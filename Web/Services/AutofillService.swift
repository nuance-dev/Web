import Foundation
import Combine
import AppKit

/// Central engine responsible for generating URL bar suggestions.
/// Currently keeps all data in-memory; swap out with Core Data in Phase 1.1.
@MainActor
final class AutofillService: ObservableObject {
    // MARK: - Singleton
    static let shared = AutofillService()
    private init() {
        bootstrapCommonSites()
    }

    // MARK: - Published Streams
    @Published private(set) var suggestions: [AutofillSuggestion] = []

    // MARK: - Data Stores (temporary in-memory)
    private var history: [String: AutofillSuggestion] = [:] // keyed by lowercase url
    private var bookmarks: [String: AutofillSuggestion] = [:]
    private var mostVisited: [String: AutofillSuggestion] { history }

    // MARK: - Public API
    func recordVisit(url: String, title: String) {
        let key = url.lowercased()
        let now = Date()
        if var item = history[key] {
            item.visitCount += 1
            item.lastVisited = now
            history[key] = item
        } else {
            let new = AutofillSuggestion(url: url,
                                          title: title.isEmpty ? url : title,
                                          favicon: nil,
                                          score: 0,
                                          sourceType: .history,
                                          visitCount: 1,
                                          lastVisited: now)
            history[key] = new
        }
    }

    func clearHistory() {
        history.removeAll()
        suggestions.removeAll()
    }

    func addBookmark(url: String, title: String) {
        let key = url.lowercased()
        let item = AutofillSuggestion(url: url,
                                       title: title,
                                       favicon: nil,
                                       score: 0,
                                       sourceType: .bookmark,
                                       visitCount: 0,
                                       lastVisited: .distantPast)
        bookmarks[key] = item
    }

    /// Returns suggestions sorted by score descending.
    func getSuggestions(for query: String) async -> [AutofillSuggestion] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let lowercased = query.lowercased()

        // Aggregate candidates
        var candidates: [AutofillSuggestion] = []
        candidates.append(contentsOf: history.values)
        candidates.append(contentsOf: bookmarks.values)
        // Deduplicate by url preference order (history > bookmarks)
        var unique: [String: AutofillSuggestion] = [:]
        for item in candidates {
            let key = item.url.lowercased()
            if unique[key] == nil || unique[key]!.sourceType == .bookmark && item.sourceType == .history {
                unique[key] = item
            }
        }

        // Compute score
        let scored = unique.values.map { item -> AutofillSuggestion in
            var newItem = item
            newItem = AutofillSuggestion(url: item.url,
                                          title: item.title,
                                          favicon: item.favicon,
                                          score: calculateScore(for: item, query: lowercased),
                                          sourceType: item.sourceType,
                                          visitCount: item.visitCount,
                                          lastVisited: item.lastVisited)
            return newItem
        }

        let filtered = scored.filter { $0.score > 0.1 }
        let sorted = filtered.sorted { $0.score > $1.score }
        return Array(sorted.prefix(10))
    }

    // MARK: - Scoring
    private func calculateScore(for item: AutofillSuggestion, query: String) -> Double {
        let frequencyScore = min(1, Double(item.visitCount) / 20.0) // 20 visits == max

        let recencyDays = max(0, -item.lastVisited.timeIntervalSinceNow / 86400)
        let recencyScore = exp(-recencyDays / 30) // 30-day half-life

        let matchQuality = fuzzyMatch(text: item.url + " " + item.title, query: query)

        let total = (frequencyScore * 0.4) + (recencyScore * 0.3) + (matchQuality * 0.3)
        return total
    }

    private func fuzzyMatch(text: String, query: String) -> Double {
        let lower = text.lowercased()
        if lower == query { return 1.0 }
        if lower.hasPrefix(query) { return 0.9 }
        if lower.contains(query) { return 0.6 }
        // Simple fallback – real fuzzy to be implemented later
        return 0.0
    }

    // MARK: - Defaults
    private func bootstrapCommonSites() {
        let common = [
            ("https://google.com", "Google"),
            ("https://youtube.com", "YouTube"),
            ("https://github.com", "GitHub"),
            ("https://developer.apple.com", "Apple Developer"),
            ("https://stackoverflow.com", "Stack Overflow")
        ]
        for (u, t) in common {
            let key = u.lowercased()
            history[key] = AutofillSuggestion(url: u,
                                               title: t,
                                               favicon: nil,
                                               score: 0,
                                               sourceType: .mostVisited,
                                               visitCount: 5,
                                               lastVisited: Date())
        }
    }
} 