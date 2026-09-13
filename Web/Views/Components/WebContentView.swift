import SwiftUI
import WebKit

struct WebContentView: View {
    @ObservedObject var tab: Tab
    let tabManager: TabManager
    @State private var showFind = false
    @State private var findFocusRequest = UUID()
    @StateObject private var windowReference = BrowserWindowReference()
    @State private var hoveredLink: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if tab.isHibernated {
                    Button { tab.wakeUp() } label: {
                        ZStack {
                            if let snapshot = tab.snapshot {
                                Image(nsImage: snapshot).resizable().scaledToFit()
                            }
                            Label("Resume tab", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                } else {
                    PersistentWebView(tab: tab, hoveredLink: $hoveredLink)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(tab.url == nil ? 0 : 1)
                        .allowsHitTesting(tab.url != nil)
                    if tab.url == nil { NewTabView(tab: tab) }
                }
                if tab.isLoading {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width, height: 2)
                        .scaleEffect(x: CGFloat(SafeNumericConversions.safeProgress(tab.estimatedProgress)), y: 1, anchor: .leading)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: tab.estimatedProgress)
                        .accessibilityLabel("Loading page")
                        .accessibilityValue("\(Int(SafeNumericConversions.safeProgress(tab.estimatedProgress) * 100)) percent")
                        .allowsHitTesting(false)
                }
                VStack {
                    Spacer()
                    HStack {
                        if let hoveredLink, !hoveredLink.isEmpty {
                            Text(hoveredLink)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .frame(maxWidth: 600, alignment: .leading)
                        }
                        Spacer()
                    }
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topTrailing) {
                if showFind, let webView = tab.webView {
                    BrowserFindBar(webView: webView, focusRequest: findFocusRequest) {
                        showFind = false
                        webView.window?.makeFirstResponder(webView)
                    }
                    .padding(12)
                }
            }
        }
        .background(BrowserWindowReader(reference: windowReference))
        .onReceive(NotificationCenter.default.publisher(for: .findInPageRequested)) { _ in
            guard windowReference.acceptsCommands, tab.url != nil else { return }
            showFind = true
            findFocusRequest = UUID()
        }
    }
}

/// Keeps one WebKit view and coordinator for each tab across SwiftUI updates.
struct PersistentWebView: View {
    @ObservedObject var tab: Tab
    @Binding var hoveredLink: String?

    var body: some View {
        WebView(tab: tab, hoveredLink: $hoveredLink)
        .id(tab.id)
    }
}


private struct BrowserFindBar: View {
    let webView: WKWebView
    let focusRequest: UUID
    let onClose: () -> Void
    @State private var query = ""
    @State private var hasMatch = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            BrowserFindField(text: $query, focusRequest: focusRequest,
                             onFind: { find(backward: $0) }, onClose: onClose)
                .frame(minWidth: 64, idealWidth: 160, maxWidth: 160)
                .onChange(of: query) { _, _ in find(backward: false) }
            if !query.isEmpty && !hasMatch {
                Text("No matches")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button { find(backward: true) } label: {
                Image(systemName: "chevron.up").font(.system(size: 11)).frame(width: 24, height: 26)
            }
            .buttonStyle(BrowserControlStyle())
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(query.isEmpty)
            .help("Previous match (⇧⌘G)")
            .accessibilityLabel("Previous match")
            Button { find(backward: false) } label: {
                Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 24, height: 26)
            }
            .buttonStyle(BrowserControlStyle())
            .keyboardShortcut("g", modifiers: .command)
            .disabled(query.isEmpty)
            .help("Next match (⌘G)")
            .accessibilityLabel("Next match")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 26)
            }
            .buttonStyle(BrowserControlStyle())
            .help("Close find (Esc)")
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func find(backward: Bool) {
        let requestedQuery = query
        let configuration = WKFindConfiguration()
        configuration.backwards = backward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(requestedQuery, configuration: configuration) { result in
            guard query == requestedQuery else { return }
            hasMatch = requestedQuery.isEmpty || result.matchFound
        }
    }
}

/// Focus the actual field after AppKit attaches it, once for each Command-F request.
private struct BrowserFindField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onFind: (Bool) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> FindTextField { FindTextField() }

    func updateNSView(_ field: FindTextField, context: Context) {
        field.onTextChange = { text = $0 }
        field.onFind = onFind
        field.onClose = onClose
        if field.stringValue != text { field.stringValue = text }
        field.requestFocus(focusRequest)
    }

    final class FindTextField: NSTextField, NSTextFieldDelegate {
        var onTextChange: ((String) -> Void)?
        var onFind: ((Bool) -> Void)?
        var onClose: (() -> Void)?
        private var pendingFocusRequest: UUID?
        private var completedFocusRequest: UUID?
        private var focusScheduled = false

        init() {
            super.init(frame: .zero)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            isEditable = true
            isSelectable = true
            focusRingType = .none
            font = .systemFont(ofSize: 13)
            placeholderString = "Find in page"
            delegate = self
            setAccessibilityLabel("Find in page")
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFocus()
        }

        func requestFocus(_ request: UUID) {
            guard request != completedFocusRequest else { return }
            pendingFocusRequest = request
            scheduleFocus()
        }

        private func scheduleFocus() {
            guard window != nil, pendingFocusRequest != nil, !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard let window = self.window, window.isKeyWindow,
                      let request = self.pendingFocusRequest,
                      window.makeFirstResponder(self) else { return }
                self.selectText(nil)
                self.completedFocusRequest = request
                self.pendingFocusRequest = nil
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            onTextChange?(stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:)) ||
                commandSelector == #selector(NSTextView.insertLineBreak(_:)) ||
                commandSelector == #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)) {
                onFind?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onClose?()
                return true
            }
            return false
        }
    }
}
