import AppKit
import SwiftUI

struct CompactWindowControls: View {
    var body: some View {
        NativeWindowControls().frame(width: 72, height: 36)
    }
}

private struct NativeWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.updateTargets() }

    final class ControlsView: NSView {
        private var buttons: [NSButton] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = NSWindow.standardWindowButton(type, for: style) else { continue }
                buttons.append(button)
                addSubview(button)
            }
        }

        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: NSSize { NSSize(width: 72, height: 36) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTargets()
        }

        func updateTargets() {
            for button in buttons {
                button.target = window
                button.isEnabled = window != nil
                button.needsDisplay = true
            }
        }

        override func layout() {
            super.layout()
            let spacing: CGFloat = 8
            let width = buttons.reduce(0) { $0 + $1.frame.width }
                + spacing * CGFloat(max(0, buttons.count - 1))
            var x = ((bounds.width - width) / 2).rounded()
            for button in buttons {
                button.setFrameOrigin(NSPoint(x: x, y: ((bounds.height - button.frame.height) / 2).rounded()))
                x += button.frame.width + spacing
            }
        }
    }
}

// Kept for views that need a one-time AppKit window lookup.
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { callback(view.window) }
    }
}
