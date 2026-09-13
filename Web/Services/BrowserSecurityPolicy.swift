import Foundation

/// Pure policy decisions shared by native bridges and their regression tests.
enum BrowserSecurityPolicy {
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    static func allowsBridgeMessage(
        isMainFrame: Bool, scheme: String, host: String, port: Int, topLevelURL: URL?
    ) -> Bool {
        guard isMainFrame, let origin = Origin(url: topLevelURL) else { return false }
        let effectivePort = port == 0 ? (scheme.lowercased() == "https" ? 443 : 80) : port
        return scheme.lowercased() == origin.scheme
            && host.lowercased() == origin.host && effectivePort == origin.port
    }

    /// Legacy host-only entries are valid only on the exact host's default HTTPS port.
    static func credentialMatches(website: String, pageURL: URL?) -> Bool {
        guard let page = Origin(url: pageURL), page.scheme == "https" else { return false }
        if website.contains("://") {
            return Origin(url: URL(string: website)) == page
        }
        return page.port == 443 && website.lowercased() == page.host
    }

    /// Server filenames are display hints, never filesystem paths.
    static func downloadFilename(_ proposed: String) -> String {
        let leaf = proposed.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let forbidden = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: ":\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let cleaned = String(String.UnicodeScalarView(leaf.unicodeScalars.filter { !forbidden.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Download" }
        // Keep UTF-8 below common filesystem name limits, preserving the extension.
        guard cleaned.utf8.count > 240 else { return cleaned.hasPrefix(".") ? "Download-" + cleaned : cleaned }
        var ext = String((cleaned as NSString).pathExtension.prefix(20))
        while ext.utf8.count > 32 { ext.removeLast() }
        var stem = (cleaned as NSString).deletingPathExtension
        while stem.utf8.count > 190 { stem.removeLast() }
        return (stem.hasPrefix(".") ? "Download-" : "") + stem + (ext.isEmpty ? "" : "." + ext)
    }
}
