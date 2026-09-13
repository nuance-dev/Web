import AppKit
import WebKit

/// Keeps page clipping in AppKit without flattening WebKit into a SwiftUI mask.
final class NativePageContainer: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: webView.frame)
        wantsLayer = true
        clipsToBounds = true
        canDrawSubviewsIntoLayer = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        webView.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(webView)
        webView.frame = bounds
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        // A retained tab may already have moved into a newly mounted container.
        guard webView.superview === self else { return }
        webView.frame = bounds
    }
}
