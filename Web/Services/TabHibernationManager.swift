import Combine
import Foundation
import WebKit

/// Advanced tab hibernation manager that provides true resource management
/// with actual WKWebView destruction/recreation and intelligent hibernation policies
class TabHibernationManager: ObservableObject {
    static let shared = TabHibernationManager()

    // MARK: - Published Properties

    @Published var hibernatedTabs: Set<UUID> = []
    @Published var isHibernationActive: Bool = false
    @Published var memoryFreedBytes: Int64 = 0

    // MARK: - Configuration

    struct HibernationPolicy: Codable {
        var timeThreshold: TimeInterval = 1800  // 30 minutes default
        var memoryPressureEnabled: Bool = true
        var maxActiveWebViews: Int = 8
        var excludedDomains: Set<String> = ["localhost", "127.0.0.1", "192.168."]
        var protectFormData: Bool = true
        var protectMediaPlayback: Bool = true
        var protectDownloads: Bool = true

        // Preset policies for easy configuration
        static let conservative = HibernationPolicy(timeThreshold: 3600, maxActiveWebViews: 12)
        static let balanced = HibernationPolicy(timeThreshold: 1800, maxActiveWebViews: 8)
        static let aggressive = HibernationPolicy(timeThreshold: 900, maxActiveWebViews: 4)
    }

    // MARK: - Private Properties

    private var currentPolicy: HibernationPolicy = .balanced
    private var hibernationTimer: Timer?
    private var memoryMonitorSubscription: AnyCancellable?
    private var hibernatedTabStates: [UUID: HibernatedTabData] = [:]

    private struct HibernatedTabData {
        let tabState: Tab.TabState
        let snapshot: NSImage?
        let hibernationTime: Date
        let memoryFreed: Int64
    }

    private init() {
        setupMemoryMonitoring()
        startPeriodicHibernationCheck()
        setupSuspensionNotifications()
    }

    deinit {
        hibernationTimer?.invalidate()
        memoryMonitorSubscription?.cancel()
    }

    // MARK: - Public Methods

    /// Updates the hibernation policy
    func updatePolicy(_ policy: HibernationPolicy) {
        currentPolicy = policy

        // Trigger immediate evaluation with new policy
        evaluateHibernationOpportunities()
    }

    /// Forces hibernation of a specific tab
    func forceHibernate(_ tab: Tab) {
        guard !tab.isActive && !tab.isHibernated else { return }

        performTrueHibernation(for: tab, reason: "Manual hibernation")
    }

    /// SwiftUI recreates the page through the browser's configured WebView factory.
    /// Creating a bare WKWebView here bypasses its delegates and loads the page twice.
    func wakeUpTab(_ tab: Tab) -> Bool {
        guard tab.isHibernated, let hibernatedData = hibernatedTabStates[tab.id] else {
            return false
        }
        tab.isHibernated = false
        tab.snapshot = hibernatedData.snapshot  // Keep snapshot until page loads

        // Remove from hibernated states
        hibernatedTabStates.removeValue(forKey: tab.id)
        hibernatedTabs.remove(tab.id)

        // Update memory tracking
        memoryFreedBytes = max(0, memoryFreedBytes - hibernatedData.memoryFreed)

        return true
    }

    /// Closing a tab must also release any private page snapshot held by this service.
    func forgetTab(_ id: UUID) {
        if let data = hibernatedTabStates.removeValue(forKey: id) {
            memoryFreedBytes = max(0, memoryFreedBytes - data.memoryFreed)
        }
        hibernatedTabs.remove(id)
    }

    /// Gets hibernation statistics for monitoring
    func getHibernationStats() -> HibernationStats {
        return HibernationStats(
            hibernatedCount: hibernatedTabs.count,
            memoryFreed: memoryFreedBytes,
            currentPolicy: currentPolicy,
            lastHibernationCheck: hibernationTimer?.fireDate ?? Date()
        )
    }

    /// Evaluates all tabs for hibernation opportunities
    func evaluateHibernationOpportunities() {
        let memoryStats = MemoryMonitor.shared.getMemoryStats()
        let shouldAggressivelyHibernate = memoryStats.shouldHibernate
        let maxActiveWebViews = min(currentPolicy.maxActiveWebViews, memoryStats.maxActiveWebViews)

        // Get all tabs from TabManager (we'll need to inject this dependency)
        // For now, we'll use a notification-based approach
        NotificationCenter.default.post(
            name: .hibernationEvaluationRequested,
            object: nil,
            userInfo: [
                "shouldAggressivelyHibernate": shouldAggressivelyHibernate,
                "maxActiveWebViews": maxActiveWebViews,
            ]
        )
    }

    // MARK: - Internal Methods (called by TabManager)

    /// Evaluates tabs for hibernation - called by TabManager
    func evaluateTabs(_ tabs: [Tab], activeTab: Tab?) {
        let memoryStats = MemoryMonitor.shared.getMemoryStats()
        let shouldAggressivelyHibernate = memoryStats.shouldHibernate
        let maxActiveWebViews = min(currentPolicy.maxActiveWebViews, memoryStats.maxActiveWebViews)

        // Determine whether the application is currently active (front-most)
        let isAppActive = NSApplication.shared.isActive

        // Get non-hibernated tabs with WebViews
        let activeWebViewTabs = tabs.filter { !$0.isHibernated && $0.webView != nil }

        // If we're under the limit and not under memory pressure **and** the app is active, no hibernation needed.
        // When the app is in background we still want to consider freeing resources even if under the limit.
        if isAppActive && activeWebViewTabs.count <= maxActiveWebViews
            && !shouldAggressivelyHibernate
        {
            return
        }

        // Protect active tab from hibernation when app is in background unless under memory pressure
        let protectActiveInBackground = !isAppActive && !shouldAggressivelyHibernate
        let effectiveActiveTab: Tab? = activeTab

        // Sort tabs by hibernation priority (LRU with exclusions)
        let hibernationCandidates = getHibernationCandidates(
            from: tabs,
            activeTab: effectiveActiveTab,
            protectActiveInBackground: protectActiveInBackground
        )

        // Determine how many tabs need to be hibernated
        let excessTabs = max(0, activeWebViewTabs.count - maxActiveWebViews)
        let targetHibernations =
            shouldAggressivelyHibernate ? max(excessTabs, activeWebViewTabs.count / 2) : excessTabs

        // Hibernate the appropriate number of tabs
        for tab in hibernationCandidates.prefix(targetHibernations) {
            performTrueHibernation(
                for: tab,
                reason: shouldAggressivelyHibernate ? "Memory pressure" : "Tab limit exceeded")
        }
    }

    // MARK: - Private Methods

    private func setupMemoryMonitoring() {
        memoryMonitorSubscription = MemoryMonitor.shared.$currentMemoryPressure
            .sink { [weak self] pressureLevel in
                if pressureLevel.shouldHibernateAggressively {
                    self?.evaluateHibernationOpportunities()
                }
            }
    }

    private func startPeriodicHibernationCheck() {
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) {
            [weak self] _ in
            self?.evaluateHibernationOpportunities()
        }
    }

    private func setupSuspensionNotifications() {
        // Listen for hibernation suspension
        NotificationCenter.default.addObserver(
            forName: .suspendHibernationEvaluation, object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("⏸️ Suspending hibernation evaluation timer")
            self?.hibernationTimer?.invalidate()
            self?.hibernationTimer = nil
        }

        // Listen for hibernation resumption
        NotificationCenter.default.addObserver(
            forName: .resumeHibernationEvaluation, object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("▶️ Resuming hibernation evaluation timer")
            self?.startPeriodicHibernationCheck()
        }
    }

    private func getHibernationCandidates(
        from tabs: [Tab],
        activeTab: Tab?,
        protectActiveInBackground: Bool
    ) -> [Tab] {
        let isAppActive = NSApplication.shared.isActive
        let excludeActive = isAppActive || protectActiveInBackground

        return
            tabs
            .filter { tab in
                // Exclude active tab (only if app is active), already hibernated, or tabs that should be protected
                return (excludeActive ? tab.id != activeTab?.id : true) && !tab.isHibernated
                    && tab.webView != nil && !shouldExcludeDomain(tab.url)
                    && {
                        if isAppActive {
                            // Normal protection rules
                            return !tab.shouldExcludeFromHibernation()
                        } else {
                            // In background, protect media playback, downloads, and form data to avoid data loss
                            return
                                !(tab.hasMediaPlayback || tab.hasActiveDownloads || tab.hasFormData)
                        }
                    }()
            }
            .filter { tab in
                // If the app is backgrounded, ignore the usual time threshold and hibernate immediately.
                // Otherwise honour the policy’s time threshold.
                if isAppActive {
                    return Date().timeIntervalSince(tab.lastAccessed) > currentPolicy.timeThreshold
                } else {
                    return true
                }
            }
            .sorted { tab1, tab2 in
                // Sort by last accessed time (oldest first) - LRU policy
                return tab1.lastAccessed < tab2.lastAccessed
            }
    }

    private func shouldExcludeDomain(_ url: URL?) -> Bool {
        guard let url = url else { return false }

        let host = url.host?.lowercased() ?? ""
        return currentPolicy.excludedDomains.contains { domain in
            host.contains(domain.lowercased())
        }
    }

    private func performTrueHibernation(for tab: Tab, reason: String) {
        guard let webView = tab.webView, !tab.isHibernated else { return }

        // Capture comprehensive state before destroying WebView
        tab.captureState()

        // Create snapshot before hibernation
        createHibernationSnapshot(for: tab, webView: webView) { [weak self, weak tab] snapshot in
            guard let self = self, let tab = tab,
                  tab.webView === webView, !tab.isActive, !tab.isHibernated else { return }

            // Estimate memory that will be freed (approximation)
            let estimatedMemoryFreed: Int64 = 150 * 1024 * 1024  // ~150MB per WebView

            // Store hibernated data
            let hibernatedData = HibernatedTabData(
                tabState: Tab.TabState(from: tab, webView: webView),
                snapshot: snapshot,
                hibernationTime: Date(),
                memoryFreed: estimatedMemoryFreed
            )

            self.hibernatedTabStates[tab.id] = hibernatedData

            DispatchQueue.main.async {
                guard tab.webView === webView, !tab.isActive, !tab.isHibernated else {
                    self.forgetTab(tab.id)
                    return
                }
                // Remove WebView from view hierarchy and memory
                webView.stopLoading()
                webView.pauseAllMediaPlayback(completionHandler: nil)
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.removeFromSuperview()
                tab.webView = nil

                // Update tab state
                tab.isHibernated = true
                tab.snapshot = snapshot

                // Update tracking
                self.hibernatedTabs.insert(tab.id)
                self.memoryFreedBytes += estimatedMemoryFreed
            }
        }
    }

    private func createHibernationSnapshot(
        for tab: Tab, webView: WKWebView, completion: @escaping (NSImage?) -> Void
    ) {
        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds

        // Use safe rect validation
        let safeBounds = SafeNumericConversions.validateSafeRect(bounds)
        guard safeBounds.width > 0 && safeBounds.height > 0 else {
            completion(nil)
            return
        }

        config.rect = safeBounds

        webView.takeSnapshot(with: config) { image, error in
            completion(image)
        }
    }
}

// MARK: - Supporting Types

extension TabHibernationManager {
    struct HibernationStats {
        let hibernatedCount: Int
        let memoryFreed: Int64
        let currentPolicy: HibernationPolicy
        let lastHibernationCheck: Date

        var formattedMemoryFreed: String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .memory
            return formatter.string(fromByteCount: memoryFreed)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let hibernationEvaluationRequested = Notification.Name("hibernationEvaluationRequested")
    static let tabHibernated = Notification.Name("tabHibernated")
    static let tabWokenUp = Notification.Name("tabWokenUp")
}
