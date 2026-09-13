import Foundation

enum DownloadResponsePolicy {
    static func shouldDownload(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        if let response = response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            let type = disposition.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?.trimmingCharacters(in: .whitespacesAndNewlines)
            if type?.caseInsensitiveCompare("attachment") == .orderedSame { return true }
        }
        return !canShowMIMEType
    }
}
