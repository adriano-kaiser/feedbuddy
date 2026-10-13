import AppKit
import Combine
import UniformTypeIdentifiers

enum Route: Equatable {
    case home, feed, settings, edit
}

enum Filter: String, CaseIterable {
    case all, unread, starred

    var label: String { rawValue.capitalized }
    var next: Filter { Filter.allCases[(Filter.allCases.firstIndex(of: self)! + 1) % Filter.allCases.count] }
}

struct Confirmation: Identifiable {
    let id = UUID()
    let message: String
    let confirmTitle: String
    let action: () -> Void
}

/// View state for the dropdown plus every user action. Views observe this one object;
/// it re-publishes changes from the store and the feed service.
@MainActor
final class AppModel: ObservableObject {
    static let page = 20

    let store: Store
    let service: FeedService

    @Published var route: Route = .home
    @Published var feedId: String? // nil = all posts
    @Published var filter: Filter = .all
    @Published var search = ""
    @Published var limit = AppModel.page
    @Published var loadingOlder = false
    @Published var scrollToken = UUID()
    @Published var confirmation: Confirmation?

    @Published var addURL = ""
    @Published var addError = ""
    @Published var adding = false
    @Published var focusAdd = false
    @Published var settingsMessage = ""
    @Published var launchAtLogin = false

    @Published var editFeedId: String?
    @Published var editTitle = ""
    @Published var editURL = ""
    @Published var editError = ""

    private var cancellables: Set<AnyCancellable> = []

    init(store: Store, service: FeedService) {
        self.store = store
        self.service = service
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - selectors

    var currentFeed: Feed? { feedId.flatMap(store.feed) }

    var unreadByFeed: [String: Int] {
        var map: [String: Int] = [:]
        for e in store.entries where !e.read { map[e.feedId, default: 0] += 1 }
        return map
    }

    var visibleEntries: [Entry] {
        let feedIds = Set(store.feeds.map(\.id))
        var list = store.entries.filter { feedIds.contains($0.feedId) }
        if let feedId { list = list.filter { $0.feedId == feedId } }
        switch filter {
        case .all: break
        case .unread: list = list.filter { !$0.read }
        case .starred: list = list.filter(\.starred)
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
        }
        return list.stableSorted(by: Store.inOrder)
    }

    // MARK: - navigation

    func openFeed(_ id: String?, filter: Filter? = nil) {
        route = .feed
        feedId = id
        if let filter { self.filter = filter }
        search = ""
        limit = Self.page
        loadingOlder = false
        scrollToken = UUID()
    }

    /// Typing in the home search jumps to "All posts" with that query.
    func searchFromHome(_ q: String) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        openFeed(nil)
        search = q
    }

    func goHome() {
        route = .home
        feedId = nil
        filter = .all
        confirmation = nil
    }

    func openSettings(focusAdd: Bool = false) {
        route = .settings
        addError = ""
        settingsMessage = ""
        launchAtLogin = LoginItem.isEnabled
        self.focusAdd = focusAdd
    }

    func cycleFilter() {
        filter = filter.next
        limit = Self.page
    }

    // MARK: - entries

    func open(_ entry: Entry) {
        store.setRead(entry.id, true)
        guard let link = entry.link?.trimmingCharacters(in: .whitespaces),
              link.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: link) else {
            NSLog("FeedBuddy: entry has no usable link: \(entry.id)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func toggleRead(_ entry: Entry) { store.setRead(entry.id, !entry.read) }
    func toggleStar(_ entry: Entry) { store.toggleStar(entry.id) }
    func markAllRead(feedId: String?) { store.markAllRead(feedId: feedId) }

    func loadMore() { limit += Self.page }

    /// Pull the next older pages for the current feed from its source.
    func loadOlder() {
        guard let id = feedId, !loadingOlder, currentFeed?.exhausted != true else { return }
        loadingOlder = true
        Task {
            let result = await service.loadOlder(feedId: id)
            if result.added > 0 { limit += result.added }
            loadingOlder = false
        }
    }

    // MARK: - feeds

    func openAllUnread(_ feed: Feed) {
        let list = store.entries
            .filter { $0.feedId == feed.id && !$0.read && $0.link != nil }
            .stableSorted(by: Store.inOrder)
        guard !list.isEmpty else { return }
        let run = { [weak self] in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            for e in list {
                if let link = e.link, let url = URL(string: link) {
                    NSWorkspace.shared.open(url, configuration: config)
                }
                self?.store.setRead(e.id, true)
            }
        }
        if list.count > 10 {
            confirmation = Confirmation(message: "Open \(list.count) tabs?", confirmTitle: "Open", action: run)
        } else {
            run()
        }
    }

    func reload(_ feed: Feed) {
        Task { _ = try? await service.refreshFeed(feed) }
    }

    func delete(_ feed: Feed) {
        confirmation = Confirmation(message: "Delete \u{201C}\(feed.title)\u{201D}?", confirmTitle: "Delete") { [weak self] in
            self?.store.removeFeed(feed.id)
            if self?.feedId == feed.id { self?.goHome() }
        }
    }

    func edit(_ feed: Feed) {
        editFeedId = feed.id
        editTitle = feed.title
        editURL = feed.url
        editError = ""
        route = .edit
    }

    func saveEdit() {
        guard let id = editFeedId, let feed = store.feed(id) else { return goHome() }
        let url = editURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            editError = "A feed URL is required."
            return
        }
        do {
            try store.editFeed(id, title: editTitle, url: url)
            if url != feed.url, let updated = store.feed(id) { reload(updated) }
            goHome()
        } catch {
            editError = error.localizedDescription
        }
    }

    func addFeed() {
        let url = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !adding else { return }
        addError = ""
        adding = true
        Task {
            do {
                _ = try await service.addFeed(url)
                addURL = ""
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }

    func checkNow() {
        Task { await service.refreshAll() }
    }

    // MARK: - settings

    func setNotifications(_ on: Bool) {
        store.updateSettings { $0.notifications = on }
        if on { service.requestNotificationPermission() }
    }

    func setInterval(_ minutes: Int) {
        store.updateSettings { $0.intervalMinutes = minutes }
        service.schedule()
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an OPML file exported from an RSS reader"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let outlines = try OPML.parse(try Data(contentsOf: url))
            var added: [Feed] = []
            var skipped = 0
            for o in outlines {
                if let f = try? store.addFeed(url: o.url, title: o.title, iconUrl: nil) {
                    added.append(f)
                } else {
                    skipped += 1
                }
            }
            settingsMessage = "Imported \(added.count) feed\(added.count == 1 ? "" : "s")"
                + (skipped > 0 ? " (\(skipped) already added)" : "") + "."
            Task {
                for f in added { _ = try? await service.refreshFeed(f) }
            }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func exportOPML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "FeedBuddy.opml"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OPML.export(store.feeds).write(to: url, options: .atomic)
            settingsMessage = "Exported \(store.feeds.count) feeds."
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func quit() { NSApp.terminate(nil) }
}
