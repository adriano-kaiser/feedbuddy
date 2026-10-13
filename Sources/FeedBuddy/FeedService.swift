import AppKit
import UserNotifications

/// Polling, fetching and paging. The only network access in the app (plus feed icons
/// in IconCache): requests go to the feed URLs you add and their sites, nothing else.
@MainActor
final class FeedService: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private let store: Store
    private var timer: Timer?

    private static let backfillPages = 5     // pages to pull when a feed is sparse
    private static let backfillThreshold = 15 // below this many stored items, backfill
    private static let olderNewPages = 3     // reveal ~3 pages of older items per trigger
    private static let olderFetchCap = 10    // hard cap on requests per trigger

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            // Browser-like, so feeds behind basic bot filters still answer; names the app.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) FeedBuddy/1.0",
        ]
        return URLSession(configuration: config)
    }()

    init(store: Store) {
        self.store = store
    }

    // MARK: - scheduling

    /// (Re)start polling at the configured interval.
    func schedule() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, store.settings.intervalMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        t.tolerance = min(60, interval / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Refresh when the dropdown opens, unless a check just ran.
    func refreshOnOpen() {
        if lastRefresh.map({ Date().timeIntervalSince($0) >= 120 }) ?? true {
            Task { await refreshAll() }
        }
    }

    /// After sleep the timer may be far behind; catch up if a poll is overdue.
    func refreshIfOverdue() {
        let interval = TimeInterval(max(1, store.settings.intervalMinutes) * 60)
        if lastRefresh.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
            Task { await refreshAll() }
        }
    }

    // MARK: - fetching

    func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw FeedError("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError("HTTP \(http.statusCode)")
        }
        return Self.decodeText(data, encodingName: response.textEncodingName)
    }

    /// Honor the declared charset (HTTP header, then XML prolog), else UTF-8, else Latin-1.
    private static func decodeText(_ data: Data, encodingName: String?) -> String {
        var name = encodingName
        if name == nil, let head = String(data: data.prefix(256), encoding: .ascii),
           let r = head.range(of: "encoding=[\"']([A-Za-z0-9._-]+)[\"']", options: .regularExpression) {
            name = String(head[r]).components(separatedBy: CharacterSet(charactersIn: "\"'"))[1]
        }
        if let name {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Parsing a big feed (some ship thousands of items in one file) can take a while;
    /// keep it off the main thread so the dropdown never stutters.
    private func parse(_ text: String, _ url: String) async -> FeedParser.Parsed {
        await Task.detached(priority: .utility) { FeedParser.parse(text, feedURL: url) }.value
    }

    private func fetchParsed(_ url: String) async throws -> FeedParser.Parsed {
        await parse(try await fetchText(url), url)
    }

    // MARK: - adding feeds

    /// Takes what the user pasted (a feed URL or a site URL) and saves the feed.
    func addFeed(_ raw: String) async throws -> Feed {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
            url = "https://" + url
        }

        let text = try await fetchText(url)
        var feedURL = url
        var feedText = text

        if !FeedParser.looksLikeFeed(text) {
            guard let discovered = FeedParser.discoverFeedURL(html: text, base: url) else {
                throw FeedError("No RSS or Atom feed found at that URL.")
            }
            feedURL = discovered
            feedText = try await fetchText(feedURL)
            guard FeedParser.looksLikeFeed(feedText) else {
                throw FeedError("Discovered link is not a valid feed.")
            }
        }

        let parsed = await parse(feedText, feedURL)
        let feed = try store.addFeed(url: feedURL, title: parsed.title, iconUrl: parsed.iconUrl)
        _ = try? await refreshFeed(feed)
        return feed
    }

    // MARK: - paging

    /// Query-param paging (WordPress default): ?paged=N
    static func pagedQuery(_ url: String, page: Int) -> String {
        guard var c = URLComponents(string: url) else {
            return url + (url.contains("?") ? "&" : "?") + "paged=\(page)"
        }
        var items = (c.queryItems ?? []).filter { $0.name != "paged" }
        items.append(URLQueryItem(name: "paged", value: String(page)))
        c.queryItems = items
        return c.string ?? url
    }

    /// Path paging (WordPress pretty permalinks): .../feed/ -> .../page/N/feed/
    static func pagedPath(_ url: String, page: Int) -> String {
        guard var c = URLComponents(string: url) else { return url }
        let path = c.path
        if let r = path.range(of: "/feed/?$", options: .regularExpression) {
            c.path = String(path[..<r.lowerBound]) + "/page/\(page)/feed/"
        } else {
            c.path = (path.hasSuffix("/") ? path : path + "/") + "page/\(page)/"
        }
        return c.string ?? url
    }

    private struct PagedResult {
        var first: FeedParser.Parsed
        var items: [FeedParser.Item]
        var scheme: String?
        var pages: Int
    }

    /// Fetch page 1, then keep pulling older pages until a page yields no new items or
    /// we hit maxPages. Handles rel=next, ?paged=N and /page/N/ by trying each until
    /// one returns fresh items, then locking to that scheme.
    private func fetchFeedPages(_ feedURL: String, maxPages: Int) async throws -> PagedResult {
        let first = try await fetchParsed(feedURL)
        var items = first.items
        var seen = Set(items.map(\.key))
        var next = first.next
        var scheme: String?
        var deepest = 1

        if maxPages >= 2 {
            for page in 2...maxPages {
                var candidates: [(String, String)]
                if let n = next { candidates = [("next", n)] }
                else if scheme == "query" { candidates = [("query", Self.pagedQuery(feedURL, page: page))] }
                else if scheme == "path" { candidates = [("path", Self.pagedPath(feedURL, page: page))] }
                else {
                    candidates = [("query", Self.pagedQuery(feedURL, page: page)), ("path", Self.pagedPath(feedURL, page: page))]
                }

                var advanced = false
                for (kind, url) in candidates {
                    guard let parsed = try? await fetchParsed(url) else { continue }
                    let fresh = parsed.items.filter { !seen.contains($0.key) }
                    if fresh.isEmpty { continue }
                    for i in fresh {
                        seen.insert(i.key)
                        items.append(i)
                    }
                    next = parsed.next
                    if scheme == nil && kind != "next" { scheme = kind }
                    deepest = page
                    advanced = true
                    break
                }
                if !advanced { break }
            }
        }
        return PagedResult(first: first, items: items, scheme: scheme, pages: deepest)
    }

    /// When a feed has no <image>/<icon>, use the site favicon the way a browser tab
    /// does: the homepage's <link rel="icon">, else /favicon.ico.
    private func discoverSiteIcon(_ siteOrFeedURL: String) async -> String? {
        guard let u = URL(string: siteOrFeedURL), let scheme = u.scheme, let host = u.host else { return nil }
        let origin = "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
        if let html = try? await fetchText(origin + "/"), let icon = FeedParser.pickIcon(html: html, origin: origin) {
            return icon
        }
        return origin + "/favicon.ico"
    }

    private func incoming(_ feedId: String, _ items: [FeedParser.Item], read: Bool?) -> [IncomingItem] {
        items.map {
            IncomingItem(id: "\(feedId)::\($0.key)", title: $0.title, link: $0.link, author: $0.author,
                         publishedAt: $0.publishedAt, summary: $0.summary, read: read)
        }
    }

    // MARK: - refreshing

    /// Returns the number of genuinely new items.
    @discardableResult
    func refreshFeed(_ feed: Feed) async throws -> Int {
        let stored = store.entryCount(feedId: feed.id)
        let backfilling = stored < Self.backfillThreshold
        // First sync: the existing archive is history, not news. Import it read so
        // adding a feed does not dump hundreds of items onto the unread count.
        let firstSync = stored == 0 && feed.initialized != true

        let parsed = try await fetchFeedPages(feed.url, maxPages: backfilling ? Self.backfillPages : 1)

        if let icon = parsed.first.iconUrl {
            store.updateFeed(feed.id) { $0.iconUrl = icon }
        } else if store.feed(feed.id)?.iconUrl == nil, let fav = await discoverSiteIcon(parsed.first.siteLink ?? feed.url) {
            store.updateFeed(feed.id) { $0.iconUrl = fav }
        }

        // Remember how deep the backfill reached so "load older" continues from there.
        if backfilling && parsed.pages > 1 {
            store.updateFeed(feed.id) { f in
                f.pageScheme = parsed.scheme ?? f.pageScheme
                f.deepestPage = max(f.deepestPage ?? 1, parsed.pages)
            }
        }

        let items = incoming(feed.id, parsed.items, read: firstSync ? true : nil)
        let newCount = store.mergeEntries(feedId: feed.id, items: items)
        if firstSync { store.updateFeed(feed.id) { $0.initialized = true } }

        // Drift detector: on an established feed, every fetched item counting as new
        // means item identity is unstable between fetches, not a publishing burst.
        if !firstSync && stored > 0 && items.count > 3 && newCount >= items.count {
            NSLog("FeedBuddy: \(feed.title) reported \(newCount)/\(items.count) items as new. Item ids look unstable. Sample id: \(items[0].id)")
        }
        return firstSync ? 0 : newCount
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        // Sequential: a handful of feeds costs little and keeps the load on sites low.
        var totalNew = 0
        var newByFeed: [(String, Int)] = []
        for feed in store.feeds {
            do {
                let n = try await refreshFeed(feed)
                totalNew += n
                if n > 0 { newByFeed.append((feed.title, n)) }
            } catch {
                NSLog("FeedBuddy: feed failed: \(feed.url): \(error.localizedDescription)")
            }
        }
        if totalNew > 0 { notify(totalNew, newByFeed) }
    }

    // MARK: - older pages on demand

    /// Pull the next older pages for one feed, continuing from its stored cursor.
    /// Older items land as read so they don't inflate the unread count.
    func loadOlder(feedId: String) async -> (added: Int, exhausted: Bool) {
        guard let feed = store.feed(feedId) else { return (0, true) }
        if feed.exhausted == true { return (0, true) }

        let prefix = "\(feed.id)::"
        let stored = store.entries.filter { $0.feedId == feed.id }
        var seen = Set(stored.map { String($0.id.dropFirst(prefix.count)) })
        // Keys of the newest stored posts. A "page N" containing them is really page 1:
        // the server ignored the paging parameter (some feeds ship everything at once).
        let newestKeys = Set(stored.stableSorted(by: Store.inOrder).prefix(5).map { String($0.id.dropFirst(prefix.count)) })
        var scheme = feed.pageScheme
        var page = feed.deepestPage ?? 1
        var exhausted = false
        var collected: [FeedParser.Item] = []
        var newPages = 0
        var fetches = 0

        while newPages < Self.olderNewPages && fetches < Self.olderFetchCap {
            let targets: [(String, String)]
            switch scheme {
            case "query": targets = [("query", Self.pagedQuery(feed.url, page: page + 1))]
            case "path": targets = [("path", Self.pagedPath(feed.url, page: page + 1))]
            default: targets = [("query", Self.pagedQuery(feed.url, page: page + 1)), ("path", Self.pagedPath(feed.url, page: page + 1))]
            }

            var parsed: FeedParser.Parsed?
            var usedKind: String?
            for (kind, url) in targets {
                if fetches >= Self.olderFetchCap { break }
                fetches += 1
                guard let p = try? await fetchParsed(url) else { continue } // 404: try the other scheme
                if p.items.contains(where: { newestKeys.contains($0.key) }) { continue } // paging ignored
                let hasFresh = p.items.contains { !seen.contains($0.key) }
                // Known scheme: accept any non-empty page so we can advance over pages we
                // already have. Still detecting: only accept a page with new items, so a
                // feed that ignores the paging param doesn't lock the wrong scheme.
                if !p.items.isEmpty && (scheme != nil || hasFresh) {
                    parsed = p
                    usedKind = kind
                    break
                }
            }

            guard let parsed else {
                exhausted = true // nothing paged back: end of the feed
                break
            }
            if scheme == nil { scheme = usedKind }
            page += 1

            let fresh = parsed.items.filter { !seen.contains($0.key) }
            if !fresh.isEmpty {
                for it in fresh {
                    seen.insert(it.key)
                    collected.append(it)
                }
                newPages += 1
            }
        }

        if !collected.isEmpty {
            store.mergeEntries(feedId: feed.id, items: incoming(feed.id, collected, read: true))
        }
        store.updateFeed(feed.id) { f in
            f.pageScheme = scheme
            f.deepestPage = page
            f.exhausted = exhausted
        }
        return (collected.count, exhausted)
    }

    // MARK: - notifications

    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func requestNotificationPermission() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ totalNew: Int, _ newByFeed: [(String, Int)]) {
        guard store.settings.notifications, Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(totalNew) new item\(totalNew == 1 ? "" : "s")"
        let lines = newByFeed.prefix(5).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        content.body = lines.isEmpty ? "New items in your feeds" : lines
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
