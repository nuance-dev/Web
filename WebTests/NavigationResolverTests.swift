import Foundation
import Testing
@testable import Web

struct NavigationResolverTests {
    @Test func addressesAndLocalDevelopment() {
        #expect(NavigationResolver.resolve(" example.com/path ")?.absoluteString == "https://example.com/path")
        #expect(NavigationResolver.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(NavigationResolver.resolve("https://example.com/a?q=b#c")?.fragment == "c")
    }

    @Test func queriesCannotInjectSearchParameters() {
        let url = NavigationResolver.resolve("cats & dogs #today", engine: .youtube)!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.count == 1)
        #expect(items.first?.value == "cats & dogs #today")
        #expect(url.fragment == nil)
        #expect(NavigationResolver.resolve("!ddg swift concurrency")?.host == "duckduckgo.com")
    }

    @Test func rejectExecutableAndCredentialBearingURLs() {
        for input in ["", "  ", "javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "https://good.com@evil.com", "https://", "example.com\nsecret"] {
            #expect(NavigationResolver.resolve(input) == nil, "Rejected input: \(input)")
        }
    }
}
