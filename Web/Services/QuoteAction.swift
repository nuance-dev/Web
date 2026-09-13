import AppKit
import WebKit

struct QuoteSelection {
    let text: String
    let documentURL: URL
    let isMainFrame: Bool
    let isEditable: Bool

    init(text: String, documentURL: URL, isMainFrame: Bool = true, isEditable: Bool = false) {
        self.text = text
        self.documentURL = documentURL
        self.isMainFrame = isMainFrame
        self.isEditable = isEditable
    }

    init?(result: Any) {
        guard let values = result as? [String: Any],
              let text = values["text"] as? String,
              let address = values["url"] as? String, let url = URL(string: address),
              let isMainFrame = values["isMainFrame"] as? Bool,
              let isEditable = values["isEditable"] as? Bool else { return nil }
        self.init(text: text, documentURL: url, isMainFrame: isMainFrame, isEditable: isEditable)
    }
}

/// Formats an explicit selection without storing or interpreting the page's text.
enum QuotePolicy {
    static let maximumSelectionLength = 4_000

    static func clipboardText(
        selection: QuoteSelection, sourceURL: URL, currentURL: URL?,
        sourceRevision: UInt64, currentRevision: UInt64?
    ) -> String? {
        guard NavigationResolver.isWebURL(sourceURL), sourceURL.absoluteString.utf8.count <= 8_192,
              currentURL == sourceURL, selection.documentURL == sourceURL,
              sourceRevision == currentRevision,
              selection.isMainFrame, !selection.isEditable,
              selection.text.utf16.count <= maximumSelectionLength else { return nil }
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text + "\n\n" + sourceURL.absoluteString
    }
}

@MainActor
enum QuoteAction {
    /// Call before any link-only context-menu handling. Selection text lives only
    /// in each one-shot read; the menu item retains no excerpt or private-page cache.
    static func addMenuItem(
        to menu: NSMenu, for webView: WKWebView,
        documentRevision: @escaping () -> UInt64?
    ) {
        guard let sourceURL = webView.url, NavigationResolver.isWebURL(sourceURL),
              let revision = documentRevision() else { return }
        readSelection(from: webView) { [weak menu, weak webView] selection in
            guard let menu, let webView, let selection,
                  QuotePolicy.clipboardText(selection: selection, sourceURL: sourceURL,
                      currentURL: webView.url, sourceRevision: revision,
                      currentRevision: documentRevision()) != nil,
                  !menu.items.contains(where: { $0.identifier == QuoteMenuItem.itemIdentifier }) else { return }
            let item = QuoteMenuItem(webView: webView, sourceURL: sourceURL, sourceRevision: revision,
                                     documentRevision: documentRevision)
            let copyIndex = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
            menu.insertItem(item, at: copyIndex.map { $0 + 1 } ?? 0)
            menu.update()
        }
    }

    fileprivate static func readSelection(from webView: WKWebView, completion: @escaping (QuoteSelection?) -> Void) {
        webView.evaluateJavaScript(selectionScript, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value): completion(QuoteSelection(result: value))
            case .failure: completion(nil)
            }
        }
    }

    // Isolated, read-only DOM access. No script messages, listeners or page mutations.
    private static let selectionScript = """
    (() => {
      if (window.top !== window) return null;
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || selection.rangeCount !== 1) return null;
      const text = selection.toString();
      if (!text.trim() || text.length > 4000) return null;
      const elementFor = node => node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
      const editable = node => {
        const element = elementFor(node);
        return !!element && (element.isContentEditable || !!element.closest('input, textarea, select'));
      };
      const range = selection.getRangeAt(0);
      let isEditable = editable(selection.anchorNode) || editable(selection.focusNode) || editable(document.activeElement);
      if (!isEditable) {
        const root = elementFor(range.commonAncestorContainer);
        if (root) {
          const fields = root.querySelectorAll('input, textarea, select, [contenteditable]');
          if (fields.length > 1000) return null;
          isEditable = Array.from(fields).some(field => editable(field) && range.intersectsNode(field));
        }
      }
      return { text, url: document.URL, isMainFrame: true, isEditable };
    })()
    """
}

@MainActor
private final class QuoteMenuItem: NSMenuItem, NSMenuItemValidation {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("Web.CopyQuote")
    private weak var webView: WKWebView?
    private let sourceURL: URL
    private let sourceRevision: UInt64
    private let documentRevision: () -> UInt64?

    init(webView: WKWebView, sourceURL: URL, sourceRevision: UInt64, documentRevision: @escaping () -> UInt64?) {
        self.webView = webView
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.documentRevision = documentRevision
        super.init(title: "Copy Quote", action: #selector(copyQuote(_:)), keyEquivalent: "")
        target = self
        identifier = Self.itemIdentifier
    }

    required init(coder: NSCoder) { fatalError("QuoteMenuItem does not support decoding") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        webView?.url == sourceURL && documentRevision() == sourceRevision
    }

    @objc private func copyQuote(_ sender: NSMenuItem) {
        guard let webView, validateMenuItem(self) else { return }
        // Keep the action alive until its one-shot read completes. It holds the
        // WebView weakly, and never stores selection text after the menu closes.
        QuoteAction.readSelection(from: webView) { [self, weak webView] selection in
            guard let webView, let selection,
                  let text = QuotePolicy.clipboardText(selection: selection, sourceURL: sourceURL,
                      currentURL: webView.url, sourceRevision: sourceRevision,
                      currentRevision: documentRevision()) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
