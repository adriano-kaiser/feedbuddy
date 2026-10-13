import SwiftUI

struct RootView: View {
    static let size = CGSize(width: 420, height: 560)

    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch app.route {
            case .home: HomeView(app: app)
            case .feed: FeedView(app: app)
            case .settings: SettingsView(app: app)
            case .edit: EditFeedView(app: app)
            }
            if let c = app.confirmation {
                ConfirmBar(confirmation: c) { app.confirmation = nil }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Solid instead of the popover's default see-through material.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}

// MARK: - Home (feed list)

struct HomeView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let counts = app.unreadByFeed
        let total = counts.values.reduce(0, +)

        VStack(spacing: 0) {
            TopBar {
                IconButton(systemName: "gearshape", help: "Settings") { app.openSettings() }
                Spacer()
                HStack(spacing: 2) {
                    IconButton(systemName: "list.bullet", help: "All posts") { app.openFeed(nil, filter: .all) }
                    Text("\(total)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 22)
                    IconButton(systemName: "star", help: "Starred") { app.openFeed(nil, filter: .starred) }
                }
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Spacer()
                IconButton(systemName: "plus.circle", help: "Add feed") { app.openSettings(focusAdd: true) }
                IconButton(systemName: "checkmark.circle", help: "Mark all read") { app.markAllRead(feedId: nil) }
            }

            SearchField(placeholder: "Search all posts…", text: Binding(
                get: { "" },
                set: { app.searchFromHome($0) }))

            if app.store.feeds.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.up.forward").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No feeds yet.")
                    Text("Add one with the + button.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        FeedRow(title: "All posts", count: total, feed: nil, app: app) { app.openFeed(nil, filter: .all) }
                        ForEach(app.store.feeds) { feed in
                            FeedRow(title: feed.title, count: counts[feed.id] ?? 0, feed: feed, app: app) {
                                app.openFeed(feed.id, filter: .all)
                            }
                        }
                    }
                    .padding(6)
                }
            }

            if app.service.isRefreshing {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking feeds…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

struct FeedRow: View {
    let title: String
    let count: Int
    let feed: Feed?
    @ObservedObject var app: AppModel
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: 10) {
            if let feed {
                FeedAvatar(feed: feed)
            } else {
                Image(systemName: "tray.full").frame(width: 20, height: 20).foregroundStyle(.secondary)
            }
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if count > 0 { CountBadge(count: count) }
            if let feed {
                Menu {
                    menuItems(feed)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 20)
                .opacity(hover.isHovered ? 1 : 0)
                .help("Feed options")
            } else {
                Color.clear.frame(width: 20, height: 1) // keeps counts aligned with feed rows
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.isHovered ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            if let feed { menuItems(feed) }
        }
    }

    @ViewBuilder
    private func menuItems(_ feed: Feed) -> some View {
        Button("Mark Feed as Read") { app.markAllRead(feedId: feed.id) }
        Button("Open All Unread") { app.openAllUnread(feed) }
        Button("Reload Feed") { app.reload(feed) }
        Divider()
        Button("Edit Feed…") { app.edit(feed) }
        Button("Delete Feed…", role: .destructive) { app.delete(feed) }
    }
}

// MARK: - Feed (entry list)

struct FeedView: View {
    @ObservedObject var app: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let feed = app.currentFeed
        let list = app.visibleEntries
        let unread = list.lazy.filter { !$0.read }.count
        let feedsById = Dictionary(uniqueKeysWithValues: app.store.feeds.map { ($0.id, $0) })

        VStack(spacing: 0) {
            TopBar {
                IconButton(systemName: "chevron.left", help: "Back") { app.goHome() }
                if let feed { FeedAvatar(feed: feed) }
                Text(feed?.title ?? "All posts").font(.headline).lineLimit(1)
                Spacer()
                if unread > 0 { CountBadge(count: unread) }
            }

            SearchField(placeholder: "Search…", text: $app.search)
                .focused($searchFocused)
                .onChange(of: app.search) { app.limit = AppModel.page }

            HStack(spacing: 4) {
                ToolbarButton(systemName: "line.3.horizontal.decrease", title: app.filter.label) { app.cycleFilter() }
                    .help("Show all, unread or starred posts")
                ToolbarButton(systemName: "checkmark", title: "Mark all read") { app.markAllRead(feedId: app.feedId) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()

            if list.isEmpty {
                Text(app.search.isEmpty ? "Nothing here." : "No matching posts.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("top")
                            ForEach(list.prefix(app.limit)) { entry in
                                EntryRow(entry: entry, feed: feedsById[entry.feedId], app: app)
                                Divider().padding(.leading, 14)
                            }
                            footer(feed: feed, total: list.count)
                        }
                    }
                    .onChange(of: app.scrollToken) { proxy.scrollTo("top") }
                }
            }
        }
        .onAppear { if !app.search.isEmpty { searchFocused = true } }
    }

    @ViewBuilder
    private func footer(feed: Feed?, total: Int) -> some View {
        Group {
            if app.limit < total {
                // Reaching the bottom reveals the next stored page.
                Button("Load more") { app.loadMore() }
                    .onAppear { app.loadMore() }
            } else if let feed, feed.exhausted != true {
                // Older posts come from the source; fetch automatically only once the
                // user has scrolled through a full page, else wait for a click.
                Button(app.loadingOlder ? "Loading older posts…" : "Load older posts") { app.loadOlder() }
                    .disabled(app.loadingOlder)
                    .onAppear { if total >= AppModel.page { app.loadOlder() } }
            } else if feed != nil {
                Text("No older posts").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

struct ToolbarButton: View {
    let systemName: String
    let title: String
    var action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover.isHovered ? 0.1 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

struct EntryRow: View {
    let entry: Entry
    let feed: Feed?
    @ObservedObject var app: AppModel
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.read ? .regular : .semibold))
                    .foregroundStyle(entry.read ? .secondary : .primary)
                    .lineLimit(2)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    FeedAvatar(feed: feed, size: 14)
                    if let feed { Text(feed.title).lineLimit(1) }
                    if entry.publishedAt != nil || feed != nil { Text("·") }
                    Text(TimeAgo.string(entry.sortDate))
                    if entry.starred {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .opacity(entry.read ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hover.isHovered ? Color.primary.opacity(0.05) : .clear)
        .overlay(alignment: .topTrailing) {
            if hover.isHovered { actions }
        }
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
        .onTapGesture { app.open(entry) }
        .contextMenu {
            Button("Open") { app.open(entry) }
            Button(entry.starred ? "Unstar" : "Star") { app.toggleStar(entry) }
            Button(entry.read ? "Mark as Unread" : "Mark as Read") { app.toggleRead(entry) }
            if let link = entry.link {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "arrow.up.right.square", help: "Open") { app.open(entry) }
            IconButton(systemName: entry.starred ? "star.fill" : "star", help: entry.starred ? "Unstar" : "Star") {
                app.toggleStar(entry)
            }
            IconButton(systemName: entry.read ? "circle" : "checkmark.circle",
                       help: entry.read ? "Mark as unread" : "Mark as read") {
                app.toggleRead(entry)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 1))
        .padding(6)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                IconButton(systemName: "chevron.left", help: "Back") { app.goHome() }
                Text("Settings").font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingRow(title: "Notifications", subtitle: "Notify when new items arrive") {
                        Toggle("", isOn: Binding(get: { app.store.settings.notifications }, set: { app.setNotifications($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    SettingRow(title: "Check every", subtitle: "How often feeds are polled") {
                        Picker("", selection: Binding(get: { app.store.settings.intervalMinutes }, set: { app.setInterval($0) })) {
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("60 min").tag(60)
                            Text("2 hours").tag(120)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingRow(title: "Start at login", subtitle: "Launch FeedBuddy when you log in") {
                        Toggle("", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    HStack {
                        Button(app.service.isRefreshing ? "Checking…" : "Check now") { app.checkNow() }
                            .disabled(app.service.isRefreshing)
                        if let last = app.service.lastRefresh {
                            Text("Last checked \(TimeAgo.string(last))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import OPML…") { app.importOPML() }
                        Button("Export OPML…") { app.exportOPML() }
                            .disabled(app.store.feeds.isEmpty)
                    }
                    if !app.settingsMessage.isEmpty {
                        Text(app.settingsMessage).font(.caption).foregroundStyle(.secondary)
                    }

                    Text("FEEDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    VStack(spacing: 0) {
                        if app.store.feeds.isEmpty {
                            Text("No feeds added.").foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(app.store.feeds) { feed in
                            HStack(spacing: 10) {
                                FeedAvatar(feed: feed)
                                Text(feed.title).lineLimit(1)
                                Spacer()
                                IconButton(systemName: "pencil", help: "Edit feed") { app.edit(feed) }
                                IconButton(systemName: "trash", help: "Remove feed") { app.delete(feed) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                    HStack {
                        TextField("Feed or site URL…", text: $app.addURL)
                            .textFieldStyle(.roundedBorder)
                            .focused($addFocused)
                            .onSubmit { app.addFeed() }
                        Button(app.adding ? "Adding…" : "Add") { app.addFeed() }
                            .disabled(app.adding || app.addURL.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    if !app.addError.isEmpty {
                        Text(app.addError).font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        Button("Quit FeedBuddy") { app.quit() }
                    }
                    .padding(.top, 8)
                }
                .padding(14)
            }
        }
        .onAppear {
            if app.focusAdd {
                app.focusAdd = false
                DispatchQueue.main.async { addFocused = true }
            }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control
        }
    }
}

// MARK: - Edit feed

struct EditFeedView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                IconButton(systemName: "chevron.left", help: "Back") { app.goHome() }
                Text("Edit feed").font(.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title").font(.caption).foregroundStyle(.secondary)
                    TextField("Custom title", text: $app.editTitle).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Feed URL").font(.caption).foregroundStyle(.secondary)
                    TextField("https://…", text: $app.editURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { app.saveEdit() }
                }
                if !app.editError.isEmpty {
                    Text(app.editError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { app.goHome() }.keyboardShortcut(.cancelAction)
                    Button("Save") { app.saveEdit() }.keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
            .padding(14)
        }
    }
}
