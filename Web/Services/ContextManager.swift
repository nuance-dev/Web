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

    private let maxContentLength = 24_000
    private var activeExtractions = 0

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

        return await extractPageContext(from: webView, tab: activeTab)
    }

    /// Read the current document only when the assistant requests it.
    func extractPageContext(from webView: WKWebView, tab: Tab) async -> WebpageContext? {
        guard !Task.isCancelled, !tab.isIncognito,
              webView.configuration.websiteDataStore.isPersistent,
              let url = webView.url, NavigationResolver.isWebURL(url) else { return nil }
        let revision = (webView as? WebView.CustomWebView)?.coordinator?.documentRevision
        activeExtractions += 1
        isExtracting = true
        contextStatus = "Reading page…"
        defer {
            activeExtractions -= 1
            isExtracting = activeExtractions > 0
            contextStatus = isExtracting ? "Reading page…" : "Ready"
        }
        do {
            let context = try await performContentExtraction(from: webView, tab: tab)
            try Task.checkCancellation()
            guard !tab.isIncognito, tab.webView === webView, webView.url == url,
                  (webView as? WebView.CustomWebView)?.coordinator?.documentRevision == revision,
                  context.url == url.absoluteString else { return nil }
            lastExtractedContext = context
            return context
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.warn("Page content could not be read.")
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

    /// Clear the last page snapshot when the user clears browsing data.
    func clearContextCache() { lastExtractedContext = nil }

    private func performContentExtraction(from webView: WKWebView, tab: Tab) async throws -> WebpageContext {
        let result = try await PageScriptEvaluation.evaluate(PageContentScript.source, in: webView)
        try Task.checkCancellation()
        guard let data = result as? [String: Any] else { throw ContextError.invalidResponse }
        return try parseExtractionResult(data, from: webView, tab: tab)
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
        String(text.prefix(maxContentLength)).trimmingCharacters(in: .whitespacesAndNewlines)
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

}

// MARK: - Supporting Types

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
