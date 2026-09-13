import Foundation

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google, youtube, duckDuckGo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .youtube:
            components.host = "www.youtube.com"
            components.path = "/results"
            components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }
}

/// One interpretation of user input for every browsing entry point.
/// Only web URLs can cross from a text field into navigation.
enum NavigationResolver {
    static func resolve(_ input: String, engine: BrowserSearchEngine? = nil) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let chosen = engine ?? BrowserSearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        let scopes: [(String, BrowserSearchEngine)] = [("!g ", .google), ("!yt ", .youtube), ("!ddg ", .duckDuckGo)]
        for (prefix, scopedEngine) in scopes where text.lowercased().hasPrefix(prefix) {
            let query = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? nil : scopedEngine.searchURL(for: query)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return validatedWebURL(text)
        }
        let hasWhitespace = text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        if !hasWhitespace {
            let authority = String(text.split(separator: "/", maxSplits: 1).first ?? "")
            let local = authority == "localhost" || authority.hasPrefix("localhost:") || authority.hasPrefix("127.0.0.1") || authority.hasPrefix("[::1]")
            if local { return validatedWebURL("http://" + text) }
            // An explicit non-web scheme is never executed or sent to search.
            if let colon = text.firstIndex(of: ":") {
                let prefix = String(text[..<colon])
                if !prefix.contains("."), !prefix.hasPrefix("[") { return nil }
            }
            if authority.contains(".") || authority.hasPrefix("[") {
                if let url = validatedWebURL("https://" + text) { return url }
            }
        }
        return chosen.searchURL(for: text)
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func validatedWebURL(_ text: String) -> URL? {
        guard let url = URL(string: text), isWebURL(url) else { return nil }
        return url
    }
}
