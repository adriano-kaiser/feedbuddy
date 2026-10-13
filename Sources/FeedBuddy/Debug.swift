import AppKit
import SwiftUI

/// Developer aids, reachable only via launch arguments (see main.swift).
@MainActor
enum Debug {
    /// Pass `keepIn` to keep the resulting data (e.g. to feed --snapshot); otherwise it's thrown away.
    static func check(url: String, keepIn: String? = nil) {
        let dir = keepIn.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("feedbuddy-check-\(UUID().uuidString)")
        let store = Store(directory: dir)
        let service = FeedService(store: store)
        Task {
            do {
                let start = Date()
                let feed = try await service.addFeed(url)
                let f = store.feed(feed.id)!
                let entries = store.entries.stableSorted(by: Store.inOrder)
                print("feed:     \(f.title)")
                print("url:      \(f.url)")
                print("icon:     \(f.iconUrl ?? "-")")
                print("paging:   scheme=\(f.pageScheme ?? "-") deepest=\(f.deepestPage ?? 1)")
                print("entries:  \(entries.count) (unread \(store.unreadCount)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                for e in entries.prefix(5) {
                    print("  - [\(e.publishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no date")] \(e.title.prefix(70))")
                    print("    \(e.link ?? "NO LINK") | \(e.summary.prefix(80))")
                }
                let older = await service.loadOlder(feedId: feed.id)
                print("older:    +\(older.added), exhausted=\(older.exhausted), total now \(store.entryCount(feedId: feed.id))")
                let again = try await service.refreshFeed(store.feed(feed.id)!)
                print("re-poll:  \(again) new (should be 0)")
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            if keepIn == nil { try? FileManager.default.removeItem(at: dir) }
            exit(0)
        }
        RunLoop.main.run()
    }

    static func snapshot(to outDir: String, dataDir: String?) {
        let store = Store(directory: dataDir.map { URL(fileURLWithPath: $0) })
        let model = AppModel(store: store, service: FeedService(store: store))
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: RootView.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView(app: model).background(.windowBackground))
        window.contentView = host

        let firstFeed = store.feeds.first?.id
        let screens: [(String, () -> Void)] = [
            ("home", { model.goHome() }),
            ("all-posts", { model.openFeed(nil) }),
            ("feed", { model.openFeed(firstFeed) }),
            ("settings", { model.openSettings() }),
            ("edit", { if let f = store.feeds.first { model.edit(f) } }),
        ]

        // Give icon downloads a moment, then render each screen in light and dark.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for (_, setup) in screens { setup() }
            model.goHome()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for (name, setup) in screens {
                    setup()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let suffix = appearance == .aqua ? "light" : "dark"
                    let path = "\(outDir)/\(name)-\(suffix).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print(path)
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}
