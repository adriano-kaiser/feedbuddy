import Foundation

struct Feed: Codable, Identifiable, Equatable {
    var id: String
    var url: String
    var title: String
    var iconUrl: String?
    var addedAt: Date
    /// How older pages are fetched once detected: "query" (?paged=N) or "path" (/page/N/).
    var pageScheme: String?
    /// Deepest page already pulled, so "load older" continues from there.
    var deepestPage: Int?
    /// No older pages left at the source.
    var exhausted: Bool?
    /// First sync done; its archive was imported as read.
    var initialized: Bool?
    /// Newest timestamp ever pruned by the retention cap (see Store.mergeEntries).
    var pruneWatermark: Date?
}

struct Entry: Codable, Identifiable, Equatable {
    var id: String
    var feedId: String
    var title: String
    var link: String?
    var author: String?
    var publishedAt: Date?
    var summary: String
    var read: Bool
    var starred: Bool
    var fetchedAt: Date

    var sortDate: Date { publishedAt ?? fetchedAt }
}

struct Settings: Codable, Equatable {
    var notifications = false
    var intervalMinutes = 30

    init() {}

    // Tolerate missing keys so adding a setting later never fails to decode old data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
    }
}

struct AppData: Codable {
    var feeds: [Feed] = []
    var entries: [Entry] = []
    var settings = Settings()
}

/// An item as parsed from a feed, before it is merged into storage.
struct IncomingItem {
    var id: String
    var title: String
    var link: String?
    var author: String?
    var publishedAt: Date?
    var summary: String
    /// Force read state (history imports); nil means "decide on merge".
    var read: Bool?
}

struct FeedError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Array {
    /// Sort that keeps the existing order of elements that compare equal.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { l, r in
                if areInIncreasingOrder(l.element, r.element) { return true }
                if areInIncreasingOrder(r.element, l.element) { return false }
                return l.offset < r.offset
            }
            .map(\.element)
    }
}
