import Combine
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers
import WebKit

class Tab: ObservableObject, Identifiable, Transferable, Equatable {
    let id = UUID()
    @Published var url: URL?
    @Published var title: String = "New Tab"
    @Published var favicon: NSImage?
    @Published var themeColor: NSColor?
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isIncognito: Bool = false
    @Published var isPinned: Bool = false
    @Published var lastAccessed: Date = Date()
    @Published var isActive: Bool = false

    // Performance optimization features
    @Published var isHibernated: Bool = false
    @Published var snapshot: NSImage?
    @Published var memoryUsage: Int64 = 0

    // Enhanced state preservation for true hibernation
    @Published var scrollPosition: CGPoint = .zero
    @Published var zoomScale: CGFloat = 1.0
    @Published var hasFormData: Bool = false
    @Published var hasMediaPlayback: Bool = false
    @Published var hasActiveDownloads: Bool = false
    private var preservedState: TabState?

    // Navigation history
    private(set) var backHistory: [HistoryEntry] = []
    private(set) var forwardHistory: [HistoryEntry] = []

    // WebView reference - keeping strong reference to prevent deallocation during tab switches
    private var _webView: WKWebView?

    // Track WebView ownership using associated objects
    private static var webViewOwnershipKey: UInt8 = 0

    var webView: WKWebView? {
        get { _webView }
        set {
            // CRITICAL: Prevent WebView sharing between tabs to fix content duplication bug
            if let newWebView = newValue {
                // Check if this WebView is already assigned to another tab
                let existingOwnerId =
                    objc_getAssociatedObject(newWebView, &Self.webViewOwnershipKey) as? UUID

                if let existingId = existingOwnerId, existingId != id {
                    if AppLog.isVerboseEnabled {
                        print(
                            "🚨 Attempt to assign WebView from another tab. Expected: \(id), got: \(existingId)"
                        )
                    }
                    return  // Reject assignment to prevent content bleeding
                }

                // Set ownership tracking for this WebView
                objc_setAssociatedObject(
                    newWebView, &Self.webViewOwnershipKey, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            _webView = newValue
        }
    }

    // Simple hibernation timer for backward compatibility
    private var hibernationTimer: Timer?
    private let hibernationThreshold: TimeInterval = 1800  // Increased to 30 minutes to prevent aggressive hibernation

    struct HistoryEntry {
        let url: URL
        let title: String
        let timestamp: Date
    }

    /// Comprehensive state preservation for true hibernation
    struct TabState: Codable {
        let url: URL?
        let title: String
        let scrollPosition: CGPoint
        let zoomScale: CGFloat
        let canGoBack: Bool
        let canGoForward: Bool
        let lastAccessed: Date
        let hasFormData: Bool
        let hasMediaPlayback: Bool
        let estimatedProgress: Double

        // Navigation history preservation
        let backHistoryURLs: [URL]
        let forwardHistoryURLs: [URL]

        init(from tab: Tab, webView: WKWebView?) {
            self.url = tab.url
            self.title = tab.title
            self.scrollPosition = tab.scrollPosition
            self.zoomScale = tab.zoomScale
            self.canGoBack = webView?.canGoBack ?? tab.canGoBack
            self.canGoForward = webView?.canGoForward ?? tab.canGoForward
            self.lastAccessed = tab.lastAccessed
            self.hasFormData = tab.hasFormData
            self.hasMediaPlayback = tab.hasMediaPlayback
            self.estimatedProgress = tab.estimatedProgress

            // Extract navigation history from WebView if available
            self.backHistoryURLs = webView?.backForwardList.backList.compactMap { $0.url } ?? []
            self.forwardHistoryURLs =
                webView?.backForwardList.forwardList.compactMap { $0.url } ?? []
        }
    }

    init(url: URL? = nil, isIncognito: Bool = false) {
        self.url = url
        self.isIncognito = isIncognito

        // Start simple hibernation timer
        startHibernationTimer()
    }

    /// Explicit teardown breaks script-handler/coordinator ownership cycles when a tab closes.
    func dispose() {
        TabHibernationManager.shared.forgetTab(id)
        hibernationTimer?.invalidate()
        hibernationTimer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        snapshot = nil
        preservedState = nil
        backHistory = []
        forwardHistory = []
        isActive = false
    }

    // MARK: - Navigation Methods
    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    func navigate(to url: URL) {
        self.url = url
        updateLastAccessed()

        // Trigger navigation in the webView if it exists
        if let webView = webView {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    // MARK: - Performance Management
    func hibernate() {
        // CRITICAL: Clean up JavaScript timers before hibernating to prevent CPU usage
        cleanupWebViewTimers()

        // Use TabHibernationManager for true resource hibernation
        TabHibernationManager.shared.forceHibernate(self)
    }

    func wakeUp() {
        guard isHibernated else { return }

        // SwiftUI creates the configured browser view once after waking.
        if TabHibernationManager.shared.wakeUpTab(self) {
            updateLastAccessed()
        }
    }

    // MARK: - Legacy Hibernation Support (Backward Compatibility)

    /// Legacy hibernation method - now delegates to TabHibernationManager
    func hibernateLegacy() {
        // Only hibernate if tab has been inactive for a very long time and not loading
        // Don't hibernate tabs that are actively loading or recently accessed
        guard !isActive && !isHibernated && !isLoading else { return }
        guard Date().timeIntervalSince(lastAccessed) > hibernationThreshold else { return }

        // Create snapshot before hibernating
        createSnapshot()

        // Keep WebView in memory but mark as hibernated for UI purposes
        // This prevents content loss while still indicating hibernated state
        isHibernated = true

        // Tab hibernated successfully
    }

    /// Legacy wake up method
    func wakeUpLegacy() {
        guard isHibernated else { return }

        isHibernated = false
        updateLastAccessed()

        // Tab woken up successfully
    }

    // MARK: - Enhanced State Preservation

    /// Captures comprehensive tab state for true hibernation
    func captureState() {
        guard let webView = webView else { return }

        // Capture current scroll position and zoom
        webView.evaluateJavaScript("window.scrollX") { [weak self] (x, _) in
            webView.evaluateJavaScript("window.scrollY") { [weak self] (y, _) in
                DispatchQueue.main.async {
                    self?.scrollPosition = CGPoint(
                        x: x as? Double ?? 0,
                        y: y as? Double ?? 0
                    )
                }
            }
        }

        // Capture zoom scale
        DispatchQueue.main.async { [weak self] in
            self?.zoomScale = webView.magnification
        }

        // Check for form data
        detectFormData(in: webView)

        // Check for media playback
        detectMediaPlayback(in: webView)

        // Create preserved state object
        preservedState = TabState(from: self, webView: webView)
    }

    /// Restores comprehensive tab state after hibernation
    func restoreState(to webView: WKWebView) {
        let state = preservedState
        preservedState = nil
        snapshot = nil
        guard let state else {
            webView.magnification = zoomScale.isFinite ? min(3, max(0.5, zoomScale)) : 1
            return
        }
        guard state.url == webView.url else { return }
        let zoom = state.zoomScale.isFinite ? min(3, max(0.5, state.zoomScale)) : 1
        let position = state.scrollPosition
        guard position.x.isFinite, position.y.isFinite else { return }
        let x = min(100_000_000, max(0, position.x))
        let y = min(100_000_000, max(0, position.y))
        webView.magnification = zoom
        webView.evaluateJavaScript("window.scrollTo(\(x), \(y));")
        scrollPosition = CGPoint(x: x, y: y)
        zoomScale = zoom
    }

    /// Detects if the page has form data that might be lost
    private func detectFormData(in webView: WKWebView) {
        let script = """
                (function() {
                    var inputs = document.querySelectorAll('input, textarea');
                    for (var i = 0; i < inputs.length; i++) {
                        if (inputs[i].value && inputs[i].value.length > 0) {
                            return true;
                        }
                    }
                    return false;
                })();
            """

        webView.evaluateJavaScript(script) { [weak self] (result, _) in
            DispatchQueue.main.async {
                self?.hasFormData = result as? Bool ?? false
            }
        }
    }

    /// Detects if the page has active media playback
    private func detectMediaPlayback(in webView: WKWebView) {
        let script = """
                (function() {
                    var videos = document.querySelectorAll('video');
                    var audios = document.querySelectorAll('audio');
                    for (var i = 0; i < videos.length; i++) {
                        if (!videos[i].paused) return true;
                    }
                    for (var i = 0; i < audios.length; i++) {
                        if (!audios[i].paused) return true;
                    }
                    return false;
                })();
            """

        webView.evaluateJavaScript(script) { [weak self] (result, _) in
            DispatchQueue.main.async {
                self?.hasMediaPlayback = result as? Bool ?? false
            }
        }
    }

    /// Checks if this tab should be excluded from hibernation
    func shouldExcludeFromHibernation() -> Bool {
        return hasMediaPlayback || hasActiveDownloads || isLoading
            || (hasFormData && Date().timeIntervalSince(lastAccessed) < 300)  // Protect recent form data
    }

    private func createSnapshot() {
        guard let webView = webView else { return }

        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds

        // Use safe rect validation to prevent Double/Int conversion issues
        let safeBounds = SafeNumericConversions.validateSafeRect(bounds)
        guard safeBounds.width > 0 && safeBounds.height > 0 else {
            return
        }

        config.rect = safeBounds

        webView.takeSnapshot(with: config) { [weak self] image, error in
            DispatchQueue.main.async {
                self?.snapshot = image
            }
        }
    }

    private func updateLastAccessed() {
        lastAccessed = Date()
        startHibernationTimer()
    }

    private func startHibernationTimer() {
        // Don't restart timer if one is already running and hasn't expired
        // This prevents timer accumulation that causes performance issues
        guard hibernationTimer == nil || !hibernationTimer!.isValid else { return }

        hibernationTimer?.invalidate()
        hibernationTimer = Timer.scheduledTimer(
            withTimeInterval: hibernationThreshold, repeats: false
        ) { [weak self] _ in
            if !(self?.isActive ?? true) && !(self?.isLoading ?? false) {
                self?.hibernate()
            }
        }
    }

    func notifyLoadingStateChanged() {
        // Restart hibernation timer when loading state changes
        if !isActive {
            startHibernationTimer()
        }
    }

    // MARK: - Print functionality
    func printPage() {
        guard let webView = webView else { return }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.orientation = .portrait

        let printOperation = NSPrintOperation(view: webView, printInfo: printInfo)
        printOperation.showsProgressPanel = true
        printOperation.canSpawnSeparateThread = true

        printOperation.run()
    }

    // MARK: - Find in page
    func findInPage(_ searchText: String, forward: Bool = true) {
        guard let webView = webView else { return }

        let script = "window.find('\(searchText)', false, \(!forward), true)"
        webView.evaluateJavaScript(script)
    }

    deinit {
        hibernationTimer?.invalidate()

        // CRITICAL: Clean up all JavaScript timers when tab is deallocated
        cleanupWebViewTimers()
    }

    /// CRITICAL: Clean up JavaScript timers to prevent CPU usage and memory leaks
    private func cleanupWebViewTimers() {
        guard let webView = webView else { return }

        // Execute JavaScript timer cleanup to prevent CPU spikes
        webView.evaluateJavaScript("if (window.cleanupAllTimers) { window.cleanupAllTimers(); }") {
            result, error in
            if let error = error {
                if AppLog.isVerboseEnabled {
                    print("⚠️ Tab \(self.id) timer cleanup error: \(error.localizedDescription)")
                }
            } else {
                if AppLog.isVerboseEnabled {
                    print("🧹 Tab \(self.id) timers cleaned up successfully")
                }
            }
        }
    }

    // MARK: - Equatable Implementation
    static func == (lhs: Tab, rhs: Tab) -> Bool {
        return lhs.id == rhs.id
    }

    // MARK: - Transferable Implementation
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { tab in
            tab.id.uuidString
        }
    }
}
