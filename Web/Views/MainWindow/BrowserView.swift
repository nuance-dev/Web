import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var tabManager = TabManager()
    
    var body: some View {
        TabDisplayView(tabManager: tabManager)
            .overlay { PanelManager(tabManager: tabManager) }
            .background(BrowserWindowBridge(tabManager: tabManager))
            .onAppear { PeekController.shared.openBrowserWindow = { openWindow(id: "browser") } }
            .onOpenURL { url in
                guard NavigationResolver.isWebURL(url) else { return }
                tabManager.createNewTab(url: url)
            }
    }
}

private struct BrowserWindowBridge: NSViewRepresentable {
    let tabManager: TabManager

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.tabManager = tabManager
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) { nsView.tabManager = tabManager }

    final class WindowView: NSView {
        var tabManager: TabManager?
        private var observer: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private var keyObserver: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            guard let window else { return }
            attach(window)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                    object: window, queue: .main) { [weak self, weak window] _ in
                if let window { PeekController.shared.detach(from: window) }
                if let window { KeyboardShortcutHandler.shared.unregisterBrowserWindow(window) }
                self?.tabManager?.closeWindow()
            }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window else { return }
                self?.attach(window)
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window else { return }
                self?.attach(window)
            }
        }
        private func attach(_ window: NSWindow) {
            guard let tabManager else { return }
            KeyboardShortcutHandler.shared.registerBrowserWindow(window)
            if (window.isMainWindow || window.isKeyWindow), let tab = tabManager.activeTab {
                KeyboardShortcutHandler.shared.browserWindowBecameActive(window)
                URLSynchronizer.shared.updateFromTabSwitch(tabID: tab.id, url: tab.url, title: tab.title,
                                                          isLoading: tab.isLoading, progress: tab.estimatedProgress,
                                                          isHibernated: tab.isHibernated)
            }
            PeekController.shared.attach(to: window) { [weak tabManager] url, isPrivate in
                if isPrivate {
                    tabManager?.createIncognitoTab(url: url)
                } else {
                    tabManager?.createNewTab(url: url)
                }
            }
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }
}

#Preview {
    BrowserView()
        .frame(width: 1200, height: 800)
}
