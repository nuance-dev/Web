import Foundation
import Testing
import WebKit
@testable import Web

@MainActor
struct PageContentExtractionTests {
    @Test func readsArticleWithoutFormsHiddenTextOrPageMutation() async throws {
        let webView = try await page("""
        <article><h1>Observation</h1><p>Ground observations: 2024. Hubble images: 2023.</p>
        <p>Version 1.2 has .map() and a ratio of 50%.</p>
        <form><textarea>FORM_SECRET</textarea><input id="field" value="INPUT_SECRET"></form>
        <div contenteditable="true">DRAFT_SECRET</div><div hidden><p>HIDDEN_SECRET</p></div>
        <div style="display:none"><span>STYLE_SECRET</span></div>
        <script>window.scriptSecret = 'SCRIPT_SECRET';</script>
        <p style="height:2000px">The visible ending.</p></article>
        """)
        // Compare in one JavaScript turn so WebKit's deferred focus scrolling cannot intervene.
        let check = """
        (() => {
            document.getElementById('field').focus(); window.scrollTo(0, 300);
            const before = window.scrollY;
            const context = \(PageContentScript.source)
            return { context, before, after: window.scrollY,
                unchanged: document.getElementById('field').value === 'INPUT_SECRET' &&
                    document.activeElement.id === 'field' && typeof window.contentExtractionState === 'undefined' };
        })();
        """
        let checked = try #require(try await PageScriptEvaluation.evaluate(check, in: webView) as? [String: Any])
        let result = try #require(checked["context"] as? [String: Any])
        let text = try #require(result["text"] as? String)
        #expect(text.contains("2024") && text.contains("2023"))
        #expect(text.contains("Version 1.2 has .map() and a ratio of 50%."))
        #expect(!text.contains("SECRET"))
        #expect(checked["unchanged"] as? Bool == true)
        #expect(checked["before"] as? Double == checked["after"] as? Double)
    }

    @Test func selectedArticleInsideHiddenOrEditableAncestorIsExcluded() async throws {
        for container in ["hidden", "contenteditable='true'", "style='visibility:hidden'"] {
            let webView = try await page("<div \(container)><article>PRIVATE_DRAFT</article></div>")
            let result = try #require(try await PageScriptEvaluation.evaluate(PageContentScript.source, in: webView) as? [String: Any])
            #expect(result["text"] as? String == "")
        }
    }

    @Test func textAndTraversalStayBounded() async throws {
        let webView = try await page("<article>" + String(repeating: "<span>Visible words. </span>", count: 8000) + "</article>")
        let result = try #require(try await PageScriptEvaluation.evaluate(PageContentScript.source, in: webView) as? [String: Any])
        let text = try #require(result["text"] as? String)
        #expect(text.utf16.count <= 24_000)
        #expect(!text.isEmpty)
    }

    private func page(_ body: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        webView.loadHTMLString("<html><head><title>Extraction fixture</title></head><body>\(body)</body></html>", baseURL: URL(string: "https://example.com/article"))
        let deadline = Date().addingTimeInterval(5)
        while webView.title != "Extraction fixture", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(webView.title == "Extraction fixture")
        return webView
    }
}
