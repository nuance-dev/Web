import Foundation
import Testing
@testable import Web

struct AssistantMarkdownTests {
    @Test func rendersBlocksWithoutSplittingInlineEmphasis() throws {
        let document = AssistantMarkdownDocument.parse("# Result\n\nA **strong** answer with `code`.\n\n## Details\n\nNext paragraph.")
        #expect(document.blocks.map(\.kind) == [.heading(1), .paragraph, .heading(2), .paragraph])
        try #require(document.blocks.count == 4)
        #expect(String(document.blocks[1].content.characters) == "A strong answer with code.")
        #expect(document.blocks[1].content.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(document.blocks[1].content.runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true
        })
    }

    @Test func keepsNestedListDepthAndNumbering() {
        let document = AssistantMarkdownDocument.parse("7. First\n   - Nested\n   - Another\n8. Last")
        #expect(document.blocks.map(\.listDepth) == [1, 2, 2, 1])
        #expect(document.blocks.map(\.listMarker) == ["7.", "•", "•", "8."])
        #expect(document.blocks.map { String($0.content.characters) } == ["First", "Nested", "Another", "Last"])
    }

    @Test func fencedCodeKeepsLiteralContentsWhileStreaming() throws {
        let prefix = "## Example\n\n```swift\nlet value = \"**literal**\"\n  print(value)"
        let streaming = AssistantMarkdownDocument.parse(prefix)
        let completed = AssistantMarkdownDocument.parse(prefix + "\n```\n\nDone.")
        try #require(completed.blocks.count >= 2)
        #expect(streaming.blocks.last?.kind == .code("swift"))
        #expect(streaming.blocks.first?.id == completed.blocks.first?.id)
        #expect(streaming.blocks.last?.id == completed.blocks[1].id)
        let code = String(completed.blocks[1].content.characters)
        #expect(code.trimmingCharacters(in: .newlines) == "let value = \"**literal**\"\n  print(value)")
        #expect(!completed.blocks[1].content.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func quotesRemainSeparateFromTheAnswer() throws {
        let document = AssistantMarkdownDocument.parse("> A quoted **source**.\n\nAn explanation.")
        try #require(document.blocks.count == 2)
        #expect(document.blocks[0].isQuote)
        #expect(!document.blocks[1].isQuote)
        #expect(String(document.blocks[0].content.characters) == "A quoted source.")
    }

    @Test func linksCannotLaunchNativeSchemesOrExposeEmbeddedCredentials() throws {
        let blocked = ["file:///tmp/private", "javascript:alert(1)", "data:text/html,hello",
                       "mailto:someone@example.com", "web-custom://action", "https://user:secret@example.com", "/relative"]
        for target in blocked {
            #expect(!AssistantMarkdownDocument.isAllowedLink(URL(string: target)!))
            let document = AssistantMarkdownDocument.parse("[Open](\(target))")
            #expect(document.blocks.allSatisfy { block in block.content.runs.allSatisfy { $0.link == nil } })
        }
        let allowed = URL(string: "https://example.com/page?q=value")!
        let document = AssistantMarkdownDocument.parse("[Read](\(allowed.absoluteString))")
        try #require(!document.blocks.isEmpty)
        #expect(document.blocks[0].content.runs.contains { $0.link == allowed })
    }

    @Test func imagesDoNotRetainRemoteResourceAttributes() {
        let document = AssistantMarkdownDocument.parse("![Chart](https://example.com/tracker.png)")
        #expect(!document.blocks.isEmpty)
        #expect(document.blocks.allSatisfy { block in block.content.runs.allSatisfy { $0.imageURL == nil } })
        let rawHTML = AssistantMarkdownDocument.parse("<script>alert('test')</script>")
        #expect(rawHTML.blocks.allSatisfy { block in block.content.runs.allSatisfy { $0.link == nil && $0.imageURL == nil } })
    }

    @Test func tablesKeepRowsColumnsAndInlineFormatting() throws {
        let document = AssistantMarkdownDocument.parse("| Name | Value |\n| --- | --- |\n| **One** | `1` |\n| Two | 2 |")
        try #require(document.blocks.count == 1)
        #expect(document.blocks[0].kind == .table)
        let rows = document.blocks[0].rows
        try #require(rows.count == 3)
        #expect(rows[0].isHeader)
        #expect(rows.map { $0.cells.map { String($0.content.characters) } } == [["Name", "Value"], ["One", "1"], ["Two", "2"]])
        try #require(!rows[1].cells.isEmpty)
        #expect(rows[1].cells[0].content.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func longAndHighlyFragmentedOutputHasExplicitDisplayBounds() throws {
        let long = AssistantMarkdownDocument.parse(String(repeating: "🧭", count: AssistantMarkdownDocument.characterLimit + 1))
        #expect(long.isTruncated)
        try #require(!long.blocks.isEmpty)
        #expect(long.blocks[0].content.characters.count == AssistantMarkdownDocument.characterLimit)
        let fragmented = AssistantMarkdownDocument.parse((0..<300).map { "# Heading \($0)" }.joined(separator: "\n\n"))
        #expect(fragmented.isTruncated)
        #expect(fragmented.blocks.count == AssistantMarkdownDocument.blockLimit)
        #expect(AssistantMarkdownDocument.parse("").blocks.isEmpty)
    }
}
