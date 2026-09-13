import Foundation
import Network
import WebKit

@MainActor
class AdBlockService: NSObject, ObservableObject {
    static let shared = AdBlockService()

    @Published var isEnabled: Bool = true {
        didSet {
            if isEnabled != oldValue {
                updateContentBlockingRules()
                saveSettings()
            }
        }
    }

    @Published var blockedRequestsCount: Int = 0
    @Published var blockedRequestsToday: Int = 0
    @Published var filterListsStatus: [String: FilterListStatus] = [:]

    private let contentRuleListStore = WKContentRuleListStore.default()
    private var activeRuleLists: [WKContentRuleList] = []
    private let maxRulesPerList = 50000

    private let filterLists = [
        FilterList(
            name: "EasyList",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            category: .ads,
            priority: .high,
            isEnabled: true
        ),
        FilterList(
            name: "EasyPrivacy",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            category: .privacy,
            priority: .high,
            isEnabled: true
        ),
        FilterList(
            name: "uBlock Origin",
            url: URL(
                string:
                    "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"
            )!,
            category: .comprehensive,
            priority: .medium,
            isEnabled: false
        ),
        FilterList(
            name: "Fanboy Annoyances",
            url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!,
            category: .annoyances,
            priority: .low,
            isEnabled: false
        ),
    ]

    struct FilterList {
        let name: String
        let url: URL
        let category: Category
        let priority: Priority
        let isEnabled: Bool

        enum Category {
            case ads, privacy, comprehensive, annoyances, malware
        }

        enum Priority {
            case high, medium, low
        }
    }

    struct FilterListStatus {
        let lastUpdated: Date
        let ruleCount: Int
        let isActive: Bool
        let errorMessage: String?
    }

    override init() {
        super.init()
        loadStoredSettings()
        loadContentBlockingRules()
        setupDailyStatsReset()
    }

    // MARK: - WebView Configuration (CSP-Protected)
    func configureWebView(_ webView: WKWebView) {
        guard isEnabled else { return }

        for ruleList in activeRuleLists {
            webView.configuration.userContentController.add(ruleList)
        }

        let blockingScript = generateBlockingScript()

        // SECURITY: Use CSP-protected script injection for adblocking
        if let secureScript = CSPManager.shared.secureScriptInjection(
            script: blockingScript,
            type: .adBlock,
            webView: webView
        ) {
            webView.configuration.userContentController.addUserScript(secureScript)
        }

        webView.configuration.userContentController.add(self, name: "adBlockHandler")

        setupRequestInterception(for: webView)
    }

    private func generateBlockingScript() -> String {
        return """
            (function() {
                'use strict';
                
                let blockedCount = 0;
                const blockedDomains = new Set();
                
                const originalFetch = window.fetch;
                const originalXHROpen = XMLHttpRequest.prototype.open;
                const originalImageSrc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
                
                const trackingPatterns = [
                    /\\b(analytics|tracking|metrics|stats|telemetry)\\b/i,
                    /\\b(doubleclick|googlesyndication|googletagmanager)\\b/i,
                    /\\b(facebook\\.com\\/tr|connect\\.facebook\\.net)\\b/i,
                    /\\b(twitter\\.com\\/i\\/adsct)\\b/i,
                    /\\b(amazon-adsystem|adsystem\\.amazon)\\b/i
                ];
                
                function isTrackingRequest(url) {
                    return trackingPatterns.some(pattern => pattern.test(url));
                }
                
                function reportBlocked(url) {
                    blockedCount++;
                    const domain = new URL(url).hostname;
                    blockedDomains.add(domain);
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.adBlockHandler) {
                        window.webkit.messageHandlers.adBlockHandler.postMessage({
                            type: 'blocked',
                            url: url,
                            domain: domain,
                            count: blockedCount
                        });
                    }
                }
                
                window.fetch = function(...args) {
                    const url = args[0];
                    if (typeof url === 'string' && isTrackingRequest(url)) {
                        reportBlocked(url);
                        return Promise.reject(new TypeError('Blocked by Ad Blocker'));
                    }
                    
                    return originalFetch.apply(this, args).catch(error => {
                        if (error.message && error.message.includes('blocked')) {
                            reportBlocked(url);
                        }
                        throw error;
                    });
                };
                
                XMLHttpRequest.prototype.open = function(method, url, ...args) {
                    if (isTrackingRequest(url)) {
                        reportBlocked(url);
                        throw new Error('Blocked by Ad Blocker');
                    }
                    
                    this.addEventListener('error', function() {
                        reportBlocked(url);
                    });
                    
                    return originalXHROpen.apply(this, [method, url, ...args]);
                };
                
                if (originalImageSrc) {
                    Object.defineProperty(HTMLImageElement.prototype, 'src', {
                        get: originalImageSrc.get,
                        set: function(value) {
                            if (isTrackingRequest(value)) {
                                reportBlocked(value);
                                return;
                            }
                            originalImageSrc.set.call(this, value);
                        }
                    });
                }
                
                const observer = new MutationObserver(function(mutations) {
                    // Throttle processing if too many mutations to prevent CPU spikes
                    if (mutations.length > 50) {
                // console noise suppressed in production
                        return;
                    }
                    
                    // Skip processing if page is hidden to save CPU
                    if (document.hidden) return;
                    
                    mutations.forEach(function(mutation) {
                        if (mutation.addedNodes && mutation.addedNodes.length > 0) {
                            mutation.addedNodes.forEach(function(node) {
                                if (node.nodeType === Node.ELEMENT_NODE) {
                                    if (node.tagName === 'SCRIPT' && node.src && isTrackingRequest(node.src)) {
                                        node.remove();
                                        reportBlocked(node.src);
                                    }
                                    
                                    if (node.tagName === 'IMG' && node.src && isTrackingRequest(node.src)) {
                                        node.remove();
                                        reportBlocked(node.src);
                                    }
                                }
                            });
                        }
                    });
                });
                
                observer.observe(document, { 
                    childList: true, 
                    subtree: true,
                    // Reduce monitoring scope to only critical changes to improve performance
                    attributeFilter: ['src', 'href']
                });
                
                // Use a single shared timer instead of per-tab intervals to reduce CPU usage  
                // CRITICAL: Reduced frequency from 10s to 30s to prevent Google CPU issues
                window.adBlockStatsTimer = window.adBlockStatsTimer || setInterval(() => {
                    // Skip if page is hidden to save CPU (especially important for Google)
                    if (document.hidden) return;
                    
                    if (blockedCount > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.adBlockHandler) {
                        window.webkit.messageHandlers.adBlockHandler.postMessage({
                            type: 'stats',
                            totalBlocked: blockedCount,
                            blockedDomains: Array.from(blockedDomains)
                        });
                    }
                }, 30000); // Increased from 10s to 30s to prevent Google search CPU spikes
                
                // Cleanup function for proper timer disposal
                window.addEventListener('beforeunload', () => {
                    if (window.adBlockStatsTimer) {
                        clearInterval(window.adBlockStatsTimer);
                        window.adBlockStatsTimer = null;
                    }
                });
                
            })();
            """
    }

    private func setupRequestInterception(for webView: WKWebView) {
        let schemeHandler = BlockedContentSchemeHandler()
        webView.configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "blocked")
    }

    // MARK: - Filter List Management
    private func loadContentBlockingRules() {
        Task {
            await updateFilterLists()
            await compileContentRules()
        }
    }

    private func updateFilterLists() async {
        let enabledLists = filterLists.filter { $0.isEnabled }

        await withTaskGroup(of: Void.self) { group in
            for filterList in enabledLists {
                group.addTask { [weak self] in
                    await self?.downloadAndProcessFilterList(filterList)
                }
            }
        }
    }

    private func downloadAndProcessFilterList(_ filterList: FilterList) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: filterList.url)

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                updateFilterListStatus(filterList.name, error: "HTTP Error")
                return
            }

            let rules = String(data: data, encoding: .utf8) ?? ""
            let contentRules = await convertToContentBlockingRules(rules, for: filterList)

            await compileRuleList(name: filterList.name, rules: contentRules)
            updateFilterListStatus(
                filterList.name, ruleCount: contentRules.components(separatedBy: "\n").count)

        } catch {
            updateFilterListStatus(filterList.name, error: error.localizedDescription)
        }
    }

    private func convertToContentBlockingRules(_ adBlockRules: String, for filterList: FilterList)
        async -> String
    {
        return await withCheckedContinuation { continuation in
            let maxRules = maxRulesPerList
            Task.detached {
                let lines = adBlockRules.components(separatedBy: .newlines)
                var contentRules: [[String: Any]] = []
                var ruleCount = 0

                for line in lines {
                    guard ruleCount < maxRules else { break }

                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    guard
                        !trimmed.isEmpty && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("[")
                            && !trimmed.hasPrefix("# ")
                    else { continue }

                    if let rule = await AdBlockService.processBlockingRuleStatic(trimmed) {
                        contentRules.append(rule)
                        ruleCount += 1
                    } else if let rule = await AdBlockService.processHidingRuleStatic(trimmed) {
                        contentRules.append(rule)
                        ruleCount += 1
                    } else if let rule = await AdBlockService.processWhitelistRuleStatic(trimmed) {
                        contentRules.append(rule)
                        ruleCount += 1
                    }
                }

                let ruleSet = [
                    "version": 1,
                    "rules": contentRules,
                ]

                do {
                    let jsonData = try JSONSerialization.data(
                        withJSONObject: ruleSet, options: .prettyPrinted)
                    let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                    continuation.resume(returning: jsonString)
                } catch {
                    continuation.resume(returning: "[]")
                }
            }
        }
    }

    // Static versions for background processing
    private static func processBlockingRuleStatic(_ rule: String) -> [String: Any]? {
        if rule.hasPrefix("||") && rule.hasSuffix("^") {
            let domain = String(rule.dropFirst(2).dropLast(1))
            return [
                "trigger": [
                    "url-filter": ".*\(NSRegularExpression.escapedPattern(for: domain)).*",
                    "resource-type": ["document", "image", "script", "style-sheet", "raw", "font"],
                ],
                "action": [
                    "type": "block"
                ],
            ]
        }

        if rule.contains("/") && !rule.contains("##") {
            let urlFilter = NSRegularExpression.escapedPattern(
                for: rule.replacingOccurrences(of: "*", with: ".*"))
            return [
                "trigger": [
                    "url-filter": urlFilter,
                    "resource-type": ["image", "script", "style-sheet", "raw"],
                ],
                "action": [
                    "type": "block"
                ],
            ]
        }

        return nil
    }

    private func processBlockingRule(_ rule: String) -> [String: Any]? {
        return AdBlockService.processBlockingRuleStatic(rule)
    }

    private func processHidingRule(_ rule: String) -> [String: Any]? {
        return AdBlockService.processHidingRuleStatic(rule)
    }

    private static func processHidingRuleStatic(_ rule: String) -> [String: Any]? {
        if rule.contains("##") {
            let parts = rule.components(separatedBy: "##")
            guard parts.count == 2 else { return nil }

            let domain = parts[0]
            let selector = parts[1]

            return [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": domain.isEmpty ? ["*"] : [domain],
                ],
                "action": [
                    "type": "css-display-none",
                    "selector": selector,
                ],
            ]
        }

        return nil
    }

    private func processWhitelistRule(_ rule: String) -> [String: Any]? {
        return AdBlockService.processWhitelistRuleStatic(rule)
    }

    private static func processWhitelistRuleStatic(_ rule: String) -> [String: Any]? {
        if rule.hasPrefix("@@") {
            let cleanRule = String(rule.dropFirst(2))
            if cleanRule.hasPrefix("||") && cleanRule.hasSuffix("^") {
                let domain = String(cleanRule.dropFirst(2).dropLast(1))
                return [
                    "trigger": [
                        "url-filter": ".*\(NSRegularExpression.escapedPattern(for: domain)).*"
                    ],
                    "action": [
                        "type": "ignore-previous-rules"
                    ],
                ]
            }
        }

        return nil
    }

    private func compileRuleList(name: String, rules: String) async {
        do {
            try await contentRuleListStore?.compileContentRuleList(
                forIdentifier: name,
                encodedContentRuleList: rules
            )
        } catch {
            updateFilterListStatus(name, error: error.localizedDescription)
        }
    }

    private func compileContentRules() async {
        activeRuleLists.removeAll()

        do {
            for filterList in filterLists where filterList.isEnabled {
                if let ruleList = try await contentRuleListStore?.contentRuleList(
                    forIdentifier: filterList.name)
                {
                    activeRuleLists.append(ruleList)
                }
            }

            await MainActor.run {
                updateContentBlockingRules()
            }
        } catch {
            print("Failed to load content rules: \(error)")
        }
    }

    @MainActor
    private func updateFilterListStatus(_ name: String, ruleCount: Int = 0, error: String? = nil) {
        filterListsStatus[name] = FilterListStatus(
            lastUpdated: Date(),
            ruleCount: ruleCount,
            isActive: error == nil,
            errorMessage: error
        )
    }

    private func updateContentBlockingRules() {
        NotificationCenter.default.post(name: .updateContentBlocking, object: activeRuleLists)
    }

    // MARK: - Statistics and Storage
    private func loadStoredSettings() {
        if let data = UserDefaults.standard.data(forKey: "adBlockSettings"),
            let settings = try? JSONDecoder().decode(AdBlockSettings.self, from: data)
        {
            isEnabled = settings.isEnabled
            blockedRequestsCount = settings.totalBlockedRequests
        }

        let today = Calendar.current.startOfDay(for: Date())
        if let lastResetDate = UserDefaults.standard.object(forKey: "lastStatsReset") as? Date,
            Calendar.current.isDate(lastResetDate, inSameDayAs: today)
        {
            blockedRequestsToday = UserDefaults.standard.integer(forKey: "blockedRequestsToday")
        } else {
            resetDailyStats()
        }
    }

    private func saveSettings() {
        let settings = AdBlockSettings(
            isEnabled: isEnabled,
            totalBlockedRequests: blockedRequestsCount
        )

        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "adBlockSettings")
        }

        UserDefaults.standard.set(blockedRequestsToday, forKey: "blockedRequestsToday")
    }

    private func setupDailyStatsReset() {
        // Use a more efficient approach - check only when app becomes active instead of hourly timer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkDailyStatsReset),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Check immediately on init
        checkDailyStatsReset()
    }

    @objc private func checkDailyStatsReset() {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastReset = UserDefaults.standard.object(forKey: "lastStatsReset") as? Date,
            !Calendar.current.isDate(lastReset, inSameDayAs: today)
        {
            resetDailyStats()
        }
    }

    private func resetDailyStats() {
        blockedRequestsToday = 0
        UserDefaults.standard.set(Date(), forKey: "lastStatsReset")
        UserDefaults.standard.set(0, forKey: "blockedRequestsToday")
    }

    struct AdBlockSettings: Codable {
        let isEnabled: Bool
        let totalBlockedRequests: Int
    }
}

// MARK: - Script Message Handler (CSP-Protected)
extension AdBlockService: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        let validationResult = CSPManager.shared.validateMessageInput(
            message, expectedHandler: "adBlockHandler")

        switch validationResult {
        case .valid(let sanitizedBody):
            guard let type = sanitizedBody["type"] as? String else { return }

            DispatchQueue.main.async {
                switch type {
                case "blocked":
                    self.blockedRequestsCount += 1
                    self.blockedRequestsToday += 1
                    self.saveSettings()

                case "stats":
                    if let totalBlocked = sanitizedBody["totalBlocked"] as? Int {
                        self.blockedRequestsCount += totalBlocked
                        self.blockedRequestsToday += totalBlocked
                        self.saveSettings()
                    }

                default:
                    break
                }
            }

        case .invalid(let error):
            NSLog("🔒 CSP: AdBlock message validation failed: \(error.description)")
        }
    }
}

// MARK: - Custom URL Scheme Handler
class BlockedContentSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let response = URLResponse(
            url: urlSchemeTask.request.url!,
            mimeType: "text/plain",
            expectedContentLength: 0,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Handle task cancellation
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let updateContentBlocking = Notification.Name("updateContentBlocking")
}
