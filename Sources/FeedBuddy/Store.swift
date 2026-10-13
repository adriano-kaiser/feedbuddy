import Foundation

/// Single source of truth for persisted data: one JSON file in Application Support.
/// Nothing leaves the machine. All mutations run on the main actor, so a background
/// refresh and a click in the UI can never interleave a read-modify-write.
@MainActor
final class Store: ObservableObject {
    /// Retention cap per feed. Only regular read items count toward it; unread and
    /// starred are always kept. Older items pulled on demand land as read, so this
    /// also bounds how far back you can scroll before the oldest get pruned.
    static let maxEntriesPerFeed = 200

    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var settings = Settings()

    let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FeedBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        load()
    }

    var unreadCount: Int { entries.lazy.filter { !$0.read }.count }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            feeds = decoded.feeds
            entries = decoded.entries
            settings = decoded.settings
        } catch {
            // Keep a copy so an unreadable file is never silently overwritten.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("data-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("FeedBuddy: could not read \(fileURL.path): \(error). Backed up to \(backup.lastPathComponent)")
        }
    }

    private func save() {
        let data = AppData(feeds: feeds, entries: entries, settings: settings)
        do {
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("FeedBuddy: could not save: \(error)")
        }
    }

    // MARK: - settings

    func updateSettings(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    // MARK: - feeds

    func feed(_ id: String) -> Feed? { feeds.first { $0.id == id } }

    @discardableResult
    func addFeed(url: String, title: String?, iconUrl: String?) throws -> Feed {
        if feeds.contains(where: { $0.url == url }) {
            throw FeedError("That feed is already added.")
        }
        let feed = Feed(
            id: UUID().uuidString.lowercased(),
            url: url,
            title: (title?.isEmpty == false ? title : nil) ?? url,
            iconUrl: iconUrl,
            addedAt: Date())
        feeds.append(feed)
        save()
        return feed
    }

    /// Update mutable feed metadata (icon discovered later, paging cursor, ...).
    func updateFeed(_ id: String, _ change: (inout Feed) -> Void) {
        guard let i = feeds.firstIndex(where: { $0.id == id }) else { return }
        var f = feeds[i]
        change(&f)
        guard f != feeds[i] else { return }
        feeds[i] = f
        save()
    }

    /// Edit a feed's title and/or URL. Keeps the feed id (and its entries) stable.
    func editFeed(_ id: String, title: String, url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, feeds.contains(where: { $0.id != id && $0.url == url }) {
            throw FeedError("Another feed already uses that URL.")
        }
        updateFeed(id) { f in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { f.title = t }
            if !url.isEmpty { f.url = url }
        }
    }

    func removeFeed(_ id: String) {
        feeds.removeAll { $0.id == id }
        entries.removeAll { $0.feedId == id }
        save()
    }

    // MARK: - entries

    /// List order, newest first, with ties between feeds settled by feed. Timestamps
    /// tie a lot (many feeds publish only a date, or round to the hour); entries of one
    /// feed with the same timestamp compare equal and, because the sort is stable, keep
    /// their stored order. mergeEntries picks that order once, when an entry arrives,
    /// so a refresh can insert new items but never reshuffle old ones.
    nonisolated static func inOrder(_ a: Entry, _ b: Entry) -> Bool {
        if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
        return a.feedId < b.feedId
    }

    /// Merge freshly fetched items into storage. Preserves read/starred state for
    /// entries we already had, matching first by id and then by normalized link so a
    /// drifting guid can't resurrect read items as new. Also collapses duplicates a
    /// previous drift may have created. Returns the count of new items.
    @discardableResult
    func mergeEntries(feedId: String, items: [IncomingItem]) -> Int {
        // The feed may have been deleted while its refresh was in flight.
        guard let feedRec = feed(feedId) else { return 0 }
        let prevWatermark = feedRec.pruneWatermark
        let mine = entries.filter { $0.feedId == feedId }
        let others = entries.filter { $0.feedId != feedId }

        var byId: [String: Entry] = [:]
        var byLink: [String: Entry] = [:]
        for e in mine {
            if byId[e.id] == nil { byId[e.id] = e }
            if let nl = Self.normLink(e.link), byLink[nl] == nil { byLink[nl] = e }
        }

        var matched: [String: Entry] = [:] // existing entry id -> refreshed copy
        var newCount = 0
        let now = Date()
        var arrived: [Entry] = [] // new unread items
        var history: [Entry] = [] // new items imported read (older pages, pruned history)

        for item in items {
            let nl = Self.normLink(item.link)
            var prev = byId[item.id]
            if prev == nil, let nl { prev = byLink[nl] }

            if let p = prev {
                // Another incoming item pointing at the same stored entry: skip.
                guard matched[p.id] == nil else { continue }
                // Keep identity, user state and date; refresh content. The date stays
                // as first seen because some feeds re-date a post whenever it is
                // edited, which would move it around the list.
                var u = p
                u.title = item.title
                u.link = item.link
                u.author = item.author
                u.publishedAt = p.publishedAt ?? item.publishedAt
                u.summary = item.summary
                matched[p.id] = u
            } else {
                // Older than the newest thing we previously pruned: history the user
                // already had, not news. Import it read so the retention cap cannot
                // manufacture unread items every poll.
                var isPrunedHistory = false
                if let w = prevWatermark, let ts = item.publishedAt { isPrunedHistory = ts <= w }
                if !isPrunedHistory { newCount += 1 }
                let read = item.read ?? isPrunedHistory
                let e = Entry(
                    id: item.id, feedId: feedId, title: item.title, link: item.link,
                    author: item.author, publishedAt: item.publishedAt, summary: item.summary,
                    read: read, starred: false, fetchedAt: now)
                if read { history.append(e) } else { arrived.append(e) }
            }
        }

        // Unread arrivals above stored entries, stored entries in their existing order
        // (including ones this fetch no longer lists), history below, so the stable
        // sort settles same-timestamp ties without ever swapping stored entries.
        let merged = (arrived + mine.map { matched[$0.id] ?? $0 } + history)
            .stableSorted(by: Self.inOrder)

        // Collapse duplicates sharing a normalized link (or id when there is no link).
        // If any copy was read or starred, the survivor inherits it.
        var canon: [String: Int] = [:]
        var deduped: [Entry] = []
        for e in merged {
            let key = Self.normLink(e.link) ?? e.id
            if let i = canon[key] {
                deduped[i].read = deduped[i].read || e.read
                deduped[i].starred = deduped[i].starred || e.starred
            } else {
                canon[key] = deduped.count
                deduped.append(e)
            }
        }

        // Cap, but never drop unread or starred items. Remember how recent the newest
        // dropped item was, so when the feed serves it again it comes back read.
        var kept: [Entry] = []
        var readCount = 0
        var droppedWatermark: Date?
        for e in deduped {
            if !e.read || e.starred || readCount < Self.maxEntriesPerFeed {
                kept.append(e)
                if e.read && !e.starred { readCount += 1 }
            } else {
                let ts = e.publishedAt ?? e.fetchedAt
                if droppedWatermark.map({ ts > $0 }) ?? true { droppedWatermark = ts }
            }
        }

        entries = others + kept
        if let d = droppedWatermark, d > (prevWatermark ?? .distantPast),
           let i = feeds.firstIndex(where: { $0.id == feedId }) {
            feeds[i].pruneWatermark = d
        }
        save()
        return newCount
    }

    func entryCount(feedId: String) -> Int {
        entries.lazy.filter { $0.feedId == feedId }.count
    }

    func setRead(_ entryId: String, _ read: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == entryId }), entries[i].read != read else { return }
        entries[i].read = read
        save()
    }

    func toggleStar(_ entryId: String) {
        guard let i = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[i].starred.toggle()
        save()
    }

    /// Mark all read, optionally scoped to one feed.
    func markAllRead(feedId: String? = nil) {
        var changed = false
        for i in entries.indices where !entries[i].read && (feedId == nil || entries[i].feedId == feedId) {
            entries[i].read = true
            changed = true
        }
        if changed { save() }
    }

    // MARK: - link identity

    private nonisolated static let trackingParam = try! NSRegularExpression(
        pattern: "^(utm_|fbclid|gclid|mc_|igshid|ref$|ref_)", options: .caseInsensitive)

    /// A stable identity for an item based on its link, so read/starred state sticks
    /// even when a feed's guid drifts or carries a per-fetch token. Strips common
    /// tracking params, lowercases the origin, drops trailing slashes. The fragment is
    /// KEPT: some feeds permalink each item as an anchor on one page.
    nonisolated static func normLink(_ link: String?) -> String? {
        guard let raw = link?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard var c = URLComponents(string: raw), let scheme = c.scheme, let host = c.host else { return raw }
        if let items = c.queryItems {
            let kept = items.filter { item in
                let n = item.name as NSString
                return trackingParam.firstMatch(in: item.name, range: NSRange(location: 0, length: n.length)) == nil
            }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        var origin = "\(scheme)://\(host)".lowercased()
        if let port = c.port { origin += ":\(port)" }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let search = c.percentEncodedQuery.map { "?" + $0 } ?? ""
        let hash = c.percentEncodedFragment.map { "#" + $0 } ?? ""
        return origin + path + search + hash
    }
}
