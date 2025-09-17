import Foundation
import SwiftUI
import WebKit

enum TabDisplayMode: String, CaseIterable {
    case sidebar = "sidebar"
    case topBar = "topBar"
    case hidden = "hidden"
}

struct TabDisplayView: View {
    @ObservedObject var tabManager: TabManager
    @AppStorage("tabDisplayMode") private var displayMode: TabDisplayMode = .sidebar
    @AppStorage("hideTopBar") private var hideTopBar: Bool = false
    @State private var isEdgeToEdgeMode: Bool = false
    @State private var showSidebarOnHover: Bool = false
    @State private var showTopBarOnHover: Bool = false
    @State private var showBottomSearchOnHover: Bool = false
    @State private var showHoverableURLBar: Bool = false
    @State private var hideTimer: Timer?
    @State private var topTabAutoHideTimer: Timer?
    @State private var showTopTabTemporary: Bool = false

    var body: some View {
        mainView
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: displayMode)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isEdgeToEdgeMode)
            .animation(.easeInOut(duration: 0.2), value: showSidebarOnHover)
            .animation(.easeInOut(duration: 0.2), value: showTopBarOnHover)
            .onReceive(NotificationCenter.default.publisher(for: .toggleTabDisplay)) { _ in
                toggleTabDisplay()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEdgeToEdge)) { _ in
                toggleEdgeToEdgeMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTabRequested)) { _ in
                tabManager.createNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTabInBackgroundRequested)) {
                notification in
                if let userInfo = notification.userInfo,
                    let url = userInfo["url"] as? URL
                {
                    tabManager.createNewTabInBackground(url: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTabRequested)) { _ in
                if let activeTab = tabManager.activeTab {
                    tabManager.closeTab(activeTab)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reopenTabRequested)) { _ in
                _ = tabManager.reopenLastClosedTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTabRequested)) { _ in
                tabManager.selectNextTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .previousTabRequested)) { _ in
                tabManager.selectPreviousTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectTabByNumber)) {
                notification in
                if let number = notification.object as? Int {
                    tabManager.selectTabByNumber(number)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNewTabWithURL)) {
                notification in
                if let url = notification.object as? URL {
                    tabManager.createNewTab(url: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTopBar)) { _ in
                hideTopBar.toggle()
                if hideTopBar {
                    startTopTabAutoHideTimer()
                } else {
                    topTabAutoHideTimer?.invalidate()
                    showTopTabTemporary = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateCurrentTab)) {
                notification in
                if let url = notification.object as? URL {
                    if let activeTab = tabManager.activeTab {
                        activeTab.navigate(to: url)
                    } else {
                        _ = tabManager.createNewTab(url: url)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadRequested)) { _ in
                if let activeTab = tabManager.activeTab {
                    activeTab.reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusAddressBarRequested)) { _ in
                NotificationCenter.default.post(name: .focusURLBarRequested, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarkCurrentPageRequested)) {
                _ in
                handleBookmarkCurrentPage()
            }
            .onAppear {
                startTopTabAutoHideTimer()
            }
            .onDisappear {
                hideTimer?.invalidate()
                topTabAutoHideTimer?.invalidate()
            }
    }

    private var mainView: some View {
        GeometryReader { geometry in
            ZStack {
                contentArea
                urlBarOverlay

                // Security warning overlay for certificate validation issues
                SecurityWarningSheet()

                // Safe Browsing threat warning overlay for malware/phishing protection
                SafeBrowsingWarningSheet()
            }
        }
    }

    private var contentArea: some View {
        VStack(spacing: 0) {
            topBarSection
            webContentSection
        }
    }

    @ViewBuilder
    private var topBarSection: some View {
        if displayMode == .topBar && shouldShowTopTab {
            TopBarTabView(tabManager: tabManager)
                .frame(height: 40)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var webContentSection: some View {
        HStack(spacing: 0) {
            sidebarSection
            WebContentArea(tabManager: tabManager)
                .clipped()
            AISidebar(tabManager: tabManager)
        }
    }

    @ViewBuilder
    private var sidebarSection: some View {
        if displayMode == .sidebar && (!isEdgeToEdgeMode || showSidebarOnHover) {
            SidebarTabView(tabManager: tabManager)
                .frame(width: 50)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .opacity(isEdgeToEdgeMode && !showSidebarOnHover ? 0 : 1)
                .onHover { hovering in
                    if isEdgeToEdgeMode {
                        handleSidebarHover(hovering)
                    }
                }
        }
    }

    @ViewBuilder
    private var urlBarOverlay: some View {
        if hideTopBar || isEdgeToEdgeMode {
            VStack {
                urlBarContent
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var urlBarContent: some View {
        if let activeTab = tabManager.activeTab {
            HoverableURLBar(
                tabID: activeTab.id,
                themeColor: activeTab.themeColor,
                onSubmit: { urlString in
                    if let newURL = URL(string: urlString) {
                        activeTab.navigate(to: newURL)
                    }
                },
                tabManager: tabManager
            )
        } else {
            HoverableURLBar(
                tabID: UUID(),
                themeColor: nil,
                onSubmit: { urlString in
                    if let url = URL(string: urlString) {
                        _ = tabManager.createNewTab(url: url)
                    }
                },
                tabManager: tabManager
            )
        }
    }

    // Computed property to determine if top tab should be shown
    private var shouldShowTopTab: Bool {
        // In borderless mode with hidden top bar: show temporarily or on hover
        if hideTopBar {
            return showTopTabTemporary || showTopBarOnHover
        }
        // In edge-to-edge mode: show on hover only
        else if isEdgeToEdgeMode {
            return showTopBarOnHover
        }
        // Normal mode: always show
        else {
            return true
        }
    }

    private func startTopTabAutoHideTimer() {
        // Only start timer in borderless mode with hidden top bar
        guard hideTopBar else { return }

        // Cancel existing timer
        topTabAutoHideTimer?.invalidate()

        // Show tab temporarily
        showTopTabTemporary = true

        // Set timer to hide after 2 seconds
        topTabAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                showTopTabTemporary = false
            }
        }
    }

    @ViewBuilder
    private func edgeToEdgeHoverZones(geometry: GeometryProxy) -> some View {
        ZStack {
            // Left edge hover zone for sidebar (better usability)
            if displayMode == .sidebar {
                HStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 12)  // Keep consistent small trigger zone
                        .onHover { hovering in
                            handleSidebarHover(hovering)
                        }
                    Spacer()
                }
            }

            // Top edge hover zone for top bar (better usability)
            if displayMode == .topBar {
                VStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)  // Increased from 3px to 12px for better UX
                        .onHover { hovering in
                            handleTopBarHover(hovering)
                        }
                    Spacer()
                }
            }

            // Bottom edge hover zone for hoverable URL bar (when top bar hidden)
            if hideTopBar || displayMode == .hidden {
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)  // Increased from 3px to 12px for better UX
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showHoverableURLBar = hovering
                            }
                        }
                }
            }
        }
    }

    private func toggleTabDisplay() {
        switch displayMode {
        case .sidebar:
            displayMode = .topBar
        case .topBar:
            displayMode = .sidebar
        case .hidden:
            displayMode = .sidebar
        }
    }

    private func toggleEdgeToEdgeMode() {
        isEdgeToEdgeMode.toggle()

        // Reset hover states when exiting edge-to-edge
        if !isEdgeToEdgeMode {
            showSidebarOnHover = false
            showTopBarOnHover = false
            showBottomSearchOnHover = false
            showHoverableURLBar = false
        }
    }

    private func handleSidebarHover(_ hovering: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil

        if hovering {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showSidebarOnHover = true
            }
        } else {
            // Add a longer delay before hiding to allow clicking on tabs
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showSidebarOnHover = false
                }
            }
        }
    }

    private func handleTopBarHover(_ hovering: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showTopBarOnHover = hovering
        }

        // In borderless mode, restart the auto-hide timer when hover ends
        if hideTopBar && !hovering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startTopTabAutoHideTimer()
            }
        }
    }

    // MARK: - Helper Methods for Keyboard Shortcuts

    private func handleHistoryRequest() {
        // TODO: Show history panel/view - placeholder for future UI implementation
        if AppLog.isVerboseEnabled { print("History panel requested") }
    }

    private func handleBookmarkRequest() {
        // Bookmark current page
        if let activeTab = tabManager.activeTab,
            let url = activeTab.url
        {
            let title = activeTab.title.isEmpty ? url.absoluteString : activeTab.title
            BookmarkService.shared.quickBookmark(url: url.absoluteString, title: title)
        }
    }

    private func handleBookmarkCurrentPage() {
        // Bookmark current page when requested via notification
        if let activeTab = tabManager.activeTab,
            let url = activeTab.url
        {
            let title = activeTab.title.isEmpty ? url.absoluteString : activeTab.title
            BookmarkService.shared.quickBookmark(url: url.absoluteString, title: title)
        }
    }

    private func handleDownloadsRequest() {
        // Show downloads panel
        DownloadManager.shared.isVisible.toggle()
    }
}

// Web content area wrapper with rounded corners and margin
struct WebContentArea: View {
    @ObservedObject var tabManager: TabManager
    @AppStorage("tabDisplayMode") private var displayMode: TabDisplayMode = .sidebar
    @AppStorage("hideTopBar") private var hideTopBar: Bool = false
    @State private var isEdgeToEdgeMode: Bool = false
    @State private var showFindOverlay: Bool = false
    @State private var findQuery: String = ""

    // Use centralized URL synchronizer
    @ObservedObject private var urlSynchronizer = URLSynchronizer.shared

    // Network error handling state
    @State private var showNoInternetPage: Bool = false
    @State private var networkError: Error?
    @State private var failedURL: URL?

    // Helper to determine if tab is in browsing mode (not new tab mode)
    private func isTabInBrowsingMode(_ tab: Web.Tab) -> Bool {
        return tab.url != nil || tab.isLoading || (tab.title != "New Tab" && !tab.title.isEmpty)
    }

    // Computed property to determine if URL bar should be shown
    private var shouldShowURLBar: Bool {
        guard let activeTab = tabManager.activeTab else { return false }
        return isTabInBrowsingMode(activeTab)
    }

    // MARK: - Network Error Handling Methods

    private func handleNoInternetConnectionNotification(_ notification: Notification) {
        // Check if this notification is for the current active tab
        guard let activeTab = tabManager.activeTab,
            let notificationTabID = notification.object as? UUID,
            notificationTabID == activeTab.id
        else {
            return
        }

        // Extract error and URL information from notification
        if let userInfo = notification.userInfo {
            networkError = userInfo["error"] as? Error
            failedURL = userInfo["url"] as? URL
        }

        // Show the no internet page with animation
        withAnimation(.easeInOut(duration: 0.4)) {
            showNoInternetPage = true
        }
    }

    private func retryConnection() {
        guard let activeTab = tabManager.activeTab else { return }

        let networkMonitor = NetworkConnectivityMonitor.shared

        // Check network connectivity before retrying
        if networkMonitor.hasInternetConnection {
            // Hide the no internet page
            withAnimation(.easeInOut(duration: 0.4)) {
                showNoInternetPage = false
            }

            // Clear error state
            networkError = nil
            failedURL = nil

            // Retry loading the page
            if let url = failedURL ?? activeTab.url {
                activeTab.navigate(to: url)
            } else {
                // If no URL to retry, reload current page
                activeTab.reload()
            }
        } else {
            // Still no internet connection - shake animation or show error
            // For now, just keep showing the no internet page
            NSLog("🔴 Retry attempted but still no internet connection")
        }
    }

    var body: some View {
        // Add rounded wrapper with 1px margin
        VStack(spacing: 0) {
            // URL bar (hidden in edge-to-edge mode, when hideTopBar is enabled, or when showing new tab)
            if !isEdgeToEdgeMode && !hideTopBar && shouldShowURLBar {
                HStack(spacing: 12) {
                    // Navigation controls
                    if let activeTab = tabManager.activeTab {
                        NavigationControls(tab: activeTab)
                    }

                    // URL bar with URLSynchronizer integration
                    Group {
                        if let activeTab = tabManager.activeTab {
                            URLBar(
                                tabID: activeTab.id,
                                themeColor: activeTab.themeColor,
                                mixedContentStatus: nil,
                                onSubmit: navigateToURL
                            )
                        } else {
                            URLBar(
                                tabID: UUID(),  // Temporary ID for new tab creation
                                themeColor: nil,
                                mixedContentStatus: nil,
                                onSubmit: navigateToURL
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)  // Further reduced for even more minimal height
                .background(
                    ZStack {
                        // Clean base with subtle material and window drag capability
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.3)
                            .background(WindowDragArea())

                        // Next-gen ambient gradient system
                        if let themeColor = tabManager.activeTab?.themeColor {
                            // Primary ambient glow (top-left origin)
                            Rectangle()
                                .fill(
                                    EllipticalGradient(
                                        colors: [
                                            Color(themeColor).opacity(0.08),
                                            Color(themeColor).opacity(0.05),
                                            Color(themeColor).opacity(0.02),
                                            Color.clear,
                                        ],
                                        center: .init(x: 0.1, y: 0.0),
                                        startRadiusFraction: 0.1,
                                        endRadiusFraction: 1.2
                                    )
                                )
                                .animation(
                                    .spring(response: 0.8, dampingFraction: 0.8), value: themeColor)

                            // Secondary ambient point (center-right)
                            Rectangle()
                                .fill(
                                    EllipticalGradient(
                                        colors: [
                                            Color.clear,
                                            Color(themeColor).opacity(0.04),
                                            Color(themeColor).opacity(0.07),
                                            Color(themeColor).opacity(0.03),
                                            Color.clear,
                                        ],
                                        center: .init(x: 0.85, y: 0.5),
                                        startRadiusFraction: 0.15,
                                        endRadiusFraction: 0.9
                                    )
                                )
                                .animation(
                                    .spring(response: 0.8, dampingFraction: 0.8), value: themeColor)

                            // Tertiary diffused glow (bottom spread)
                            Rectangle()
                                .fill(
                                    EllipticalGradient(
                                        colors: [
                                            Color.clear,
                                            Color.clear,
                                            Color(themeColor).opacity(0.03),
                                            Color(themeColor).opacity(0.06),
                                            Color(themeColor).opacity(0.02),
                                            Color.clear,
                                        ],
                                        center: .init(x: 0.4, y: 1.0),
                                        startRadiusFraction: 0.2,
                                        endRadiusFraction: 0.8
                                    )
                                )
                                .animation(
                                    .spring(response: 0.8, dampingFraction: 0.8), value: themeColor)
                        } else {
                            // Subtle fallback ambient system
                            Rectangle()
                                .fill(
                                    EllipticalGradient(
                                        colors: [
                                            Color.accentBeam.opacity(0.04),
                                            Color.accentBeam.opacity(0.02),
                                            Color.clear,
                                        ],
                                        center: .init(x: 0.2, y: 0.0),
                                        startRadiusFraction: 0.15,
                                        endRadiusFraction: 1.0
                                    )
                                )

                            Rectangle()
                                .fill(
                                    EllipticalGradient(
                                        colors: [
                                            Color.clear,
                                            Color.accentBeam.opacity(0.03),
                                            Color.accentBeam.opacity(0.01),
                                            Color.clear,
                                        ],
                                        center: .init(x: 0.7, y: 1.0),
                                        startRadiusFraction: 0.3,
                                        endRadiusFraction: 0.7
                                    )
                                )
                        }

                        // Minimal surface highlight
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.015),
                                        Color.clear,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                )
            }

            // Web content with smart status bar overlay and network error handling
            ZStack(alignment: .bottom) {
                if showNoInternetPage {
                    // Show no internet connection page
                    NoInternetConnectionView(
                        onRetry: {
                            retryConnection()
                        },
                        onGoBack: {
                            showNoInternetPage = false
                            networkError = nil
                            failedURL = nil
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if let activeTab = tabManager.activeTab {
                    WebContentView(tab: activeTab, tabManager: tabManager)
                        .overlay(alignment: .topTrailing) {
                            if showFindOverlay {
                                FindOverlay(
                                    query: $findQuery,
                                    onClose: { withAnimation { showFindOverlay = false } },
                                    onNext: {
                                        if !findQuery.isEmpty {
                                            activeTab.findInPage(findQuery, forward: true)
                                        }
                                    },
                                    onPrev: {
                                        if !findQuery.isEmpty {
                                            activeTab.findInPage(findQuery, forward: false)
                                        }
                                    },
                                    onSubmit: {
                                        if !findQuery.isEmpty {
                                            activeTab.findInPage(findQuery, forward: true)
                                        }
                                    }
                                )
                                .padding(.top, 8)
                                .padding(.trailing, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .zIndex(50)
                            }
                        }
                } else {
                    NewTabView()
                }
            }
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onReceive(NotificationCenter.default.publisher(for: .showNoInternetConnection)) {
            notification in
            handleNoInternetConnectionNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEdgeToEdge)) { _ in
            isEdgeToEdgeMode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInPageRequested)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showFindOverlay.toggle()
            }
            if showFindOverlay == true {
                findQuery = ""
            }
        }
        .background(
            // Add drag area to the padding/margin area around web content
            WindowDragArea(allowsHitTesting: false)  // Don't interfere with content clicks
                .background(Color.clear)
        )
        .padding(2)  // 2px margin as requested
        .onAppear {
            // Sync with URLSynchronizer on appear
            if let activeTab = tabManager.activeTab {
                URLSynchronizer.shared.updateFromTabSwitch(
                    tabID: activeTab.id,
                    url: activeTab.url,
                    title: activeTab.title,
                    isLoading: activeTab.isLoading,
                    progress: activeTab.estimatedProgress,
                    isHibernated: activeTab.isHibernated
                )
            }
        }
    }

    private func navigateToURL(_ url: String) {
        guard let activeTab = tabManager.activeTab else { return }

        let processedURL: URL?

        // Use same logic as URLBar for consistency
        if isValidURL(url) {
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                processedURL = URL(string: url)
            } else {
                processedURL = URL(string: "https://\(url)")
            }
        } else {
            // Search Google for anything that doesn't look like a URL
            let query = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            processedURL = URL(string: "https://www.google.com/search?q=\(query)")
        }

        guard let validURL = processedURL else { return }

        // Navigate to URL - tab manages its own state
        activeTab.navigate(to: validURL)
    }

    private func isValidURL(_ string: String) -> Bool {
        // Check if it already has a scheme
        if string.hasPrefix("http://") || string.hasPrefix("https://") {
            return URL(string: string) != nil
        }

        // Check if it looks like a domain (contains . and no spaces)
        if string.contains(".") && !string.contains(" ") {
            // Make sure it's not just a decimal number
            if !string.allSatisfy({ $0.isNumber || $0 == "." }) {
                return true
            }
        }

        return false
    }
}
