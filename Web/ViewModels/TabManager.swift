import SwiftUI
import Combine
import Foundation
import WebKit

class TabManager: ObservableObject {
    @Published var tabs: [Tab] = [] {
        didSet { observeSessionTabs(); persistSession() }
    }
    @Published var activeTab: Tab? {
        didSet { persistSession() }
    }
    @Published var recentlyClosedTabs: [Tab] = []
    
    private let maxRecentlyClosedTabs = 10
    private let maxConcurrentTabs = 50
    private var hibernationSubscription: AnyCancellable?
    private var collectionObserver: NSObjectProtocol?
    private var lifecycleSubscriptions = Set<AnyCancellable>()
    private var tabSubscriptions = Set<AnyCancellable>()
    private let sessionStore: SessionStore
    private let sessionIdentifier: UUID
    private var isRestoringSession = true
    private var isWindowClosed = false
    
    init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
        let registration = sessionStore.registerWindow()
        self.sessionIdentifier = registration.id
        if let restored = registration.restored, !restored.tabs.isEmpty {
            for item in restored.tabs {
                let tab = Tab(url: item.url.flatMap(URL.init(string:)))
                tab.title = item.title
                tab.isPinned = item.isPinned
                tab.zoomScale = item.zoomScale
                tabs.append(tab)
            }
            let selected = tabs[min(max(0, restored.activeIndex), tabs.count - 1)]
            normalizePinnedOrder()
            setActiveTab(selected)
        } else {
            createNewTab()
        }
        isRestoringSession = false
        observeSessionTabs()
        setupHibernationIntegration()
        setupWebViewCollection()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sessionStore.refreshPreference()
                self?.persistSession()
            }
            .store(in: &lifecycleSubscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.persistSession()
                self?.sessionStore.flush()
            }
            .store(in: &lifecycleSubscriptions)
        persistSession()
    }

    // MARK: - Session lifecycle

    private func observeSessionTabs() {
        tabSubscriptions.removeAll()
        for tab in tabs {
            // Window chrome reads the active tab through this manager. Forward
            // changes so the first navigation also reveals its address controls.
            tab.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &tabSubscriptions)
            tab.objectWillChange
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.persistSession() }
                .store(in: &tabSubscriptions)
        }
    }

    private func persistSession() {
        guard !isRestoringSession, !isWindowClosed else { return }
        var snapshots: [SessionTabSnapshot] = []
        var activeIndex = 0
        for tab in tabs {
            guard let item = SessionTabSnapshot(url: tab.url, title: tab.title,
                                                isPinned: tab.isPinned, zoomScale: tab.zoomScale,
                                                isPrivate: tab.isIncognito) else { continue }
            if tab.id == activeTab?.id { activeIndex = snapshots.count }
            snapshots.append(item)
        }
        sessionStore.update(WindowSessionSnapshot(tabs: snapshots, activeIndex: activeIndex), for: sessionIdentifier)
    }

    /// Called from the owning NSWindow before SwiftUI and WebKit release their references.
    /// This cannot rely on deinit because script handlers can keep the window graph alive.
    func closeWindow() {
        guard !isWindowClosed else { return }
        persistSession()
        isWindowClosed = true
        lifecycleSubscriptions.removeAll()
        tabSubscriptions.removeAll()
        hibernationSubscription?.cancel()
        if let collectionObserver {
            NotificationCenter.default.removeObserver(collectionObserver)
            self.collectionObserver = nil
        }
        for tab in tabs {
            tab.dispose()
            if tab.isIncognito { IncognitoSession.shared.closeIncognitoTab(tab) }
        }
        activeTab = nil
        tabs = []
        recentlyClosedTabs = []
        sessionStore.closeWindow(sessionIdentifier)
        sessionStore.flush()
    }

    private func normalizePinnedOrder() {
        let reordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        if reordered.map(\.id) != tabs.map(\.id) { tabs = reordered }
    }

    func togglePin(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.isPinned.toggle()
        normalizePinnedOrder()
        persistSession()
    }

    @discardableResult
    func duplicateTab(_ tab: Tab) -> Tab? {
        guard tabs.contains(where: { $0.id == tab.id }) else { return nil }
        guard tab.url == nil || tab.url.map(SessionTabSnapshot.isRestorableURL) == true else { return nil }
        let duplicate = createNewTab(url: tab.url, isIncognito: tab.isIncognito)
        duplicate.title = tab.title
        duplicate.zoomScale = tab.zoomScale
        if let source = tabs.firstIndex(where: { $0.id == tab.id }),
           let destination = tabs.firstIndex(where: { $0.id == duplicate.id }), !tab.isPinned {
            let moved = tabs.remove(at: destination)
            tabs.insert(moved, at: min(source + 1, tabs.count))
        }
        persistSession()
        return duplicate
    }

    /// Preserve the active copy, then pinned copies. Never merge private and normal tabs.
    @discardableResult
    func closeDuplicateTabs() -> Int {
        var seen = Set<String>()
        var closing: [Tab] = []
        let prioritized = tabs.sorted { lhs, rhs in
            if lhs.id == rhs.id { return false }
            if lhs.id == activeTab?.id { return true }
            if rhs.id == activeTab?.id { return false }
            return lhs.isPinned && !rhs.isPinned
        }
        for tab in prioritized {
            guard let url = tab.url else { continue }
            let key = (tab.isIncognito ? "private:" : "normal:") + url.absoluteString
            if !seen.insert(key).inserted, !tab.isPinned { closing.append(tab) }
        }
        closing.forEach(closeTab)
        return closing.count
    }

    // MARK: - Tab Operations
    @discardableResult
    func createNewTab(url: URL? = nil, isIncognito: Bool = false) -> Tab {
        let tab: Tab
        
        if isIncognito {
            // Create incognito tab through IncognitoSession
            tab = IncognitoSession.shared.createIncognitoTab(url: url)
        } else {
            tab = Tab(url: url, isIncognito: isIncognito)
        }
        
        tabs.append(tab)
        setActiveTab(tab)
        
        // Manage memory by hibernating old tabs
        manageTabMemory()
        
        return tab
    }
    
    @discardableResult
    func createNewTabInBackground(url: URL? = nil, isIncognito: Bool = false) -> Tab {
        let tab: Tab
        
        if isIncognito {
            // Create incognito tab through IncognitoSession
            tab = IncognitoSession.shared.createIncognitoTab(url: url)
        } else {
            tab = Tab(url: url, isIncognito: isIncognito)
        }
        
        tabs.append(tab)
        // Note: We do NOT call setActiveTab(tab) for background tabs
        
        // Manage memory by hibernating old tabs
        manageTabMemory()
        
        return tab
    }
    
    @discardableResult
    func createIncognitoTab(url: URL? = nil) -> Tab {
        return createNewTab(url: url, isIncognito: true)
    }
    
    func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        
        tab.dispose()

        // Handle incognito tab closure
        if tab.isIncognito {
            IncognitoSession.shared.closeIncognitoTab(tab)
        } else {
            // Add to recently closed (only for regular tabs)
            recentlyClosedTabs.insert(tab, at: 0)
            if recentlyClosedTabs.count > maxRecentlyClosedTabs {
                recentlyClosedTabs.removeLast()
            }
        }
        
        tabs.remove(at: index)
        
        // Select new active tab
        if activeTab?.id == tab.id {
            if index < tabs.count {
                setActiveTab(tabs[index])
            } else if index > 0 {
                setActiveTab(tabs[index - 1])
            } else {
                activeTab = nil
                // Notify that no active tab is available (context status should update)
                NotificationCenter.default.post(
                    name: .pageNavigationCompleted,
                    object: nil
                )
            }
        }
        
        // Create new tab if none remain
        if tabs.isEmpty {
            createNewTab()
        }
    }
    
    func reopenLastClosedTab() -> Tab? {
        guard let lastClosed = recentlyClosedTabs.first else { return nil }
        
        recentlyClosedTabs.removeFirst()
        let newTab = createNewTab(url: lastClosed.url, isIncognito: lastClosed.isIncognito)
        newTab.title = lastClosed.title
        newTab.favicon = lastClosed.favicon
        newTab.zoomScale = lastClosed.zoomScale
        
        return newTab
    }
    
    func setActiveTab(_ tab: Tab) {
        // Don't do anything if this tab is already active
        guard tabs.contains(where: { $0.id == tab.id }), activeTab?.id != tab.id else { return }
        
        // Deactivate current tab
        activeTab?.isActive = false
        
        // Activate new tab
        activeTab = tab
        tab.isActive = true
        tab.wakeUp() // Wake up if hibernated
        
        // CRITICAL: Immediately update URLSynchronizer for instant URL bar updates
        URLSynchronizer.shared.updateFromTabSwitch(
            tabID: tab.id,
            url: tab.url,
            title: tab.title,
            isLoading: tab.isLoading,
            progress: tab.estimatedProgress,
            isHibernated: tab.isHibernated
        )
        
        // Notify that the active tab changed (for AI context status updates)
        NotificationCenter.default.post(
            name: .tabDidBecomeActive,
            object: tab
        )
        
        NotificationCenter.default.post(
            name: .pageNavigationCompleted,
            object: tab.id
        )
        
        // Tab switched successfully
    }
    
    func moveTab(from source: IndexSet, to destination: Int) {
        // Enhanced tab reordering with animation support
        guard let sourceIndex = source.first, 
              sourceIndex != destination,
              sourceIndex >= 0 && sourceIndex < tabs.count,
              destination >= 0 && destination <= tabs.count else {
            return
        }
        
        // Perform the move with smooth animation
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            tabs.move(fromOffsets: source, toOffset: destination)
            normalizePinnedOrder()
        }
        
        // Maintain active tab reference after reordering
        if let activeTab = activeTab, let newIndex = tabs.firstIndex(where: { $0.id == activeTab.id }) {
            // Update any tab order-dependent logic here if needed
        }
    }
    
    // Enhanced reordering with better validation
    func moveTabSafely(fromIndex: Int, toIndex: Int) -> Bool {
        guard tabs.indices.contains(fromIndex), toIndex >= 0, toIndex <= tabs.count else { return false }
        let target = min(toIndex, tabs.count - 1)
        guard target != fromIndex, tabs[fromIndex].isPinned == tabs[target].isPinned else { return false }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: target)
        return true
    }

    // MARK: - Memory Management & Hibernation Integration
    
    private func setupHibernationIntegration() {
        // Listen for hibernation evaluation requests
        hibernationSubscription = NotificationCenter.default
            .publisher(for: .hibernationEvaluationRequested)
            .sink { [weak self] _ in
                self?.evaluateTabsForHibernation()
            }
    }
    
    private func manageTabMemory() {
        // Use the new TabHibernationManager for intelligent memory management
        evaluateTabsForHibernation()
    }
    
    private func evaluateTabsForHibernation() {
        // Delegate hibernation decisions to the TabHibernationManager
        TabHibernationManager.shared.evaluateTabs(tabs, activeTab: activeTab)
    }
    
    private func setupWebViewCollection() {
        // Listen for WebView collection requests from BackgroundResourceManager
        collectionObserver = NotificationCenter.default.addObserver(forName: .collectActiveWebViews, object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let collector = userInfo["collector"] as? (WKWebView) -> Void else { return }
            
            // Collect all active WebViews from tabs
            for tab in self.tabs {
                if let webView = tab.webView {
                    collector(webView)
                }
            }
        }
    }
    
    deinit {
        hibernationSubscription?.cancel()
        if let collectionObserver { NotificationCenter.default.removeObserver(collectionObserver) }
        sessionStore.closeWindow(sessionIdentifier)
        let detachedTabs = tabs
        DispatchQueue.main.async {
            for tab in detachedTabs {
                tab.dispose()
                if tab.isIncognito { IncognitoSession.shared.closeIncognitoTab(tab) }
            }
        }
    }
    
    // MARK: - Additional Tab Operations
    func closeOtherTabs(except tab: Tab) {
        let tabsToClose = tabs.filter { $0.id != tab.id && !$0.isPinned }
        for tabToClose in tabsToClose {
            closeTab(tabToClose)
        }
    }
    
    func closeTabsToTheRight(of tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        
        let tabsToClose = Array(tabs.suffix(from: index + 1)).filter { !$0.isPinned }
        for tabToClose in tabsToClose {
            closeTab(tabToClose)
        }
    }
    
    // MARK: - Search and Filter
    func searchTabs(query: String) -> [Tab] {
        guard !query.isEmpty else { return tabs }
        
        return tabs.filter { tab in
            tab.title.lowercased().contains(query.lowercased()) ||
            tab.url?.absoluteString.lowercased().contains(query.lowercased()) == true
        }
    }
    
    // MARK: - Tab Navigation
    func selectNextTab() {
        guard let currentTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id }) else { return }
        
        let nextIndex = (currentIndex + 1) % tabs.count
        setActiveTab(tabs[nextIndex])
    }
    
    func selectPreviousTab() {
        guard let currentTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentTab.id }) else { return }
        
        let previousIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
        setActiveTab(tabs[previousIndex])
    }
    
    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        setActiveTab(tabs[index])
    }
    
    func selectTabByNumber(_ number: Int) {
        let index = number - 1 // Convert 1-based to 0-based index
        selectTab(at: index)
    }
    
    // MARK: - Keyboard-based Tab Reordering
    
    /// Move the active tab one position to the left/up
    func moveActiveTabBackward() -> Bool {
        guard let activeTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id }),
              currentIndex > 0 else {
            return false
        }
        
        return moveTabSafely(fromIndex: currentIndex, toIndex: currentIndex - 1)
    }
    
    /// Move the active tab one position to the right/down
    func moveActiveTabForward() -> Bool {
        guard let activeTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id }),
              currentIndex < tabs.count - 1 else {
            return false
        }
        
        return moveTabSafely(fromIndex: currentIndex, toIndex: currentIndex + 1)
    }
    
    /// Move the active tab to the beginning of the tab list
    func moveActiveTabToStart() -> Bool {
        guard let activeTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id }),
              currentIndex > 0 else {
            return false
        }
        
        return moveTabSafely(fromIndex: currentIndex, toIndex: 0)
    }
    
    /// Move the active tab to the end of the tab list
    func moveActiveTabToEnd() -> Bool {
        guard let activeTab = activeTab,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id }),
              currentIndex < tabs.count - 1 else {
            return false
        }
        
        return moveTabSafely(fromIndex: currentIndex, toIndex: tabs.count - 1)
    }
}
