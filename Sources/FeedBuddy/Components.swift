import AppKit
import SwiftUI

/// Feed icons, fetched once per URL and kept in memory (HTTP caching covers restarts).
@MainActor
final class IconCache: ObservableObject {
    static let shared = IconCache()

    @Published private(set) var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    func image(for url: String?) -> NSImage? {
        guard let url, !url.isEmpty else { return nil }
        if let image = images[url] { return image }
        if !pending.contains(url) && !failed.contains(url) { load(url) }
        return nil
    }

    private func load(_ url: String) {
        guard let u = URL(string: url) else {
            failed.insert(url)
            return
        }
        pending.insert(url)
        Task {
            let data = try? await FeedService.session.data(from: u).0
            pending.remove(url)
            if let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                images[url] = image
            } else {
                failed.insert(url)
            }
        }
    }
}

final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// The feed's own icon when it loads, else a colored monogram.
struct FeedAvatar: View {
    let feed: Feed?
    var size: CGFloat = 20
    @ObservedObject private var icons = IconCache.shared

    private static let colors: [Color] = [
        Color(red: 0.49, green: 0.36, blue: 1.0), Color(red: 0.88, green: 0.34, blue: 0.56),
        Color(red: 0.18, green: 0.62, blue: 0.44), Color(red: 0.88, green: 0.57, blue: 0.23),
        Color(red: 0.23, green: 0.53, blue: 0.78), Color(red: 0.61, green: 0.35, blue: 0.71),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        if let image = icons.image(for: feed?.iconUrl) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            let title = feed?.title ?? "?"
            shape
                .fill(Self.color(for: title))
                .frame(width: size, height: size)
                .overlay(
                    Text(String(title.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased())
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(.white))
        }
    }

    private static func color(for title: String) -> Color {
        var h: UInt32 = 0
        for u in title.utf16 { h = h &* 31 &+ UInt32(u) }
        return colors[Int(h % UInt32(colors.count))]
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover.isHovered ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover.isHovered ? .primary : .secondary)
        .help(help)
        .onHover { hover.isHovered = $0 }
    }
}

struct CountBadge: View {
    let count: Int
    var prominent = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.1)))
            .foregroundStyle(prominent ? Color.white : Color.secondary)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TopBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { content }
                .padding(.horizontal, 8)
                .frame(height: 44)
            Divider()
        }
    }
}

/// Inline confirmation shown at the bottom of the dropdown (modal alerts would close it).
struct ConfirmBar: View {
    let confirmation: Confirmation
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(confirmation.message).lineLimit(2)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) {
                    dismiss()
                    confirmation.action()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}

enum TimeAgo {
    static func string(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 30 { return "\(d) day\(d == 1 ? "" : "s")" }
        let mo = d / 30
        if mo < 12 { return "\(mo) mo" }
        return "\(mo / 12)y"
    }
}
