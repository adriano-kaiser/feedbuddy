import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private lazy var service = FeedService(store: store)
    private lazy var model = AppModel(store: store, service: service)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "dot.radiowaves.up.forward", accessibilityDescription: "FeedBuddy")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.contentViewController = NSHostingController(rootView: RootView(app: model))
        popover.contentSize = RootView.size
        popover.behavior = .transient

        store.$entries
            .map { $0.lazy.filter { !$0.read }.count }
            .removeDuplicates()
            .sink { [weak self] count in self?.updateStatus(unread: count) }
            .store(in: &cancellables)

        if FeedService.canNotify {
            UNUserNotificationCenter.current().delegate = self
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                MainActor.assumeIsolated { self?.service.refreshIfOverdue() }
            }
        }

        LoginItem.enableOnFirstRun()
        service.schedule()
        Task { await service.refreshAll() }
    }

    private func updateStatus(unread: Int) {
        guard let button = statusItem.button else { return }
        button.title = unread > 0 ? " \(unread)" : ""
        button.toolTip = unread > 0 ? "FeedBuddy — \(unread) unread" : "FeedBuddy"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Fresh check on open, like the extension did (skipped if one just ran).
        service.refreshOnOpen()
    }

    // MARK: - notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !self.popover.isShown { self.showPopover() }
            }
        }
        completionHandler()
    }
}
