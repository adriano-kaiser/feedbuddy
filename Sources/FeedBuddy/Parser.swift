import Foundation

/// Minimal RSS 2.0 / RSS 1.0 / Atom parser working on plain strings, ported from
/// FeedWatch. Deliberately lenient: real-world feeds are often not valid XML.
/// Handles CDATA, entity decoding, Atom <link href>, next-page links, and the
/// common date/author variants.
enum FeedParser {
    struct Item {
        var key: String
        var title: String
        var link: String?
        var author: String?
        var publishedAt: Date?
        var summary: String
    }

    struct Parsed {
        var title: String?
        var iconUrl: String?
        var siteLink: String?
        var next: String?
        var items: [Item]
    }

    // MARK: - regex helpers

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func re(_ pattern: String) -> NSRegularExpression {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        let compiled = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        regexCache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }

    private static func matches(_ pattern: String, in s: String) -> [NSTextCheckingResult] {
        re(pattern).matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
        re(pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    /// First capture group of the first match, or nil.
    private static func capture(_ pattern: String, in s: String) -> String? {
        firstMatch(pattern, in: s).flatMap { group($0, 1, in: s) }
    }

    private static func test(_ pattern: String, _ s: String) -> Bool {
        firstMatch(pattern, in: s) != nil
    }

    private static func replace(_ pattern: String, in s: String, with transform: (NSTextCheckingResult) -> String) -> String {
        let ms = matches(pattern, in: s)
        guard !ms.isEmpty else { return s }
        var out = ""
        var cursor = s.startIndex
        for m in ms {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[cursor..<r.lowerBound]
            out += transform(m)
            cursor = r.upperBound
        }
        out += s[cursor...]
        return out
    }

    /// Text before the first match of `pattern` (the whole string when there is none).
    private static func prefix(before pattern: String, in s: String) -> String {
        guard let m = firstMatch(pattern, in: s), let r = Range(m.range, in: s) else { return s }
        return String(s[..<r.lowerBound])
    }

    // MARK: - text

    // Common HTML named entities seen in WordPress and other feeds.
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "euro": "\u{20AC}", "pound": "\u{00A3}", "cent": "\u{00A2}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "frac12": "\u{00BD}", "frac14": "\u{00BC}",
        "frac34": "\u{00BE}", "eacute": "\u{00E9}", "egrave": "\u{00E8}", "ecirc": "\u{00EA}",
        "agrave": "\u{00E0}", "acirc": "\u{00E2}", "ccedil": "\u{00E7}", "uuml": "\u{00FC}",
        "ouml": "\u{00F6}", "auml": "\u{00E4}", "szlig": "\u{00DF}", "ntilde": "\u{00F1}",
        "iacute": "\u{00ED}", "oacute": "\u{00F3}", "uacute": "\u{00FA}", "aacute": "\u{00E1}",
    ]

    private static func scalar(_ n: UInt32?) -> String {
        guard let n, let u = Unicode.Scalar(n) else { return "" }
        return String(Character(u))
    }

    static func decodeEntities(_ str: String?) -> String {
        guard var s = str, !s.isEmpty else { return "" }
        s = replace("<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>", in: s) { group($0, 1, in: s) ?? "" }
        s = replace("&#x([0-9a-f]+);", in: s) { m in scalar(group(m, 1, in: s).flatMap { UInt32($0, radix: 16) }) }
        s = replace("&#(\\d+);", in: s) { m in scalar(group(m, 1, in: s).flatMap { UInt32($0) }) }
        s = replace("&([a-z][a-z0-9]*);", in: s) { m in
            let name = group(m, 1, in: s) ?? ""
            return named[name] ?? named[name.lowercased()] ?? (group(m, 0, in: s) ?? "")
        }
        return s
    }

    /// Strip HTML tags to get a plain-text preview for the entry list.
    static func stripHtml(_ str: String?) -> String {
        var s = decodeEntities(str)
        s = replace("<style[\\s\\S]*?</style>", in: s) { _ in "" }
        s = replace("<script[\\s\\S]*?</script>", in: s) { _ in "" }
        s = replace("<[^>]+>", in: s) { _ in " " }
        s = replace("\\s+", in: s) { _ in " " }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - XML-ish lookups

    /// Inner content (raw) of the first <tag>...</tag> block.
    private static func firstTag(_ xml: String?, _ tag: String) -> String? {
        guard let xml else { return nil }
        return capture("<\(tag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tag)>", in: xml)
    }

    private static func attr(_ name: String, in rawTag: String) -> String? {
        capture("\(name)=[\"']([^\"']*)[\"']", in: rawTag)
    }

    /// Atom <link href> (prefers rel="alternate" or no rel). Also matches the
    /// namespaced <atom:link> form some RSS feeds use for item permalinks.
    private static func atomLink(_ block: String) -> String? {
        var fallback: String?
        for m in matches("<(?:atom:)?link\\b[^>]*>", in: block) {
            guard let raw = group(m, 0, in: block), let href = attr("href", in: raw), !href.isEmpty else { continue }
            let rel = attr("rel", in: raw)
            if rel == nil || rel!.lowercased() == "alternate" { return decodeEntities(href) }
            if fallback == nil { fallback = decodeEntities(href) }
        }
        return fallback
    }

    /// Next-page URL from a feed-level <link rel="next" href> (Atom paging / RFC 5005).
    private static func nextPageLink(_ xml: String) -> String? {
        let head = prefix(before: "<(?:item|entry)[\\s>]", in: xml)
        for m in matches("<(?:atom:)?link\\b[^>]*>", in: head) {
            guard let raw = group(m, 0, in: head), test("rel=[\"']?next", raw) else { continue }
            if let href = capture("href=[\"']([^\"']+)[\"']", in: raw) { return decodeEntities(href) }
        }
        return nil
    }

    /// Resolve a possibly-relative href against a base URL.
    static func absURL(_ href: String, base: String) -> String {
        guard let baseURL = URL(string: base), let u = URL(string: href, relativeTo: baseURL) else { return href }
        return u.absoluteString
    }

    /// Stable per-item key, independent of which page fetched it. A permalink URL is
    /// the most reliable anchor: prefer a URL-shaped guid, then a URL-shaped link.
    private static func itemKey(guid: String?, link: String?, title: String) -> String {
        let g = (guid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let l = (link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if test("^https?://", g) { return g }
        if test("^https?://", l) { return l }
        return [g, l, title].first { !$0.isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - dates

    private static let iso: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()

    private static let formats: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz",
        "EEE, d MMMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let s = raw.map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for f in iso { if let d = f.date(from: s) { return d } }
        for f in formats { if let d = f.date(from: s) { return d } }
        return nil
    }

    // MARK: - parse

    static func parse(_ xml: String, feedURL: String) -> Parsed {
        let isAtom = test("<feed[\\s>]", xml) && !test("<rss[\\s>]", xml)
        let channel = firstTag(xml, "channel")
        let beforeEntry = prefix(before: "<entry[\\s>]", in: xml)

        // Feed title: <channel><title> (RSS) or the first <title> outside an <entry> (Atom).
        var feedTitle = channel.flatMap { firstTag($0, "title") }
        if feedTitle == nil { feedTitle = firstTag(beforeEntry, "title") }
        let title = trimmed(decodeEntities(feedTitle))

        // Feed icon: RSS <channel><image><url>, Atom <icon> or <logo>.
        var iconUrl = channel.flatMap { firstTag($0, "image") }.flatMap { trimmed(decodeEntities(firstTag($0, "url"))) }
        if iconUrl == nil {
            iconUrl = trimmed(decodeEntities(firstTag(beforeEntry, "icon") ?? firstTag(beforeEntry, "logo")))
        }
        iconUrl = iconUrl.map { absURL($0, base: feedURL) }

        // Site link (used to derive a favicon when the feed carries no icon).
        var siteLink = channel.flatMap { trimmed(decodeEntities(firstTag($0, "link"))) }
        if siteLink == nil { siteLink = atomLink(beforeEntry) }

        let blockTag = isAtom ? "entry" : "item"
        var items: [Item] = []
        for m in matches("<\(blockTag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(blockTag)>", in: xml) {
            guard let block = group(m, 1, in: xml) else { continue }

            let itemTitle = decodeEntities(decodeEntities(firstTag(block, "title")))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // RSS <link>url</link>, or an Atom-style <link href> some RSS feeds use.
            var link = trimmed(decodeEntities(firstTag(block, "link")))
            if link == nil { link = atomLink(block) }

            let guid = trimmed(decodeEntities(firstTag(block, "guid") ?? firstTag(block, "id")))

            // Some feeds carry the permalink only in <guid>/<id> and ship no <link>.
            if link == nil, let g = guid, test("^https?://", g) { link = g }
            link = link.map { absURL($0, base: feedURL) }

            let dateRaw = firstTag(block, "pubDate") ?? firstTag(block, "published")
                ?? firstTag(block, "updated") ?? firstTag(block, "dc:date")

            let author = trimmed(decodeEntities(
                firstTag(block, "dc:creator") ?? firstTag(firstTag(block, "author"), "name")
                    ?? firstTag(block, "author") ?? ""))

            let summaryRaw = firstTag(block, "content:encoded") ?? firstTag(block, "description")
                ?? firstTag(block, "summary") ?? firstTag(block, "content") ?? ""
            // Decoded once more after stripping: some feeds double-escape (&amp;rsquo;).
            let summary = String(decodeEntities(stripHtml(summaryRaw)).prefix(400))

            if itemTitle.isEmpty && link == nil { continue }

            items.append(Item(
                key: itemKey(guid: guid, link: link, title: itemTitle),
                title: itemTitle.isEmpty ? "(untitled)" : itemTitle,
                link: link,
                author: author,
                publishedAt: parseDate(dateRaw),
                summary: summary))
        }

        return Parsed(title: title, iconUrl: iconUrl, siteLink: siteLink, next: nextPageLink(xml), items: items)
    }

    // MARK: - discovery

    /// Best-effort feed discovery when the user pastes a site URL instead of a feed URL.
    static func discoverFeedURL(html: String, base: String) -> String? {
        for m in matches("<link\\b[^>]*>", in: html) {
            guard let raw = group(m, 0, in: html),
                  test("rel=[\"']?alternate", raw),
                  test("type=[\"']?application/(rss|atom)\\+xml", raw),
                  let href = capture("href=[\"']([^\"']+)[\"']", in: raw) else { continue }
            return absURL(decodeEntities(href), base: base)
        }
        return nil
    }

    static func looksLikeFeed(_ text: String) -> Bool {
        test("<rss[\\s>]", text) || test("<feed[\\s>]", text) || test("<rdf:RDF[\\s>]", text)
    }

    /// Best <link rel="icon"> (or apple-touch-icon) from a page's HTML, preferring
    /// larger declared sizes. Returns an absolute URL, or nil.
    static func pickIcon(html: String, origin: String) -> String? {
        var best: String?
        var bestScore = -1
        for m in matches("<link\\b[^>]*>", in: html) {
            guard let raw = group(m, 0, in: html),
                  test("rel=[\"'][^\"']*icon", raw),
                  let href = capture("href=[\"']([^\"']+)[\"']", in: raw) else { continue }
            var score = capture("sizes=[\"'](\\d+)x\\d+[\"']", in: raw).flatMap { Int($0) } ?? 1
            if test("apple-touch-icon", raw) { score = max(score, 180) }
            if score > bestScore {
                bestScore = score
                best = absURL(decodeEntities(href), base: origin)
            }
        }
        return best
    }
}
