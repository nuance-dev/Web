import AppKit
import SwiftUI

/// Chrome stays quiet at rest; pointer and press feedback stay inside each target.
struct BrowserControlStyle: ButtonStyle {
  var glass = false
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        Color.primary.opacity(
          isEnabled && !glass ? (configuration.isPressed ? 0.10 : hovering ? 0.055 : 0) : 0),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .glassEffect(
        glass && isEnabled && (hovering || configuration.isPressed)
          ? .regular.interactive() : .identity,
        in: .rect(cornerRadius: 6)
      )
      .opacity(isEnabled ? 1 : 0.35)
      .onHover { hovering = $0 }
  }
}

struct TabContextMenu: View {
  let tab: Tab
  let tabManager: TabManager

  var body: some View {
    Button(tab.isPinned ? "Unpin tab" : "Pin tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
    {
      tabManager.togglePin(tab)
    }
    Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
      .disabled(tab.url == nil)
    Button("Duplicate tab", systemImage: "plus.square.on.square") {
      _ = tabManager.duplicateTab(tab)
    }
    if let url = tab.url {
      Button("Copy link", systemImage: "link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
      }
    }
    Divider()
    Button("Close tab", systemImage: "xmark") { tabManager.closeTab(tab) }
    Button("Close other tabs") { tabManager.closeOtherTabs(except: tab) }
      .disabled(tabManager.tabs.count < 2)
    Button("Close tabs to the right") { tabManager.closeTabsToTheRight(of: tab) }
      .disabled(tabManager.tabs.last?.id == tab.id)
    Button("Close duplicate tabs") { _ = tabManager.closeDuplicateTabs() }
      .disabled(tabManager.tabs.count < 2)
    if !tabManager.recentlyClosedTabs.isEmpty {
      Divider()
      Button("Reopen closed tab", systemImage: "arrow.uturn.backward") {
        _ = tabManager.reopenLastClosedTab()
      }
    }
  }
}

/// Lets a view route application menu commands to its own window.
@MainActor
final class BrowserWindowReference: ObservableObject {
  weak var window: NSWindow?
  @Published private(set) var isKeyWindow = false
  private var observers: [NSObjectProtocol] = []
  var acceptsCommands: Bool { window?.isKeyWindow == true }

  func attach(_ window: NSWindow?) {
    guard self.window !== window else { return }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    self.window = window
    guard let window else {
      isKeyWindow = false
      return
    }
    isKeyWindow = window.isKeyWindow
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self, weak window] _ in
          Task { @MainActor in self?.isKeyWindow = window?.isKeyWindow ?? false }
        })
    }
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

struct BrowserWindowReader: NSViewRepresentable {
  let reference: BrowserWindowReference

  func makeNSView(context: Context) -> WindowView {
    let view = WindowView()
    view.reference = reference
    return view
  }

  func updateNSView(_ view: WindowView, context: Context) { view.reference = reference }

  final class WindowView: NSView {
    weak var reference: BrowserWindowReference?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let currentWindow = window
      DispatchQueue.main.async { [weak self, weak currentWindow] in
        self?.reference?.attach(currentWindow)
      }
    }
  }
}
