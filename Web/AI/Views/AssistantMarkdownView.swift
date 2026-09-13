import AppKit
import SwiftUI

struct AssistantMarkdownView: View, Equatable {
    let content: String
    let isStreaming: Bool
    let openLink: (URL) -> Void
    @StateObject private var renderer = AssistantMarkdownRenderer()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        let document = renderer.document
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if block.listDepth > 0 {
                        Text(block.listMarker ?? "")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                            .accessibilityHidden(block.listMarker == nil)
                    }
                    blockView(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(min(6, max(0, block.listDepth - 1))) * 12)
                .padding(.leading, block.isQuote ? 10 : 0)
                .overlay(alignment: .leading) {
                    if block.isQuote {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tertiary).frame(width: 2)
                    }
                }
            }
            if document.isTruncated {
                HStack {
                    Text("Preview shortened").foregroundStyle(.secondary)
                    Button("Copy full response") { copy(content) }
                }
                .font(.system(size: 11))
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard AssistantMarkdownDocument.isAllowedLink(url) else { return .discarded }
            openLink(url)
            return .handled
        })
        .onChange(of: AssistantMarkdownRenderer.Input(content: content, isStreaming: isStreaming), initial: true) { _, input in
            renderer.update(input)
        }
        .onDisappear { renderer.cancel() }
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdownDocument.Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(inlineText(block.content))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(inlineText(block.content))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { copy(String(block.content.characters)) } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Copy code")
                }
                .padding(.horizontal, 10).padding(.top, 3)
                ScrollView(.horizontal) {
                    Text(String(block.content.characters))
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 10).padding(.bottom, 10)
                }
                .defaultScrollAnchor(.leading)
            }
            .background(.quaternary, in: .rect(cornerRadius: 10))
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(block.rows) { row in
                        GridRow {
                            ForEach(row.cells) { cell in
                                Text(inlineText(cell.content))
                                    .font(.system(size: 12, weight: row.isHeader ? .semibold : .regular))
                                    .fixedSize(horizontal: true, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.leading)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        }
    }

    private func inlineText(_ source: AttributedString) -> AttributedString {
        var text = source
        for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 12, design: .monospaced)
            text[run.range].backgroundColor = Color.primary.opacity(0.06)
        }
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
