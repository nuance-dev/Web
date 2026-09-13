import Combine
import SwiftUI
import WebKit

enum TabDisplayMode: String, CaseIterable {
    case sidebar, topBar, hidden
}

struct TabDisplayView: View {
    @ObservedObject var tabManager: TabManager
    @AppStorage("tabDisplayMode") private var displayMode: TabDisplayMode = .sidebar
    @AppStorage("hideTopBar") private var hideTopBar = false
    @State private var focusMode = false
    @StateObject private var windowReference = BrowserWindowReference()

    private let commands: [Notification.Name] = [
        .toggleTabDisplay, .toggleEdgeToEdge, .newTabRequested, .newTabInBackgroundRequested,
        .closeTabRequested, .reopenTabRequested, .newIncognitoTabRequested, .nextTabRequested, .previousTabRequested,
        .selectTabByNumber, .createNewTabWithURL, .toggleTopBar, .navigateCurrentTab,
        .reloadRequested, .bookmarkCurrentPageRequested
    ]

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if displayMode == .topBar && !focusMode {
                    TopBarTabView(tabManager: tabManager)
                }
                if !focusMode && !hideTopBar {
                    BrowserToolbar(tabManager: tabManager,
                                   showsWindowControls: displayMode != .topBar)
                        .zIndex(2)
                }
                HStack(spacing: 0) {
                    if displayMode == .sidebar && !focusMode {
                        SidebarTabView(tabManager: tabManager)
                    }
                    WebContentArea(tabManager: tabManager)
                    AISidebar(tabManager: tabManager)
                }
            }
            if hideTopBar || focusMode {
                if let tab = tabManager.activeTab {
                    HoverableURLBar(tabID: tab.id, themeColor: tab.themeColor,
                        onSubmit: { input in
                            guard let url = NavigationResolver.resolve(input) else { return }
                            tab.navigate(to: url)
                        }, tabManager: tabManager,
                        showsWindowControls: focusMode || displayMode != .topBar)
                }
            }
            SecurityWarningSheet()
            SafeBrowsingWarningSheet()
        }
        .background(BrowserWindowReader(reference: windowReference))
        .onReceive(Publishers.MergeMany(commands.map { NotificationCenter.default.publisher(for: $0) })) { notification in
            if let sourceTabID = notification.userInfo?["sourceTabID"] as? UUID {
                guard tabManager.tabs.contains(where: { $0.id == sourceTabID }) else { return }
            } else {
                guard windowReference.acceptsCommands else { return }
            }
            handle(notification)
        }
    }

    private func handle(_ notification: Notification) {
        switch notification.name {
        case .toggleTabDisplay:
            displayMode = displayMode == .sidebar ? .topBar : .sidebar
        case .toggleEdgeToEdge:
            focusMode.toggle()
        case .toggleTopBar:
            hideTopBar.toggle()
        case .newTabRequested:
            _ = tabManager.createNewTab()
        case .newIncognitoTabRequested:
            let requestedURL = notification.object as? URL
            guard requestedURL == nil || requestedURL.map(NavigationResolver.isWebURL) == true else { return }
            _ = tabManager.createIncognitoTab(url: requestedURL)
        case .newTabInBackgroundRequested:
            if let url = notification.userInfo?["url"] as? URL, NavigationResolver.isWebURL(url) {
                let sourceTabID = notification.userInfo?["sourceTabID"] as? UUID
                let source = tabManager.tabs.first(where: { $0.id == sourceTabID })
                let isPrivate = source?.isIncognito ?? tabManager.activeTab?.isIncognito ?? false
                _ = tabManager.createNewTabInBackground(url: url, isIncognito: isPrivate)
            }
        case .closeTabRequested:
            if let tab = tabManager.activeTab { tabManager.closeTab(tab) }
        case .reopenTabRequested:
            _ = tabManager.reopenLastClosedTab()
        case .nextTabRequested:
            tabManager.selectNextTab()
        case .previousTabRequested:
            tabManager.selectPreviousTab()
        case .selectTabByNumber:
            if let number = notification.object as? Int { tabManager.selectTabByNumber(number) }
        case .createNewTabWithURL:
            if let url = notification.object as? URL, NavigationResolver.isWebURL(url) { _ = tabManager.createNewTab(url: url) }
        case .navigateCurrentTab:
            if let url = notification.object as? URL, NavigationResolver.isWebURL(url) {
                if let tab = tabManager.activeTab { tab.navigate(to: url) }
                else { _ = tabManager.createNewTab(url: url) }
            }
        case .reloadRequested:
            tabManager.activeTab?.reload()
        case .bookmarkCurrentPageRequested:
            if let tab = tabManager.activeTab, let url = tab.url, NavigationResolver.isWebURL(url) {
                KeyboardShortcutHandler.shared.toggleBookmark(url: url.absoluteString, title: tab.title)
            }
        default: break
        }
    }
}

struct WebContentArea: View {
    @ObservedObject var tabManager: TabManager
    @State private var failedTabID: UUID?
    @State private var failedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let tab = tabManager.activeTab {
                    WebContentView(tab: tab, tabManager: tabManager)
                        .id(tab.id)
                    if failedTabID == tab.id {
                        NoInternetConnectionView(onRetry: retry, onGoBack: {
                            failedTabID = nil
                            failedURL = nil
                            tab.goBack()
                        })
                    }
                } else {
                    NewTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNoInternetConnection)) { notification in
            guard let id = notification.object as? UUID, id == tabManager.activeTab?.id else { return }
            failedTabID = id
            failedURL = notification.userInfo?["url"] as? URL
        }
        .onChange(of: tabManager.activeTab?.id) { _, _ in failedTabID = nil; failedURL = nil }
    }

    private func retry() {
        guard let tab = tabManager.activeTab else { return }
        let retryURL = failedURL ?? tab.url
        failedTabID = nil
        failedURL = nil
        if let retryURL { tab.navigate(to: retryURL) } else { tab.reload() }
    }
}

/// One continuous toolbar aligns window controls and navigation above the page and rail.
private struct BrowserToolbar: View {
    @ObservedObject var tabManager: TabManager
    var showsWindowControls: Bool

    var body: some View {
        if showsWindowControls || tabManager.activeTab?.url != nil {
            HStack(spacing: 2) {
                if showsWindowControls { CompactWindowControls() }
                if let tab = tabManager.activeTab, tab.url != nil {
                    NavigationControls(tab: tab)
                    URLBar(tabID: tab.id, themeColor: tab.themeColor, mixedContentStatus: nil,
                           isIncognito: tab.isIncognito, tab: tab) { input in
                        guard let url = NavigationResolver.resolve(input) else { return }
                        tab.navigate(to: url)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.trailing, 4)
            .frame(height: 36)
            .background(WindowDragArea())
        }
    }
}
