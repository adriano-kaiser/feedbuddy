import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let app = NSApplication.shared

    if let i = args.firstIndex(of: "--check"), i + 1 < args.count {
        // Developer aid: add one feed into a throwaway store and print what came back.
        let keep = args.firstIndex(of: "--data").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Debug.check(url: args[i + 1], keepIn: keep)
    } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        // Developer aid: render each screen to PNG using the data in a given folder.
        let data = args.firstIndex(of: "--data").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Debug.snapshot(to: args[i + 1], dataDir: data)
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
