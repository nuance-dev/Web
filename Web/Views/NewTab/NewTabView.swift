import SwiftUI

struct NewTabView: View {
    let tab: Tab?
    @ObservedObject private var history = HistoryService.shared
    @ObservedObject private var bookmarks = BookmarkService.shared
    @StateObject private var windowReference = BrowserWindowReference()
    @AppStorage("searchEngine") private var searchEngineID = BrowserSearchEngine.google.rawValue
    @AppStorage("animateNewTabs") private var animateNewTabs = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var searchText = ""
    @State private var didFocusSearch = false
    @State private var lightStartedAt: Date?
    @State private var lightTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(tab: Tab? = nil) { self.tab = tab }

    private var isPrivate: Bool { tab?.isIncognito == true }
    private var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(rawValue: searchEngineID) ?? .google
    }
    private var savedPages: [Bookmark] {
        Array(bookmarks.bookmarks.filter { item in
            guard let url = URL(string: item.url) else { return false }
            return NavigationResolver.isWebURL(url)
        }.prefix(6))
    }
    private var recentPages: [HistoryItem] {
        guard !isPrivate else { return [] }
        var hosts = Set<String>()
        return Array(history.recentHistory.filter { item in
            guard let url = URL(string: item.url), NavigationResolver.isWebURL(url),
                  let host = url.host?.lowercased() else { return false }
            return hosts.insert(host).inserted
        }.prefix(4))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 10) {
                            if isPrivate {
                                HStack(spacing: 8) {
                                    Text("Private tab")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .glassEffect(.regular, in: .capsule)
                                    Text("History stays off.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 2)
                            }
                            searchField
                            quickActions(showKeys: geometry.size.width > 480)
                        }
                        if !savedPages.isEmpty { bookmarksSection }
                        if !recentPages.isEmpty { recentSection }
                    }
                    .frame(maxWidth: 580)
                    .padding(.horizontal, 24)
                    .padding(.top, max(36, min(140, geometry.size.height * 0.22)))
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(BrowserWindowReader(reference: windowReference))
        .task { focusSearchOnce() }
        .onChange(of: windowReference.isKeyWindow) { _, isKey in
            if isKey { focusSearchOnce() }
            else { stopLight() }
        }
        .onChange(of: searchText) { _, value in if !value.isEmpty { stopLight() } }
        .onChange(of: animateNewTabs) { _, enabled in if !enabled { stopLight() } }
        .onChange(of: reduceMotion) { _, enabled in if enabled { stopLight() } }
        .onChange(of: reduceTransparency) { _, enabled in if enabled { stopLight() } }
        .onDisappear(perform: stopLight)
        .onReceive(NotificationCenter.default.publisher(for: .focusAddressBarRequested)) { _ in
            if windowReference.acceptsCommands { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Search engine", selection: $searchEngineID) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Search with \(searchEngine.title)")
            .accessibilityLabel("Search engine: \(searchEngine.title)")
            TextField("Search \(searchEngine.title) or enter a link", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($searchFocused).onSubmit(search)
                .accessibilityLabel("Search or enter a link")
            Button(action: search) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Go").accessibilityLabel("Go")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if let lightStartedAt {
                NewTabLight(startedAt: lightStartedAt)
                    .padding(-12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func quickActions(showKeys: Bool) -> some View {
        HStack(spacing: 6) {
            shortcut("Glance", icon: "rectangle.bottomthird.inset.filled",
                     key: showKeys ? PeekController.shared.shortcut.label : nil) {
                NotificationCenter.default.post(name: .togglePeekRequested, object: nil)
            }
            shortcut("Commands", icon: "command", key: showKeys ? "⌘K" : nil) {
                NotificationCenter.default.post(name: .showCommandPaletteRequested, object: nil)
            }
            Spacer(minLength: 0)
        }
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Bookmarks", actionTitle: "Show all") {
                KeyboardShortcutHandler.shared.showBookmarksPanel = true
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], spacing: 6) {
                ForEach(savedPages, id: \.objectID) { item in
                    Button {
                        guard let url = URL(string: item.url) else { return }
                        navigate(to: url)
                    } label: {
                        HStack(spacing: 9) {
                            siteIcon(item.faviconData, host: domain(item.url), size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayTitle).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Text(domain(item.url)).font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    .help(item.url)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeading("Recently visited", actionTitle: "History") {
                KeyboardShortcutHandler.shared.showHistoryPanel = true
            }
            ForEach(recentPages, id: \.objectID) { item in
                Button {
                    guard let url = URL(string: item.url) else { return }
                    navigate(to: url)
                } label: {
                    HStack(spacing: 9) {
                        siteIcon(item.faviconData, host: domain(item.url), size: 18)
                        Text(item.displayTitle).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(domain(item.url)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: 145, alignment: .trailing)
                        Image(systemName: "arrow.up.left").font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(BrowserControlStyle(glass: true))
                .help(item.url)
            }
        }
    }

    private func sectionHeading(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(actionTitle)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 2)
    }

    private func shortcut(_ title: String, icon: String, key: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
                if let key {
                    Text(key).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.leading, 3)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func siteIcon(_ data: Data?, host: String, size: CGFloat) -> some View {
        if let data, let icon = NSImage(data: data) {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(String(host.prefix(1)).uppercased())
                .font(.system(size: size * 0.6, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: .rect(cornerRadius: 5))
                .accessibilityHidden(true)
        }
    }

    private func domain(_ address: String) -> String {
        let host = URL(string: address)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func focusSearchOnce() {
        guard windowReference.acceptsCommands, !didFocusSearch else { return }
        didFocusSearch = true
        searchFocused = true
        guard tab?.hasShownNewTabLight != true else { return }
        tab?.hasShownNewTabLight = true
        guard animateNewTabs, !reduceMotion, !reduceTransparency,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        lightStartedAt = Date()
        lightTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(900)) }
            catch { return }
            lightStartedAt = nil
            lightTask = nil
        }
    }

    private func stopLight() {
        lightTask?.cancel()
        lightTask = nil
        lightStartedAt = nil
    }

    private func search() {
        guard let url = NavigationResolver.resolve(searchText, engine: searchEngine) else { return }
        navigate(to: url)
        searchFocused = false
    }

    private func navigate(to url: URL) {
        guard NavigationResolver.isWebURL(url), windowReference.acceptsCommands else { return }
        if let tab { tab.navigate(to: url) }
        else { NotificationCenter.default.post(name: .navigateCurrentTab, object: url) }
    }
}

#Preview {
    NewTabView().frame(width: 1000, height: 700)
}
