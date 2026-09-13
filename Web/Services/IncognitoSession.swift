import Foundation
import Network
import WebKit

class IncognitoSession: NSObject, ObservableObject {
    static let shared = IncognitoSession()

    @Published var isActive: Bool = false
    @Published var incognitoTabs: [Tab] = []
    @Published var totalBlockedTrackers: Int = 0

    private var incognitoWebViewConfiguration: WKWebViewConfiguration?
    private var privateDataStore: WKWebsiteDataStore?
    private var sessionStartTime: Date?

    override init() {
        super.init()
        setupIncognitoConfiguration()
        setupNotificationObservers()
    }

    // MARK: - Configuration Setup
    private func setupIncognitoConfiguration() {
        // The browser and session lifecycle must use the same nonpersistent store.
        privateDataStore = WebKitManager.shared.incognitoDataStore
        incognitoWebViewConfiguration = WebKitManager.shared.createConfiguration(isIncognito: true)
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseIncognitoTab),
            name: .closeIncognitoTabRequested,
            object: nil
        )
    }

    // MARK: - Session Management
    func createIncognitoTab(url: URL? = nil) -> Tab {
        let tab = Tab(url: url, isIncognito: true)
        incognitoTabs.append(tab)

        if !isActive {
            startIncognitoSession()
        }

        return tab
    }

    func closeIncognitoTab(_ tab: Tab) {
        incognitoTabs.removeAll { $0.id == tab.id }

        tab.webView?.stopLoading()

        if incognitoTabs.isEmpty {
            endIncognitoSession()
        }
    }

    private func startIncognitoSession() {
        isActive = true
        sessionStartTime = Date()
        totalBlockedTrackers = 0

        print("🥷 Incognito session started with enhanced privacy protection")
    }

    func endIncognitoSession() {
        incognitoTabs.removeAll()

        WebKitManager.shared.resetIncognitoDataStore()

        isActive = false

        if let startTime = sessionStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print(
                "🥷 Incognito session ended - Duration: \(Int(duration))s, Blocked trackers: \(totalBlockedTrackers)"
            )
        }

        sessionStartTime = nil
        totalBlockedTrackers = 0

        setupIncognitoConfiguration()
    }

    private func clearWebViewData(_ webView: WKWebView) {
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {}
    }

    // MARK: - Configuration Access
    func getIncognitoConfiguration() -> WKWebViewConfiguration? {
        return incognitoWebViewConfiguration
    }

    func configureWebViewForIncognito(_ webView: WKWebView) {
        // Private browsing uses WebKit's ephemeral cookies/storage. JavaScript
        // overrides of storage, canvas and WebRTC were incomplete and broke sites.
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView.configuration.allowsAirPlayForMediaPlayback = false
    }

    // MARK: - Statistics
    func getSessionStatistics() -> IncognitoSessionStats {
        let duration = sessionStartTime?.timeIntervalSinceNow.magnitude ?? 0

        return IncognitoSessionStats(
            isActive: isActive,
            duration: duration,
            tabCount: incognitoTabs.count,
            blockedTrackers: totalBlockedTrackers,
            dataStoreType: "Non-Persistent"
        )
    }

    struct IncognitoSessionStats {
        let isActive: Bool
        let duration: TimeInterval
        let tabCount: Int
        let blockedTrackers: Int
        let dataStoreType: String
    }

    // MARK: - Notification Handlers
    @objc private func handleCloseIncognitoTab(_ notification: Notification) {
        if let tab = notification.object as? Tab {
            closeIncognitoTab(tab)
        }
    }
}

// MARK: - Script Message Handler (CSP-Protected)
extension IncognitoSession: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        let validationResult = CSPManager.shared.validateMessageInput(
            message, expectedHandler: "incognitoHandler")

        switch validationResult {
        case .valid(let sanitizedBody):
            guard let type = sanitizedBody["type"] as? String else { return }

            DispatchQueue.main.async {
                switch type {
                case "trackingBlocked":
                    if let count = sanitizedBody["count"] as? Int, (0...10_000).contains(count) {
                        self.totalBlockedTrackers += count
                    }

                default:
                    break
                }
            }

        case .invalid(let error):
            NSLog("🔒 CSP: Incognito message validation failed: \(error.description)")
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let newIncognitoTabRequested = Notification.Name("newIncognitoTabRequested")
    static let closeIncognitoTabRequested = Notification.Name("closeIncognitoTabRequested")
}
