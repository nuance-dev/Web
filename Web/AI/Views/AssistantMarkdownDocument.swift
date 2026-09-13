import Foundation

/// A bounded native presentation of model output. Parsing never loads linked resources.
struct AssistantMarkdownDocument: Equatable, Sendable {
    static let characterLimit = 64_000
    static let blockLimit = 256

    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case paragraph
            case heading(Int)
            case code(String?)
            case table
        }

        let id: Int
        let kind: Kind
        var content = AttributedString()
        let listMarker: String?
        let listDepth: Int
        let isQuote: Bool
        var rows: [Row] = []
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: Int
        let isHeader: Bool
        var cells: [Cell] = []
    }

    struct Cell: Identifiable, Equatable, Sendable {
        let id: Int
        var content = AttributedString()
    }

    var blocks: [Block] = []
    var isTruncated = false

    static func parse(_ source: String) -> Self {
        let boundary = source.index(source.startIndex, offsetBy: characterLimit, limitedBy: source.endIndex) ?? source.endIndex
        let bounded = String(source[..<boundary])
        var document = Self(isTruncated: boundary != source.endIndex)
        guard !bounded.isEmpty else { return document }
        let parsed = (try? AttributedString(markdown: bounded, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(bounded)
        var seenListItems = Set<Int>()
        var tableCellCount = 0

        for (runIndex, run) in parsed.runs.enumerated() {
            guard runIndex < 4_096 else { document.isTruncated = true; break }
            let intents = run.presentationIntent?.components ?? []
            var text = AttributedString(parsed[run.range])
            // Text renders inline formatting; block layout is handled by the view.
            text.presentationIntent = nil
            text.imageURL = nil
            if let link = run.link, !isAllowedLink(link) { text.link = nil }

            if let table = intents.first(where: { if case .table = $0.kind { true } else { false } }),
               let row = intents.first(where: {
                   switch $0.kind { case .tableRow, .tableHeaderRow: true; default: false }
               }),
               let cell = intents.first(where: { if case .tableCell = $0.kind { true } else { false } }) {
                if document.blocks.last?.id != table.identity {
                    guard document.blocks.count < blockLimit else { document.isTruncated = true; break }
                    document.blocks.append(Block(id: table.identity, kind: .table,
                        listMarker: nil, listDepth: 0, isQuote: false))
                }
                let blockIndex = document.blocks.count - 1
                if document.blocks[blockIndex].rows.last?.id != row.identity {
                    document.blocks[blockIndex].rows.append(Row(id: row.identity,
                        isHeader: row.kind == .tableHeaderRow))
                }
                let rowIndex = document.blocks[blockIndex].rows.count - 1
                if document.blocks[blockIndex].rows[rowIndex].cells.last?.id != cell.identity {
                    guard tableCellCount < 256 else { document.isTruncated = true; break }
                    tableCellCount += 1
                    document.blocks[blockIndex].rows[rowIndex].cells.append(Cell(id: cell.identity))
                }
                let cellIndex = document.blocks[blockIndex].rows[rowIndex].cells.count - 1
                document.blocks[blockIndex].rows[rowIndex].cells[cellIndex].content.append(text)
                continue
            }

            let leaf = intents.first(where: {
                switch $0.kind { case .paragraph, .header, .codeBlock: true; default: false }
            })
            let identity = leaf?.identity ?? -1
            if document.blocks.last?.id == identity {
                document.blocks[document.blocks.count - 1].content.append(text)
                continue
            }
            guard document.blocks.count < blockLimit else { document.isTruncated = true; break }

            let kind: Block.Kind
            switch leaf?.kind {
            case .header(let level): kind = .heading(level)
            case .codeBlock(let language): kind = .code(language.map { String($0.prefix(40)) })
            default: kind = .paragraph
            }
            let listItems = intents.filter { if case .listItem = $0.kind { true } else { false } }
            var marker: String?
            if let item = listItems.first, seenListItems.insert(item.identity).inserted {
                let list = intents.first(where: { $0.kind == .orderedList || $0.kind == .unorderedList })
                if list?.kind == .orderedList, case .listItem(let ordinal) = item.kind {
                    marker = "\(ordinal)."
                } else { marker = "•" }
            }
            document.blocks.append(Block(id: identity, kind: kind, content: text,
                listMarker: marker, listDepth: listItems.count,
                isQuote: intents.contains(where: { $0.kind == .blockQuote })))
        }

        // Preserve otherwise invisible unsupported markup as selectable literal text.
        if document.blocks.isEmpty {
            document.blocks = [Block(id: -1, kind: .paragraph, content: AttributedString(bounded),
                listMarker: nil, listDepth: 0, isQuote: false)]
        }
        return document
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 8_192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }
}
