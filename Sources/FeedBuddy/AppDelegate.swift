import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private lazy var service = FeedService(store: store)
    private lazy var model = AppModel(store: store, service: service)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

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
        popover.delegate = self

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

        installEditMenu()
        LoginItem.enableOnFirstRun()
        service.schedule()
        Task { await service.refreshAll() }
    }

    /// A menu bar app has no visible menus, but ⌘C/⌘V/⌘X/⌘A/⌘Z in text fields are
    /// dispatched through the main menu's key equivalents. Without this Edit menu they do
    /// nothing (only right-click > Paste works). The menu is never shown.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
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
        popover.contentViewController?.view.window?.makeKey()
        // A menu bar app often can't become active (macOS 14+ activation is cooperative),
        // and then .transient never sees clicks elsewhere. Clicks in other apps arrive
        // here instead; mouse events need no extra permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        // Fresh check on open, like the extension did (skipped if one just ran).
        service.refreshOnOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
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
