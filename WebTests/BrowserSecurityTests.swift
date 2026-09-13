import Foundation
import Testing
@testable import Web

struct BrowserSecurityTests {
    @Test func rejectsCredentialDomainImpersonation() {
        let trusted = URL(string: "https://accounts.example.com/login")!
        #expect(BrowserSecurityPolicy.credentialMatches(website: "accounts.example.com", pageURL: trusted))
        for host in ["example.com", "evilaccounts.example.com", "accounts.example.com.evil.test", "com", ""] {
            #expect(!BrowserSecurityPolicy.credentialMatches(website: host, pageURL: trusted))
        }
        #expect(!BrowserSecurityPolicy.credentialMatches(website: "accounts.example.com",
            pageURL: URL(string: "https://accounts.example.com.evil.test")))
    }

    @Test func credentialsRequireExactSecureOrigin() {
        #expect(!BrowserSecurityPolicy.credentialMatches(website: "example.com", pageURL: URL(string: "http://example.com")))
        #expect(!BrowserSecurityPolicy.credentialMatches(website: "example.com", pageURL: URL(string: "https://example.com:8443")))
        #expect(BrowserSecurityPolicy.credentialMatches(website: "https://example.com:8443", pageURL: URL(string: "https://example.com:8443/login")))
        #expect(!BrowserSecurityPolicy.credentialMatches(website: "https://example.com", pageURL: URL(string: "https://user:password@example.com")))
        #expect(!BrowserSecurityPolicy.credentialMatches(website: "example.com", pageURL: URL(string: "file:///example.com")))
    }

    @Test func bridgeRequiresCurrentTopLevelOrigin() {
        let page = URL(string: "https://example.com/path")!
        #expect(BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: true,
            scheme: "https", host: "example.com", port: 0, topLevelURL: page))
        #expect(!BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: false,
            scheme: "https", host: "example.com", port: 443, topLevelURL: page))
        #expect(!BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: true,
            scheme: "https", host: "previous.example", port: 443, topLevelURL: page))
        #expect(!BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: true,
            scheme: "http", host: "example.com", port: 80, topLevelURL: page))
        #expect(!BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: true,
            scheme: "https", host: "example.com", port: 8443, topLevelURL: page))
        #expect(!BrowserSecurityPolicy.allowsBridgeMessage(isMainFrame: true,
            scheme: "file", host: "", port: 0, topLevelURL: URL(string: "file:///tmp/page.html")))
    }

    @Test func downloadFilenamesCannotEscapeDestination() {
        let destination = URL(fileURLWithPath: "/tmp/download-test", isDirectory: true)
        for name in ["../../Library/LaunchAgents/start.plist", "/etc/passwd", "..\\..\\secret.txt", "..", ".", "", "one/two/file.zip"] {
            let filename = BrowserSecurityPolicy.downloadFilename(name)
            let target = destination.appendingPathComponent(filename).standardizedFileURL
            #expect(target.deletingLastPathComponent() == destination.standardizedFileURL)
            #expect(!filename.contains("/"))
            #expect(!filename.contains("\\"))
        }
        #expect(BrowserSecurityPolicy.downloadFilename("../../file.zip") == "file.zip")
    }

    @Test func downloadNamesRemoveSpoofingControlsAndBoundLength() {
        #expect(BrowserSecurityPolicy.downloadFilename("report\u{202E}fdp.exe") == "reportfdp.exe")
        #expect(BrowserSecurityPolicy.downloadFilename("\u{0}file\n.txt") == "file.txt")
        #expect(!BrowserSecurityPolicy.downloadFilename(".hidden").hasPrefix("."))
        let longName = BrowserSecurityPolicy.downloadFilename(String(repeating: "🧭", count: 200) + ".pdf")
        #expect(longName.utf8.count <= 240)
        #expect(longName.hasSuffix(".pdf"))
    }
}
