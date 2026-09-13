import Foundation
import Testing
@testable import Web

@MainActor
struct AssistantMarkdownRendererTests {
    @Test func streamingRendersTheLatestValueWithoutDebounceStarvation() async throws {
        let probe = MarkdownParserProbe()
        let renderer = AssistantMarkdownRenderer(interval: .milliseconds(40), parse: probe.parse)
        defer { renderer.cancel() }
        renderer.update(.init(content: "First", isStreaming: true))
        try await waitFor { probe.inputs.count == 1 }
        renderer.update(.init(content: "Intermediate", isStreaming: true))
        renderer.update(.init(content: "Latest", isStreaming: true))
        try await waitFor { plainText(renderer.document) == "Latest" }
        #expect(probe.inputs == ["First", "Latest"])
    }

    @Test func finalResponseBypassesTheStreamingInterval() async throws {
        let renderer = AssistantMarkdownRenderer(interval: .seconds(60))
        defer { renderer.cancel() }
        renderer.update(.init(content: "Partial", isStreaming: true))
        try await waitFor { plainText(renderer.document) == "Partial" }
        renderer.update(.init(content: "Final **answer**", isStreaming: false))
        try await waitFor { plainText(renderer.document) == "Final answer" }
        #expect(plainText(renderer.document) == "Final answer")
    }

    @Test func cancelledViewDoesNotPublishPendingUpdates() async throws {
        let renderer = AssistantMarkdownRenderer(interval: .seconds(60))
        renderer.update(.init(content: "Visible", isStreaming: true))
        try await waitFor { plainText(renderer.document) == "Visible" }
        renderer.update(.init(content: "Queued", isStreaming: true))
        renderer.cancel()
        #expect(plainText(renderer.document) == "Visible")
        // The same content can be rendered again when the view reappears.
        renderer.update(.init(content: "Queued", isStreaming: false))
        try await waitFor { plainText(renderer.document) == "Queued" }
        renderer.cancel()
    }

    private func plainText(_ document: AssistantMarkdownDocument) -> String {
        document.blocks.map { String($0.content.characters) }.joined(separator: "\n")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Markdown rendering did not finish within two seconds")
    }
}

private final class MarkdownParserProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var inputs: [String] { lock.withLock { values } }

    func parse(_ source: String) -> AssistantMarkdownDocument {
        lock.withLock { values.append(source) }
        return AssistantMarkdownDocument.parse(source)
    }
}
