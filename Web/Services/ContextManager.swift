import CoreData
import Foundation
import SwiftUI
import WebKit

/// Manages webpage content extraction and context generation for AI integration
/// Provides cleaned, summarized webpage content to enhance AI responses
@MainActor
class ContextManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isExtracting: Bool = false
    @Published var lastExtractedContext: WebpageContext?
    @Published var contextStatus: String = "Ready"

    // MARK: - Singleton

    static let shared = ContextManager()

    // MARK: - Properties

    /// Maximum number of characters allowed in `WebpageContext.text`.
    /// 0 ➜ unlimited (no truncation). We default to **0** because modern Apple-Silicon devices can easily feed tens of thousands of characters to the 2B Gemma model.
    /// If we later decide to cap it dynamically, we just need to set this to a non-zero value.
    private let maxContentLength: Int = 0
    private let contentExtractionTimeout = 10.0  // seconds
    private var lastExtractionTime: Date?
    private let minExtractionInterval: TimeInterval = 2.0  // Prevent spam extraction

    // ENHANCED: Content extraction caching
    private var contextCache: [String: CachedContext] = [:]
    private let maxCacheSize = 50  // Maximum number of cached contexts
    private let cacheExpirationTime: TimeInterval = 300  // 5 minutes
    private var cacheAccessOrder: [String] = []  // For LRU eviction

    // HISTORY CONTEXT CONFIGURATION
    private let maxHistoryItems = 10  // Limit history items for context
    private let maxHistoryDays: TimeInterval = 1 * 24 * 60 * 60  // 1 day lookback
    private let maxHistoryContentLength = 3000  // Limit history context size

    // Privacy settings for history context
    @Published var isHistoryContextEnabled: Bool = false
    @Published var historyContextScope: HistoryContextScope = .recent

    private init() {
        AppLog.debug("ContextManager initialized")
    }

    // MARK: - Public Interface

    /// Extract context from the currently active tab
    func extractCurrentPageContext(from tabManager: TabManager) async -> WebpageContext? {
        guard let activeTab = tabManager.activeTab,
            !activeTab.isIncognito,
            let webView = activeTab.webView
        else {
            if AppLog.isVerboseEnabled {
                AppLog.debug("No active tab/WebView for context extraction")
            }
            return nil
        }

        // Only throttle if we have *already* extracted context for the *same* page very recently.
        // This prevents scenarios where the user quickly navigates to a new URL but the previous
        // page's context is still returned because the interval has not expired (e.g. navigating
        // from a weather page to a social media post within two seconds). [[Fixes stale-context bug]]
        if let lastTime = lastExtractionTime,
            Date().timeIntervalSince(lastTime) < minExtractionInterval,
            let lastContext = lastExtractedContext
        {
            let currentURL = await webView.url?.absoluteString
            if lastContext.url == currentURL {
                return lastContext
            }
        }

        return await extractPageContext(from: webView, tab: activeTab)
    }

    /// Extract context from specific WebView with intelligent caching
    func extractPageContext(from webView: WKWebView, tab: Tab) async -> WebpageContext? {
        // Private pages must never enter the shared AI context cache or history.
        guard !tab.isIncognito, webView.configuration.websiteDataStore.isPersistent else { return nil }
        guard let url = await webView.url?.absoluteString else {
            if AppLog.isVerboseEnabled { AppLog.debug("No URL for context extraction") }
            return nil
        }

        // Check cache first
        if let cachedContext = getCachedContext(for: url) {
            if AppLog.isVerboseEnabled {
                AppLog.debug(
                    "Using cached context: len=\(cachedContext.context.text.count) title=\(cachedContext.context.title)"
                )
            }

            await MainActor.run {
                lastExtractedContext = cachedContext.context
            }

            return cachedContext.context
        }

        await MainActor.run {
            isExtracting = true
            contextStatus = "Extracting page content..."
        }

        defer {
            Task { @MainActor in
                isExtracting = false
                contextStatus = "Ready"
            }
            lastExtractionTime = Date()
        }

        do {
            let context = try await performContentExtraction(from: webView, tab: tab)

            // Cache the extracted context
            cacheContext(context, for: url)

            await MainActor.run {
                lastExtractedContext = context
            }

            if AppLog.isVerboseEnabled {
                AppLog.debug("Context extracted: len=\(context.text.count) url=\(context.url)")
            }
            return context

        } catch {
            AppLog.warn("Context extraction failed: \(error.localizedDescription)")
            await MainActor.run {
                contextStatus = "Extraction failed"
            }
            return nil
        }
    }

    /// Returns a rich, structured context string for the AI model by combining the current page data
    /// with optional browsing-history context. The page section includes title, URL, word count,
    /// a list of headings & prominent links, and finally the raw (truncated) body text.
    func getFormattedContext(from context: WebpageContext?, includeHistory: Bool = true) -> String?
    {
        var sections: [String] = []

        // 1. Current page
        if let context = context {
            let formattedContext = formatWebpageContext(context)
            sections.append(formattedContext)
            if AppLog.isVerboseEnabled {
                AppLog.debug(
                    "Formatted context length: \(formattedContext.count) from \(context.title)")
            }
        } else {
            if AppLog.isVerboseEnabled {
                AppLog.debug("No context provided to getFormattedContext")
            }
        }

        // 2. Browsing history (optional)
        if includeHistory && isHistoryContextEnabled, let historyContext = getHistoryContext() {
            sections.append(historyContext)
        }

        guard !sections.isEmpty else {
            if AppLog.isVerboseEnabled { AppLog.debug("No sections to format - returning nil") }
            return nil
        }

        let finalContext = sections.joined(separator: "\n\n---\n\n")
        if AppLog.isVerboseEnabled {
            AppLog.debug("Final formatted context len=\(finalContext.count)")
        }
        return finalContext
    }

    /// Builds a well-structured string from a `WebpageContext` that is optimised for LLM consumption.
    /// – Headings provide document outline.
    /// – Links surface key outbound references.
    /// – We keep the *full* cleaned text (up to `maxContentLength`) so the model can quote exact phrasing if necessary.
    private func formatWebpageContext(_ ctx: WebpageContext) -> String {
        // Headings (limit to first 12 for brevity)
        let headingLines: String = ctx.headings.prefix(12).map { "- \($0)" }.joined(separator: "\n")

        // Prominent links (limit 10) – already "text (url)" formatted by JS extractor
        let linkLines: String = ctx.links.prefix(10).map { "- \($0)" }.joined(separator: "\n")

        // Optionally include a quick preview/summary (first 2-3 sentences) to guide the model before the wall of text
        let preview: String = {
            // Rough sentence splitting on period/exclamation/question marks.
            let delimiters: Set<Character> = [".", "!", "?"]
            var current = ""
            var sentences: [String] = []
            for char in ctx.text {
                current.append(char)
                if delimiters.contains(char) {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sentences.append(trimmed)
                    }
                    current = ""
                }
                if sentences.count >= 3 { break }
            }
            return sentences.joined(separator: " ")
        }()

        // Re-compute word count to avoid stale/incorrect values from earlier extractions
        let dynamicWordCount = ctx.text.split { $0.isWhitespace || $0.isNewline }.count

        let formattedResult = """
            Current webpage context:
            Title: \(ctx.title)
            URL: \(ctx.url)
            Word Count: \(dynamicWordCount)

            Outline (headings):
            \(headingLines.isEmpty ? "(none)" : headingLines)

            Prominent links:
            \(linkLines.isEmpty ? "(none)" : linkLines)

            Preview:
            \(preview)

            Full content (truncated to \(maxContentLength) chars):
            \(ctx.text)
            """

        if AppLog.isVerboseEnabled {
            AppLog.debug("formatWebpageContext len=\(formattedResult.count) text=\(ctx.text.count)")
        }
        return formattedResult
    }

    /// Get browsing history context for AI processing
    func getHistoryContext() -> String? {
        let historyItems = extractRelevantHistory()
        guard !historyItems.isEmpty else { return nil }

        var historyParts: [String] = ["Recent browsing history context:"]

        for (index, item) in historyItems.enumerated() {
            let timeAgo = formatTimeAgo(item.lastVisitDate)
            let domain = extractDomain(from: item.url) ?? "unknown"

            let historyEntry =
                "\(index + 1). \(item.title ?? "Untitled") (\(domain)) - visited \(timeAgo)"
            historyParts.append(historyEntry)
        }

        let historyContext = historyParts.joined(separator: "\n")

        // Limit history context size
        if historyContext.count > maxHistoryContentLength {
            let truncated = String(historyContext.prefix(maxHistoryContentLength))
            return truncated + "... (history truncated for context)"
        }

        return historyContext
    }

    /// Check if context extraction is available for the current tab
    func canExtractContext(from tabManager: TabManager) -> Bool {
        guard let activeTab = tabManager.activeTab,
            let webView = activeTab.webView
        else {
            return false
        }

        guard let url = webView.url else {
            return false
        }

        // Don't extract from special URLs
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    // MARK: - History Context Methods

    /// Extract relevant browsing history for AI context
    private func extractRelevantHistory() -> [HistoryItem] {
        let historyService = HistoryService.shared
        let cutoffDate = Date().addingTimeInterval(-maxHistoryDays)

        // Get recent history based on scope
        let historyItems: [HistoryItem]

        switch historyContextScope {
        case .recent:
            historyItems = Array(historyService.recentHistory.prefix(maxHistoryItems))
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            historyItems = historyService.getHistory(from: startOfDay, to: Date())
        case .lastHour:
            let oneHourAgo = Date().addingTimeInterval(-3600)
            historyItems = historyService.getHistory(from: oneHourAgo, to: Date())
        case .mostVisited:
            historyItems = historyService.getMostVisited(limit: maxHistoryItems)
        }

        // Filter out items older than cutoff and limit results
        let filteredItems =
            historyItems
            .filter { $0.lastVisitDate >= cutoffDate }
            .filter { !shouldExcludeFromHistoryContext($0.url) }
            .prefix(maxHistoryItems)

        return Array(filteredItems)
    }

    /// Check if URL should be excluded from history context
    private func shouldExcludeFromHistoryContext(_ url: String) -> Bool {
        let excludedDomains = [
            "localhost", "127.0.0.1", "::1",
            "chrome://", "webkit://", "about:",
            "data:", "file://",
        ]

        for excludedDomain in excludedDomains {
            if url.contains(excludedDomain) {
                return true
            }
        }

        // Exclude sensitive domains (banking, medical, etc.)
        let sensitiveDomains = [
            "bank", "medical", "health", "pharmacy",
            "login", "auth", "secure", "private",
        ]

        let lowercaseUrl = url.lowercased()
        for sensitiveDomain in sensitiveDomains {
            if lowercaseUrl.contains(sensitiveDomain) {
                return true
            }
        }

        return false
    }

    /// Extract domain from URL for context display
    private func extractDomain(from url: String) -> String? {
        guard let urlObj = URL(string: url) else { return nil }
        return urlObj.host
    }

    /// Format time ago string for history context
    private func formatTimeAgo(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

    /// Configure history context settings
    func configureHistoryContext(enabled: Bool, scope: HistoryContextScope) {
        isHistoryContextEnabled = enabled
        historyContextScope = scope
        if AppLog.isVerboseEnabled {
            AppLog.debug("History context configured: enabled=\(enabled) scope=\(scope)")
        }
    }

    /// Clear history context cache (for privacy)
    func clearHistoryContextCache() {
        // Clear any cached history context data
        if AppLog.isVerboseEnabled { AppLog.debug("History context cache cleared") }
    }

    // MARK: - Content Caching Methods

    /// Get cached context for URL if it exists and is still fresh
    private func getCachedContext(for url: String) -> CachedContext? {
        // Clean up expired entries first
        cleanExpiredCache()

        guard let cachedContext = contextCache[url] else {
            return nil
        }

        // Check if cache entry is still fresh
        if Date().timeIntervalSince(cachedContext.cachedAt) > cacheExpirationTime {
            contextCache.removeValue(forKey: url)
            cacheAccessOrder.removeAll { $0 == url }
            return nil
        }

        // Update access order for LRU
        cacheAccessOrder.removeAll { $0 == url }
        cacheAccessOrder.append(url)

        return cachedContext
    }

    /// Cache extracted context for future use
    private func cacheContext(_ context: WebpageContext, for url: String) {
        // Only cache high-quality content
        guard context.contentQuality > 15 else {
            if AppLog.isVerboseEnabled {
                AppLog.debug("Skipping cache for low-quality content (q=\(context.contentQuality))")
            }
            return
        }

        // Implement LRU eviction if cache is full
        if contextCache.count >= maxCacheSize {
            evictLeastRecentlyUsed()
        }

        let cachedContext = CachedContext(
            context: context,
            cachedAt: Date(),
            accessCount: 1
        )

        contextCache[url] = cachedContext
        cacheAccessOrder.removeAll { $0 == url }
        cacheAccessOrder.append(url)

        if AppLog.isVerboseEnabled {
            AppLog.debug(
                "Context cached for \(URL(string: url)?.host ?? "unknown"): len=\(context.text.count) q=\(context.contentQuality)"
            )
        }
    }

    /// Remove expired cache entries
    private func cleanExpiredCache() {
        let now = Date()
        let expiredUrls = contextCache.compactMap { (url, cachedContext) in
            now.timeIntervalSince(cachedContext.cachedAt) > cacheExpirationTime ? url : nil
        }

        for url in expiredUrls {
            contextCache.removeValue(forKey: url)
            cacheAccessOrder.removeAll { $0 == url }
        }

        if !expiredUrls.isEmpty {
            if AppLog.isVerboseEnabled {
                AppLog.debug("Cleaned \(expiredUrls.count) expired cache entries")
            }
        }
    }

    /// Evict least recently used cache entries
    private func evictLeastRecentlyUsed() {
        let removeCount = maxCacheSize / 4  // Remove 25% of cache when full
        let urlsToRemove = Array(cacheAccessOrder.prefix(removeCount))

        for url in urlsToRemove {
            contextCache.removeValue(forKey: url)
            cacheAccessOrder.removeAll { $0 == url }
        }

        if AppLog.isVerboseEnabled {
            AppLog.debug("Evicted \(urlsToRemove.count) LRU cache entries")
        }
    }

    /// Clear all cached contexts
    func clearContextCache() {
        contextCache.removeAll()
        cacheAccessOrder.removeAll()
        if AppLog.isVerboseEnabled { AppLog.debug("All context cache cleared") }
    }

    /// Get cache statistics for debugging
    func getCacheStatistics() -> (size: Int, hitRate: Double, avgQuality: Double) {
        let size = contextCache.count

        let totalAccess = contextCache.values.reduce(0) { $0 + $1.accessCount }
        let hitRate = totalAccess > 0 ? Double(size) / Double(totalAccess) : 0.0

        let avgQuality =
            contextCache.isEmpty
            ? 0.0
            : Double(contextCache.values.reduce(0) { $0 + $1.context.contentQuality })
                / Double(size)

        return (size: size, hitRate: hitRate, avgQuality: avgQuality)
    }

    // MARK: - Private Methods

    private func performContentExtraction(from webView: WKWebView, tab: Tab) async throws
        -> WebpageContext
    {
        // ENHANCED: Multi-strategy content extraction with comprehensive fallbacks

        var bestContext: WebpageContext?
        var extractionStrategies: [ExtractionStrategy] = []

        // Strategy 1: Enhanced JavaScript extraction (primary)
        extractionStrategies.append(.enhancedJavaScript)

        // Strategy 2: Network request interception (if available)
        extractionStrategies.append(.networkInterception)

        // Strategy 3: Lazy-load scroll extraction
        extractionStrategies.append(.lazyLoadScroll)

        // Strategy 4: Emergency DOM extraction
        extractionStrategies.append(.emergencyExtraction)

        for (index, strategy) in extractionStrategies.enumerated() {
            if AppLog.isVerboseEnabled {
                AppLog.debug("Extraction attempt #\(index + 1): \(strategy.description)")
            }

            do {
                let context = try await executeExtractionStrategy(
                    strategy, webView: webView, tab: tab)

                if bestContext == nil || context.contentQuality > (bestContext?.contentQuality ?? 0)
                {
                    bestContext = context
                }

                // If we have high-quality content, we can stop
                if context.isHighQuality {
                    if AppLog.isVerboseEnabled {
                        AppLog.debug("High-quality content via \(strategy.description)")
                    }
                    break
                }

                // If strategy recommends no retry, continue to next strategy
                if !context.shouldRetry && context.contentQuality > 10 {
                    if AppLog.isVerboseEnabled {
                        AppLog.debug("Acceptable content via \(strategy.description)")
                    }
                    break
                }

            } catch {
                if AppLog.isVerboseEnabled {
                    AppLog.debug(
                        "Strategy \(strategy.description) failed: \(error.localizedDescription)")
                }
                continue
            }
        }

        guard let finalContext = bestContext else {
            throw ContextError.extractionTimeout
        }

        return finalContext
    }

    private func executeExtractionStrategy(
        _ strategy: ExtractionStrategy, webView: WKWebView, tab: Tab
    ) async throws -> WebpageContext {
        switch strategy {
        case .enhancedJavaScript:
            return try await performJavaScriptExtraction(webView: webView, tab: tab)

        case .networkInterception:
            // For now, fall back to JavaScript - network interception would require WKURLScheme handling
            return try await performJavaScriptExtraction(webView: webView, tab: tab)

        case .lazyLoadScroll:
            return try await performLazyLoadExtraction(webView: webView, tab: tab)

        case .emergencyExtraction:
            return try await performEmergencyExtraction(webView: webView, tab: tab)
        }
    }

    private func performJavaScriptExtraction(webView: WKWebView, tab: Tab) async throws
        -> WebpageContext
    {
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<WebpageContext, Error>) in
            let script = contentExtractionJavaScript

            // Set timeout for JavaScript execution
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(contentExtractionTimeout * 1_000_000_000))
                cont.resume(throwing: ContextError.extractionTimeout)
            }

            // Execute JavaScript on main thread
            Task { @MainActor [weak self] in
                webView.evaluateJavaScript(script) { result, error in
                    timeoutTask.cancel()
                    if let error = error {
                        cont.resume(
                            throwing: ContextError.javascriptError(error.localizedDescription))
                        return
                    }
                    guard let data = result as? [String: Any] else {
                        cont.resume(throwing: ContextError.invalidResponse)
                        return
                    }
                    do {
                        let context =
                            try self?.parseExtractionResult(data, from: webView, tab: tab)
                            ?? WebpageContext(
                                url: webView.url?.absoluteString ?? "", title: "", text: "",
                                headings: [], links: [], wordCount: 0, extractionDate: Date(),
                                tabId: tab.id)
                        cont.resume(returning: context)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func performLazyLoadExtraction(webView: WKWebView, tab: Tab) async throws
        -> WebpageContext
    {
        // First trigger lazy loading
        await triggerLazyLoadScroll(on: webView)

        // Wait for content to load
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

        // Then perform JavaScript extraction
        return try await performJavaScriptExtraction(webView: webView, tab: tab)
    }

    private func performEmergencyExtraction(webView: WKWebView, tab: Tab) async throws
        -> WebpageContext
    {
        // Simplified extraction that just gets all visible text
        let emergencyScript = """
            (function() {
                try {
                    var title = document.title || '';
                    var url = window.location.href;
                    var bodyText = document.body.innerText || document.body.textContent || '';
                    
                    // Clean basic content
                    var cleanedText = bodyText
                        .replace(/\\s+/g, ' ')
                        .replace(/\\n+/g, '\\n')
                        .trim();
                    
                    var wordCount = cleanedText.split(/\\s+/).filter(w => w.length > 0).length;
                    
                    return {
                        success: true,
                        text: cleanedText,
                        title: title,
                        url: url,
                        headings: [],
                        links: [],
                        wordCount: wordCount,
                        extractionMethod: 'emergency',
                        contentQuality: Math.min(cleanedText.length / 50, 15), // Basic quality score
                        frameworksDetected: [],
                        extractionAttempt: 1,
                        isContentStable: true,
                        contentChanges: 0,
                        shouldRetry: false
                    };
                    
                } catch (error) {
                    return {
                        success: false,
                        error: error.toString(),
                        text: 'Emergency extraction failed',
                        title: document.title || 'Unknown',
                        url: window.location.href,
                        headings: [],
                        links: [],
                        wordCount: 0,
                        extractionMethod: 'emergency-error',
                        contentQuality: 0,
                        frameworksDetected: [],
                        extractionAttempt: 1
                    };
                }
            })();
            """

        return try await withCheckedThrowingContinuation { cont in
            Task { @MainActor [weak self] in
                webView.evaluateJavaScript(emergencyScript) { result, error in
                    if let error = error {
                        cont.resume(
                            throwing: ContextError.javascriptError(error.localizedDescription))
                        return
                    }
                    guard let data = result as? [String: Any] else {
                        cont.resume(throwing: ContextError.invalidResponse)
                        return
                    }
                    do {
                        let context =
                            try self?.parseExtractionResult(data, from: webView, tab: tab)
                            ?? WebpageContext(
                                url: webView.url?.absoluteString ?? "", title: "", text: "",
                                headings: [], links: [], wordCount: 0, extractionDate: Date(),
                                tabId: tab.id)
                        cont.resume(returning: context)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func parseExtractionResult(_ data: [String: Any], from webView: WKWebView, tab: Tab)
        throws -> WebpageContext
    {
        guard let rawText = data["text"] as? String,
            let title = data["title"] as? String,
            let url = data["url"] as? String
        else {
            throw ContextError.missingRequiredFields
        }

        // Clean and process the content
        let cleanedText = cleanExtractedContent(rawText)
        let truncatedText = truncateContent(cleanedText)

        // Extract additional metadata
        let headings = data["headings"] as? [String] ?? []
        let links = data["links"] as? [String] ?? []

        // Re-compute word count on the Swift side to avoid under-count issues seen on some dynamic sites.
        let wordCount = truncatedText.split { $0.isWhitespace || $0.isNewline }.count
        let extractionMethod = data["extractionMethod"] as? String ?? "unknown"
        let postCount = data["postCount"] as? Int ?? 0
        let isMultiPost = data["isMultiPost"] as? Bool ?? false

        // ENHANCED: Extract new quality metrics
        let contentQuality = data["contentQuality"] as? Int ?? 0
        let frameworksDetected = data["frameworksDetected"] as? [String] ?? []
        let extractionAttempt = data["extractionAttempt"] as? Int ?? 1
        let isContentStable = data["isContentStable"] as? Bool ?? true
        let contentChanges = data["contentChanges"] as? Int ?? 0
        let shouldRetry = data["shouldRetry"] as? Bool ?? false

        // ENHANCED: Log comprehensive extraction results
        if isMultiPost {
            if AppLog.isVerboseEnabled {
                AppLog.debug(
                    "Multi-post extraction: \(postCount) posts from \(URL(string: url)?.host ?? "unknown")"
                )
            }
        }

        if !frameworksDetected.isEmpty {
            if AppLog.isVerboseEnabled {
                AppLog.debug("Frameworks detected: \(frameworksDetected.joined(separator: ", "))")
            }
        }

        if AppLog.isVerboseEnabled {
            AppLog.debug(
                "Extract method=\(extractionMethod) posts=\(postCount) len=\(truncatedText.count) q=\(contentQuality) attempt=\(extractionAttempt) stable=\(isContentStable) changes=\(contentChanges)"
            )
        }

        // Store enhanced metrics for potential retry logic
        if shouldRetry {
            if AppLog.isVerboseEnabled {
                AppLog.debug("Content quality insufficient (\(contentQuality)) – retry recommended")
            }
        }

        return WebpageContext(
            url: url,
            title: title,
            text: truncatedText,
            headings: headings,
            links: links,
            wordCount: wordCount,
            extractionDate: Date(),
            tabId: tab.id,
            // Store enhanced metrics for future use
            extractionMethod: extractionMethod,
            contentQuality: contentQuality,
            frameworksDetected: frameworksDetected,
            isContentStable: isContentStable,
            shouldRetry: shouldRetry
        )
    }

    // Enhanced retry logic based on content quality metrics
    private func shouldRetryExtraction(for context: WebpageContext) -> Bool {
        // Use the JavaScript-calculated shouldRetry flag as primary indicator
        if context.shouldRetry {
            return true
        }

        // Additional fallback checks for backward compatibility
        return context.contentQuality < 20 || context.text.count < 200
            || (!context.isContentStable && context.wordCount < 100)
    }

    private func cleanExtractedContent(_ text: String) -> String {
        // Remove CSS and HTML artifacts first
        var cleaned = text

        // Remove CSS rules and selectors
        cleaned = cleaned.replacingOccurrences(
            of: "\\.[a-zA-Z0-9_-]+\\s*\\{[^}]*\\}", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "#[a-zA-Z0-9_-]+\\s*\\{[^}]*\\}", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "[a-zA-Z0-9_-]+\\s*\\{[^}]*\\}", with: "", options: .regularExpression)

        // Remove CSS property patterns
        cleaned = cleaned.replacingOccurrences(
            of: "[a-zA-Z-]+:\\s*[^;]+;", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "\\.([-_a-zA-Z0-9]+)", with: "", options: .regularExpression)

        // Remove HTML tags
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Remove JavaScript patterns
        cleaned = cleaned.replacingOccurrences(
            of: "function\\s*\\([^)]*\\)\\s*\\{[^}]*\\}", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "\\([^)]*\\)\\s*=>\\s*[^;\\n]+[;\\n]?", with: "", options: .regularExpression)

        // Remove common web artifacts
        cleaned = cleaned.replacingOccurrences(
            of: "\\b(fill|stroke|url|rgba?|#[0-9a-fA-F]{3,8})\\b", with: "",
            options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "\\b(px|em|rem|vh|vw|%|deg)\\b", with: "", options: .regularExpression)

        // Remove excessive whitespace and clean up content
        cleaned =
            cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private func truncateContent(_ text: String) -> String {
        // If no limit set or text is within limit, return as-is
        if maxContentLength == 0 || text.count <= maxContentLength {
            return text
        }

        // Truncate at word boundary
        let truncated = String(text.prefix(maxContentLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            let result = String(truncated[..<lastSpace])
            return result + "... (content truncated)"
        }

        return String(text.prefix(maxContentLength)) + "... (content truncated)"
    }

    // MARK: - JavaScript for Content Extraction

    private var contentExtractionJavaScript: String {
        """
        (function() {
            // ENHANCED 2025: Modern content extraction with MutationObserver and framework detection
            
            // Global state for enhanced extraction
            window.contentExtractionState = window.contentExtractionState || {
                observers: [],
                attempts: 0,
                maxAttempts: 5,
                isMonitoring: false,
                foundContent: null,
                frameworks: [],
                contentStability: { changes: 0, lastChange: Date.now() }
            };
            
            var state = window.contentExtractionState;
            
            function detectFrameworks() {
                var frameworks = [];
                
                // React detection
                if (window.React || window.__REACT_DEVTOOLS_GLOBAL_HOOK__ || 
                    document.querySelector('[data-reactroot]') || 
                    document.querySelector('[data-react-]')) {
                    frameworks.push('react');
                }
                
                // Vue detection  
                if (window.Vue || document.querySelector('[data-v-]') || 
                    document.querySelector('.v-')) {
                    frameworks.push('vue');
                }
                
                // Angular detection
                if (window.ng || window.getAllAngularRootElements || 
                    document.querySelector('[ng-app]') || 
                    document.querySelector('[data-ng-]')) {
                    frameworks.push('angular');
                }
                
                // Next.js detection
                if (window.__NEXT_DATA__ || document.querySelector('#__next')) {
                    frameworks.push('nextjs');
                }
                
                // Svelte detection
                if (document.querySelector('[data-svelte-]')) {
                    frameworks.push('svelte');
                }
                
                return frameworks;
            }
            
            function setupMutationObserver() {
                if (state.isMonitoring) return;
                
                var observer = new MutationObserver(function(mutations) {
                    var significantChanges = 0;
                    
                    mutations.forEach(function(mutation) {
                        if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
                            // Check if added nodes contain meaningful content
                            for (var i = 0; i < mutation.addedNodes.length; i++) {
                                var node = mutation.addedNodes[i];
                                if (node.nodeType === Node.ELEMENT_NODE) {
                                    var text = node.textContent || '';
                                    if (text.trim().length > 50) {
                                        significantChanges++;
                                    }
                                }
                            }
                        }
                    });
                    
                    if (significantChanges > 0) {
                        state.contentStability.changes += significantChanges;
                        state.contentStability.lastChange = Date.now();
                    }
                });
                
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                
                state.observers.push(observer);
                state.isMonitoring = true;
            }
            
            function calculateContentQuality(text) {
                if (!text || text.length < 50) return 0;
                
                var quality = 0;
                var sentences = text.split(/[.!?]+/).filter(s => s.trim().length > 10);
                var words = text.split(/\\s+/).filter(w => w.length > 2);
                var uniqueWords = new Set(words.map(w => w.toLowerCase()));
                
                // Sentence structure scoring
                quality += Math.min(sentences.length * 2, 20);
                
                // Vocabulary diversity scoring
                var diversity = uniqueWords.size / Math.max(words.length, 1);
                quality += diversity * 30;
                
                // Length scoring (diminishing returns)
                quality += Math.min(text.length / 100, 25);
                
                // Penalize repetitive content
                var repetitivePatterns = text.match(/(\\b\\w+\\b)(?=.*\\1.*\\1)/gi);
                if (repetitivePatterns && repetitivePatterns.length > words.length * 0.3) {
                    quality *= 0.7; // 30% penalty for repetitive content
                }
                
                return Math.round(quality);
            }
            
            function extractWithFrameworkSupport() {
                var content = '';
                var method = 'unknown';
                
                // Framework-specific extraction strategies
                if (state.frameworks.includes('react')) {
                    // React: Look for common React patterns
                    var reactSelectors = [
                        '[data-testid*="post"]', '[data-testid*="content"]',
                        '.react-content', '[id*="react"]', '[class*="Post"]',
                        '[role="article"]', '[role="main"]'
                    ];
                    
                    for (var i = 0; i < reactSelectors.length; i++) {
                        var elements = document.querySelectorAll(reactSelectors[i]);
                        if (elements.length > 0) {
                            for (var j = 0; j < elements.length; j++) {
                                var text = elements[j].textContent || '';
                                if (text.trim().length > 100) {
                                    content += text.trim() + '\\n\\n';
                                    method = 'react-framework';
                                }
                            }
                            if (content) break;
                        }
                    }
                }
                
                if (!content && state.frameworks.includes('vue')) {
                    // Vue: Look for Vue-specific patterns
                    var vueSelectors = [
                        '[v-for]', '.vue-content', '[data-v-]',
                        '.v-card', '.v-content'
                    ];
                    
                    for (var i = 0; i < vueSelectors.length; i++) {
                        var elements = document.querySelectorAll(vueSelectors[i]);
                        if (elements.length > 0) {
                            for (var j = 0; j < elements.length; j++) {
                                var text = elements[j].textContent || '';
                                if (text.trim().length > 100) {
                                    content += text.trim() + '\\n\\n';
                                    method = 'vue-framework';
                                }
                            }
                            if (content) break;
                        }
                    }
                }
                
                return { content: content, method: method };
            }
            
            try {
                state.attempts++;
                
                // Detect frameworks on first attempt
                if (state.attempts === 1) {
                    state.frameworks = detectFrameworks();
                    setupMutationObserver();
                }
                
                // Get page metadata
                var title = document.title || '';
                var url = window.location.href;
                
                // Extract headings for structure understanding
                var headings = [];
                var headingElements = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
                for (var i = 0; i < headingElements.length; i++) {
                    var heading = headingElements[i];
                    if (heading.textContent && heading.textContent.trim()) {
                        headings.push(heading.tagName.toLowerCase() + ': ' + heading.textContent.trim());
                    }
                }
                
                var extractedContent = '';
                var contentFound = false;
                var postCount = 0;
                var extractionMethod = 'fallback';
                
                // DOM ANALYSIS: Understand the page structure
                console.log('🔍 DOM ANALYSIS: Starting comprehensive page analysis');
                console.log('🔍 Page URL:', window.location.href);
                console.log('🔍 Page title:', document.title);
                console.log('🔍 Body classes:', document.body.className || 'none');
                console.log('🔍 Total elements:', document.querySelectorAll('*').length);
                
                // Analyze common content containers
                var commonContainers = ['main', 'article', '[role="main"]', '.content', '.main', '#content', '#main'];
                for (var c = 0; c < commonContainers.length; c++) {
                    var containers = document.querySelectorAll(commonContainers[c]);
                    if (containers.length > 0) {
                        console.log('🔍 Found', containers.length, 'elements matching:', commonContainers[c]);
                    }
                }
                
                // Analyze common content patterns across all sites
                var commonContentSelectors = [
                    '[data-testid*="post"]', '[data-testid*="content"]', '[data-testid*="comment"]',
                    '.post', '.content', '.comment', '.message', '.article',
                    '[class*="post"]', '[class*="content"]', '[class*="comment"]',
                    '[role="article"]', '[role="main"]', 'article', 'main'
                ];
                
                for (var cs = 0; cs < commonContentSelectors.length; cs++) {
                    var elements = document.querySelectorAll(commonContentSelectors[cs]);
                    if (elements.length > 0) {
                        console.log('🔍 Found', elements.length, 'elements matching:', commonContentSelectors[cs]);
                        
                        if (elements.length > 0 && elements.length <= 5) {
                            for (var e = 0; e < Math.min(elements.length, 3); e++) {
                                var text = elements[e].textContent || '';
                                if (text.trim().length > 50) {
                                    console.log('📝 Element', e + 1, 'preview:', text.trim().substring(0, 100) + '...');
                                }
                            }
                        }
                    }
                }
                
                // STRATEGY 1: Framework-aware extraction
                console.log('🔍 EXTRACTION DEBUG: Starting Strategy 1 - Framework-aware extraction');
                var frameworkResult = extractWithFrameworkSupport();
                if (frameworkResult.content) {
                    console.log('✅ Strategy 1 SUCCESS:', frameworkResult.method, 'extracted', frameworkResult.content.length, 'chars');
                    console.log('📝 Strategy 1 Preview:', frameworkResult.content.substring(0, 200) + '...');
                    extractedContent = frameworkResult.content;
                    extractionMethod = frameworkResult.method;
                    contentFound = true;
                } else {
                    console.log('❌ Strategy 1 FAILED: No framework content found');
                }
                
                // STRATEGY 2: Enhanced multi-post extraction with platform-agnostic improvements
                if (!contentFound) {
                    console.log('🔍 EXTRACTION DEBUG: Starting Strategy 2 - Multi-post extraction');
                    var multiPostSelectors = [
                        // Generic content selectors (platform-agnostic)
                        '[data-testid*="post"]', '[data-testid*="content"]', '[data-testid*="comment"]',
                        '[data-testid*="tweet"]', '[data-testid*="message"]',
                        
                        // Generic forum and discussion selectors
                        '.message-body', '.post-message', '.forum-post', '.bb-post',
                        '.post-content', '.message-content', '.topic-post',
                        '.comment-body', '.reply-content', '.post-body',
                        
                        // Social media and feed selectors
                        '.feed-item', '.timeline-item', '.story-content',
                        '.card-content', '.item-content', '.entry-content',
                        
                        // General content selectors
                        '.post', '.entry', '.article-item', '.content-item',
                        '[class*="post"]', '[class*="message"]', '[class*="comment"]',
                        '[class*="content"]', '[class*="article"]',
                        '[role="article"]', '[itemtype*="Article"]'
                    ];
                    
                    for (var s = 0; s < multiPostSelectors.length && postCount < 20; s++) {
                        var posts = document.querySelectorAll(multiPostSelectors[s]);
                        console.log('🔍 Strategy 2 - Testing selector:', multiPostSelectors[s], 'found', posts.length, 'elements');
                        
                        for (var p = 0; p < posts.length && postCount < 20; p++) {
                            var post = posts[p];
                            var postText = post.textContent || post.innerText || '';
                            var quality = calculateContentQuality(postText);
                            
                            console.log('📊 Strategy 2 - Post', p + 1, 'length:', postText.trim().length, 'quality:', quality);
                            console.log('📝 Strategy 2 - Post preview:', postText.trim().substring(0, 100) + '...');
                            
                            // Enhanced content validation
                            if (postText.trim().length > 50 && quality > 10) {
                                postCount++;
                                extractedContent += 'POST ' + postCount + ': ' + postText.trim() + '\\n\\n';
                                contentFound = true;
                                extractionMethod = 'multi-post-enhanced';
                                console.log('✅ Strategy 2 - Added post', postCount, 'with quality', quality);
                            }
                        }
                    }
                    
                    if (contentFound) {
                        console.log('✅ Strategy 2 SUCCESS: Extracted', postCount, 'posts, total', extractedContent.length, 'chars');
                    } else {
                        console.log('❌ Strategy 2 FAILED: No valid posts found');
                    }
                }
                
                // STRATEGY 3: Single content extraction with semantic scoring
                if (!contentFound) {
                    console.log('🔍 EXTRACTION DEBUG: Starting Strategy 3 - Single content extraction');
                    var singleContentSelectors = [
                        // Primary content selectors (highest priority)
                        'article', 'main', '[role="main"]', '.main-content', '#main-content',
                        '.article-content', '.entry-content', '.content-area',
                        
                        // News and blog selectors  
                        '.article-body', '.story-body', '.entry-body', '.post-body',
                        '.article-text', '.story-content', '.article-wrap',
                        '.prose', '.content-wrapper', '.page-content',
                        
                        // Documentation and wiki selectors
                        '.documentation', '.docs', '.doc-content', '.readme',
                        '.wiki-content', '.markdown-body',
                        
                        // E-commerce selectors
                        '.product-description', '.item-details', '.listing-content'
                    ];
                    
                    var bestContent = { text: '', score: 0, method: 'structured' };
                    
                    for (var i = 0; i < singleContentSelectors.length; i++) {
                        var elements = document.querySelectorAll(singleContentSelectors[i]);
                        console.log('🔍 Strategy 3 - Testing selector:', singleContentSelectors[i], 'found', elements.length, 'elements');
                        
                        for (var j = 0; j < elements.length; j++) {
                            var element = elements[j];
                            if (element && element.textContent) {
                                var text = element.textContent.trim();
                                var score = calculateContentQuality(text);
                                
                                console.log('📊 Strategy 3 - Element', j + 1, 'length:', text.length, 'score:', score);
                                console.log('📝 Strategy 3 - Element preview:', text.substring(0, 100) + '...');
                                
                                if (score > bestContent.score && text.length > 200) {
                                    console.log('🎯 Strategy 3 - New best content! Score:', score, 'vs previous:', bestContent.score);
                                    bestContent = { text: text, score: score, method: 'structured-semantic' };
                                }
                            }
                        }
                    }
                    
                    if (bestContent.text) {
                        console.log('✅ Strategy 3 SUCCESS: Best content score', bestContent.score, 'length', bestContent.text.length);
                        extractedContent = bestContent.text;
                        extractionMethod = bestContent.method;
                        contentFound = true;
                    } else {
                        console.log('❌ Strategy 3 FAILED: No content found with score > 0 and length > 200');
                    }
                }
                
                // STRATEGY 4: Intelligent paragraph extraction
                if (!contentFound) {
                    console.log('🔍 EXTRACTION DEBUG: Starting Strategy 4 - Paragraph extraction');
                    var paragraphs = document.querySelectorAll('p, div, span');
                    console.log('🔍 Strategy 4 - Found', paragraphs.length, 'total elements');
                    var contentBlocks = [];
                    
                    for (var i = 0; i < paragraphs.length; i++) {
                        var p = paragraphs[i];
                        if (p.textContent && p.textContent.trim().length > 30) {
                            var quality = calculateContentQuality(p.textContent);
                            if (quality > 5) {
                                contentBlocks.push({
                                    text: p.textContent.trim(),
                                    quality: quality,
                                    tag: p.tagName,
                                    classes: p.className || 'none'
                                });
                                
                                if (contentBlocks.length <= 5) {
                                    console.log('📊 Strategy 4 - Block', contentBlocks.length, 'quality:', quality, 'tag:', p.tagName, 'classes:', p.className || 'none');
                                    console.log('📝 Strategy 4 - Block preview:', p.textContent.trim().substring(0, 100) + '...');
                                }
                            }
                        }
                    }
                    
                    console.log('🔍 Strategy 4 - Found', contentBlocks.length, 'quality blocks');
                    
                    // Sort by quality and take the best content
                    contentBlocks.sort((a, b) => b.quality - a.quality);
                    var topBlocks = contentBlocks.slice(0, 10);
                    
                    if (topBlocks.length > 0) {
                        console.log('✅ Strategy 4 SUCCESS: Using top', topBlocks.length, 'blocks');
                        console.log('🎯 Strategy 4 - Top scores:', topBlocks.slice(0, 3).map(b => b.quality).join(', '));
                        extractedContent = topBlocks.map(block => block.text).join('\\n\\n');
                        extractionMethod = 'semantic-paragraphs';
                        contentFound = true;
                    } else {
                        console.log('❌ Strategy 4 FAILED: No quality blocks found');
                    }
                }
                
                // STRATEGY 5: Full DOM body extraction (robust fallback)
                if (!contentFound) {
                    console.log('🔍 EXTRACTION DEBUG: Starting Strategy 5 - Full body extraction');
                    
                    // Get the entire body content
                    var bodyText = document.body.textContent || document.body.innerText || '';
                    
                    if (bodyText.trim().length > 500) {
                        console.log('🔍 Strategy 5 - Raw body text length:', bodyText.length);
                        
                        // Clean and filter the content
                        var cleanedText = bodyText
                            .replace(/\\s+/g, ' ')  // Normalize whitespace
                            .replace(/\\n\\s*\\n/g, '\\n')  // Remove excessive line breaks
                            .trim();
                        
                        // Filter out common navigation patterns
                        var navigationPatterns = [
                            /Sort by:.*?/gi,
                            /Open comment sort options/gi,
                            /Best Top New Controversial Old Q&A/gi,
                            /Show more comments/gi,
                            /Load more/gi,
                            /Sign in/gi,
                            /Create Account/gi,
                            /Privacy Policy/gi,
                            /Terms of Service/gi
                        ];
                        
                        for (var np = 0; np < navigationPatterns.length; np++) {
                            cleanedText = cleanedText.replace(navigationPatterns[np], '');
                        }
                        
                        // Calculate quality after filtering
                        var bodyQuality = calculateContentQuality(cleanedText);
                        console.log('🔍 Strategy 5 - Cleaned text length:', cleanedText.length, 'quality:', bodyQuality);
                        console.log('📝 Strategy 5 - Preview:', cleanedText.substring(0, 200) + '...');
                        
                        if (bodyQuality > 15 && cleanedText.length > 200) {
                            console.log('✅ Strategy 5 SUCCESS: Using full body extraction');
                            extractedContent = cleanedText.substring(0, 8000); // Limit to reasonable size
                            extractionMethod = 'full-body-filtered';
                            contentFound = true;
                        } else {
                            console.log('❌ Strategy 5 FAILED: Body quality too low or too short');
                        }
                    } else {
                        console.log('❌ Strategy 5 FAILED: Body text too short');
                    }
                }
                
                // FINAL FALLBACK: Enhanced emergency extraction
                var finalText = extractedContent.trim();
                if (!finalText || finalText.length < 100) {
                    var allTextNodes = [];
                    var walker = document.createTreeWalker(
                        document.body,
                        NodeFilter.SHOW_TEXT,
                        function(node) {
                            var parent = node.parentElement;
                            if (parent && (
                                parent.tagName === 'SCRIPT' || 
                                parent.tagName === 'STYLE' || 
                                parent.tagName === 'NOSCRIPT' ||
                                parent.tagName === 'HEAD' ||
                                parent.style.display === 'none' || 
                                parent.hidden ||
                                parent.getAttribute('aria-hidden') === 'true' ||
                                parent.className.includes('sr-only') ||
                                parent.className.includes('visually-hidden')
                            )) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            var text = node.textContent.trim();
                            // Filter out CSS-like content
                            if (text.match(/^\\.[a-zA-Z0-9_-]+/) || 
                                text.match(/[a-zA-Z-]+:\\s*[^;]+;/) ||
                                text.match(/\\{[^}]*\\}/) ||
                                text.match(/function\\s*\\(/)) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return text.length > 20 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                        }
                    );
                    
                    var node;
                    while (node = walker.nextNode()) {
                        var text = node.textContent.trim();
                        if (calculateContentQuality(text) > 5) {
                            allTextNodes.push(text);
                        }
                    }
                    
                    if (allTextNodes.length > 0) {
                        finalText = allTextNodes.join(' ').replace(/\\s+/g, ' ').trim();
                        extractionMethod = 'emergency-semantic';
                    }
                }
                
                // ENHANCED: Advanced content cleaning while preserving structure
                finalText = finalText
                    .replace(/[ \\t]+/g, ' ')
                    .replace(/\\n\\s*\\n/g, '\\n\\n')
                    .replace(/\\n{3,}(?!POST|COMMENT)/g, '\\n\\n')
                    // Remove CSS and style artifacts
                    .replace(/\\.[a-zA-Z0-9_-]+\\s*\\{[^}]*\\}/g, '')
                    .replace(/#[a-zA-Z0-9_-]+\\s*\\{[^}]*\\}/g, '')
                    .replace(/[a-zA-Z-]+:\\s*[^;\\n]+;?/g, '')
                    .replace(/\\.([-_a-zA-Z0-9]+)/g, '')
                    .replace(/\\b(fill|stroke|url|rgba?|#[0-9a-fA-F]{3,8})\\b/g, '')
                    .replace(/\\b(px|em|rem|vh|vw|%|deg)\\b/g, '')
                    // Remove HTML tags and attributes
                    .replace(/<[^>]+>/g, '')
                    .replace(/\\b(id|class|data-[a-z-]+)=["\'][^"\']*["\']/g, '')
                    // Remove common web artifacts with context awareness
                    .replace(/(?:Share|Copy link|Advertisement|Skip to content|Continue reading|Read more|Vote|Reply|permalink|embed|save|context|full comments)\\s*/gi, '')
                    // Remove navigation elements
                    .replace(/(?:Home|About|Contact|Menu|Navigation|Search|Login|Register)\\s*(?:\\||•|-)\\s*/gi, '')
                    // Remove function declarations and JavaScript
                    .replace(/function\\s*\\([^)]*\\)\\s*\\{[^}]*\\}/g, '')
                    .replace(/\\([^)]*\\)\\s*=>\\s*[^;\\n]+[;\\n]?/g, '')
                    .trim();
                
                // Extract enhanced links with quality scoring
                var links = [];
                var linkElements = document.querySelectorAll('article a[href], main a[href], .content a[href], .post-content a[href], [role="article"] a[href]');
                for (var i = 0; i < Math.min(linkElements.length, 20); i++) {
                    var link = linkElements[i];
                    if (link.textContent && link.textContent.trim() && link.href && 
                        !link.href.startsWith('javascript:') && 
                        !link.href.startsWith('#') &&
                        !link.href.includes('void(0)')) {
                        var linkText = link.textContent.trim();
                        if (linkText.length > 3 && linkText.length < 120 && 
                            calculateContentQuality(linkText) > 3) {
                            links.push(linkText + ' (' + link.href + ')');
                        }
                    }
                }
                
                // Calculate final metrics
                var wordCount = finalText.trim().split(/\\s+/).filter(function(word) {
                    return word.length > 0 && word.match(/[a-zA-Z0-9]/);
                }).length;
                
                var contentQuality = calculateContentQuality(finalText);
                var isStable = (Date.now() - state.contentStability.lastChange) > 2000; // 2 seconds of stability
                
                // Store result for potential retry logic
                state.foundContent = {
                    text: finalText,
                    quality: contentQuality,
                    wordCount: wordCount,
                    stable: isStable
                };
                
                return {
                    success: true,
                    text: finalText,
                    title: title,
                    url: url,
                    headings: headings.slice(0, 30),
                    links: links.slice(0, 20),
                    wordCount: wordCount,
                    extractionTime: new Date().toISOString(),
                    contentLength: finalText.length,
                    extractionMethod: extractionMethod,
                    postCount: postCount,
                    isMultiPost: postCount > 1,
                    // ENHANCED METRICS
                    contentQuality: contentQuality,
                    frameworksDetected: state.frameworks,
                    extractionAttempt: state.attempts,
                    isContentStable: isStable,
                    contentChanges: state.contentStability.changes,
                    shouldRetry: contentQuality < 20 && !isStable && state.attempts < state.maxAttempts
                };
                
            } catch (error) {
                return {
                    success: false,
                    error: error.toString(),
                    text: document.body.textContent || 'Unable to extract content',
                    title: document.title || 'Unknown',
                    url: window.location.href,
                    headings: [],
                    links: [],
                    wordCount: 0,
                    contentLength: 0,
                    extractionMethod: 'error',
                    contentQuality: 0,
                    frameworksDetected: [],
                    extractionAttempt: state.attempts
                };
            }
        })();
        """
    }

    /// Programmatically scrolls the page to the bottom (and briefly back to top) to trigger lazy-loaded content like virtualised lists.
    /// Must be called on the main actor because it touches the WebView JS runtime.
    private func triggerLazyLoadScroll(on webView: WKWebView) async {
        let js =
            "(function(){ const scrollBottom = () => window.scrollTo(0, document.body.scrollHeight); scrollBottom(); setTimeout(scrollBottom, 200); setTimeout(() => window.scrollTo(0,0), 400); })();"
        do {
            _ = try await webView.evaluateJavaScript(js)
        } catch {
            // Ignore JavaScript errors during lazy load scrolling
        }
    }
}

// MARK: - Supporting Types

/// Cached context entry with metadata
struct CachedContext {
    let context: WebpageContext
    let cachedAt: Date
    var accessCount: Int
}

/// Represents extracted webpage content and metadata
struct WebpageContext: Identifiable, Codable {
    let id = UUID()
    let url: String
    let title: String
    let text: String
    let headings: [String]
    let links: [String]
    let wordCount: Int
    let extractionDate: Date
    let tabId: UUID

    // ENHANCED: Quality and extraction metadata
    let extractionMethod: String
    let contentQuality: Int
    let frameworksDetected: [String]
    let isContentStable: Bool
    let shouldRetry: Bool

    private enum CodingKeys: String, CodingKey {
        case url, title, text, headings, links, wordCount, extractionDate, tabId
        case extractionMethod, contentQuality, frameworksDetected, isContentStable, shouldRetry
    }

    // Default initializer for backward compatibility
    init(
        url: String, title: String, text: String, headings: [String], links: [String],
        wordCount: Int, extractionDate: Date, tabId: UUID,
        extractionMethod: String = "unknown", contentQuality: Int = 0,
        frameworksDetected: [String] = [], isContentStable: Bool = true, shouldRetry: Bool = false
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.headings = headings
        self.links = links
        self.wordCount = wordCount
        self.extractionDate = extractionDate
        self.tabId = tabId
        self.extractionMethod = extractionMethod
        self.contentQuality = contentQuality
        self.frameworksDetected = frameworksDetected
        self.isContentStable = isContentStable
        self.shouldRetry = shouldRetry
    }

    /// Get a concise summary for display
    var summary: String {
        let previewLength = 100
        if text.count <= previewLength {
            return text
        }

        let truncated = String(text.prefix(previewLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
    }

    /// Check if the context is still fresh
    var isFresh: Bool {
        Date().timeIntervalSince(extractionDate) < 300  // 5 minutes
    }

    /// Check if the content quality is sufficient for AI processing
    var isHighQuality: Bool {
        return contentQuality >= 25 && wordCount >= 50
    }

    /// Get quality description for debugging
    var qualityDescription: String {
        switch contentQuality {
        case 0..<10:
            return "Very Poor"
        case 10..<20:
            return "Poor"
        case 20..<35:
            return "Fair"
        case 35..<50:
            return "Good"
        case 50..<70:
            return "Very Good"
        default:
            return "Excellent"
        }
    }
}

/// History context scope options
enum HistoryContextScope: String, CaseIterable {
    case recent = "recent"
    case today = "today"
    case lastHour = "lastHour"
    case mostVisited = "mostVisited"

    var displayName: String {
        switch self {
        case .recent:
            return "Recent History"
        case .today:
            return "Today Only"
        case .lastHour:
            return "Last Hour"
        case .mostVisited:
            return "Most Visited"
        }
    }
}

/// Content extraction strategies
enum ExtractionStrategy: CaseIterable {
    case enhancedJavaScript
    case networkInterception
    case lazyLoadScroll
    case emergencyExtraction

    var description: String {
        switch self {
        case .enhancedJavaScript:
            return "Enhanced JavaScript"
        case .networkInterception:
            return "Network Interception"
        case .lazyLoadScroll:
            return "Lazy-Load Scroll"
        case .emergencyExtraction:
            return "Emergency DOM"
        }
    }
}

/// Context extraction errors
enum ContextError: LocalizedError {
    case noWebView
    case noActiveTab
    case extractionTimeout
    case javascriptError(String)
    case invalidResponse
    case missingRequiredFields
    case contentTooLarge

    var errorDescription: String? {
        switch self {
        case .noWebView:
            return "No WebView available for content extraction"
        case .noActiveTab:
            return "No active tab available"
        case .extractionTimeout:
            return "Content extraction timed out"
        case .javascriptError(let message):
            return "JavaScript error: \(message)"
        case .invalidResponse:
            return "Invalid response from content extraction"
        case .missingRequiredFields:
            return "Missing required fields in extraction result"
        case .contentTooLarge:
            return "Webpage content is too large to process"
        }
    }
}
