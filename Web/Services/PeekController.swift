import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI
import WebKit

extension Notification.Name {
    static let togglePeekRequested = Notification.Name("togglePeekRequested")
}

enum PeekShortcut: String, CaseIterable, Identifiable {
    case commandOptionSpace, controlOptionSpace, commandShiftSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commandOptionSpace: return "⌥⌘Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .commandShiftSpace: return "⇧⌘Space"
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .commandOptionSpace: return UInt32(cmdKey | optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }
    var eventModifiers: NSEvent.ModifierFlags {
        switch self {
        case .commandOptionSpace: return [.command, .option]
        case .controlOptionSpace: return [.control, .option]
        case .commandShiftSpace: return [.command, .shift]
        }
    }
}

private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PeekGeometry {
    static func frame(in visible: NSRect, expanded: Bool) -> NSRect {
        let width = min(expanded ? 520.0 : 440.0, max(1, visible.width - 32))
        let height = min(expanded ? 600.0 : 92.0, max(1, visible.height - 32))
        return NSRect(x: visible.maxX - width - 16, y: visible.minY + 16, width: width, height: height)
    }
}

/// Owns the temporary browsing surface and its single global hotkey.
@MainActor
final class PeekController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = PeekController()
    @Published var query = ""
    @Published var engine: BrowserSearchEngine = .google
    @Published private(set) var isExpanded = false
    @Published var isPinned = false
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var pageURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusRequest = UUID()
    @Published private(set) var shortcutAvailable = true
    @Published var shortcut: PeekShortcut = PeekShortcut(rawValue: UserDefaults.standard.string(forKey: "peekShortcut") ?? "") ?? .controlOptionSpace {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "peekShortcut")
            registerShortcut()
        }
    }

    private(set) var webView: WKWebView?
    var openBrowserWindow: (() -> Void)?
    private var pendingPromotionURL: URL?
    private var pendingPromotionIsPrivate = false
    private weak var linkSourceWindow: NSWindow?
    private var linkSourceIsPrivate: Bool?
    private weak var focusOriginWindow: NSWindow?
    private var focusOriginApplication: NSRunningApplication?
    private var panel: PeekPanel?
    private var screen: NSScreen?
    private weak var browserWindow: NSWindow?
    private final class BrowserTarget {
        weak var window: NSWindow?
        let promote: (URL, Bool) -> Void

        init(window: NSWindow, promote: @escaping (URL, Bool) -> Void) {
            self.window = window
            self.promote = promote
        }
    }
    private var browserTargets: [ObjectIdentifier: BrowserTarget] = [:]
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private var observations: [NSKeyValueObservation] = []
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var shortcutMonitor: Any?
    private var lastShortcutTime: TimeInterval = 0

    private override init() {
        super.init()
        NotificationCenter.default.publisher(for: .togglePeekRequested)
            .sink { [weak self] _ in self?.toggle() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    func start() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == OSType(0x5745504B), identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in PeekController.shared.handleShortcut() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
        registerShortcut()
        // Also handle keys delivered directly to the app, including when a system
        // shortcut prevents global registration. Carbon remains the global path.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == self.shortcut.eventModifiers else { return event }
            if !event.isARepeat { self.handleShortcut() }
            return nil
        }
    }

    private func handleShortcut() {
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastShortcutTime > 0.08 else { return }
        lastShortcutTime = time
        toggle()
    }

    func attach(to window: NSWindow, promote: @escaping (URL, Bool) -> Void) {
        browserTargets = browserTargets.filter { $0.value.window != nil }
        let identifier = ObjectIdentifier(window)
        let isNewWindow = browserTargets[identifier] == nil
        browserTargets[identifier] = BrowserTarget(window: window, promote: promote)
        browserWindow = window
        if isNewWindow, let url = pendingPromotionURL {
            let isPrivate = pendingPromotionIsPrivate
            pendingPromotionURL = nil
            pendingPromotionIsPrivate = false
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                promote(url, isPrivate)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func detach(from window: NSWindow) {
        browserTargets.removeValue(forKey: ObjectIdentifier(window))
        if browserWindow === window { browserWindow = nil }
    }

    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let identifier = EventHotKeyID(signature: OSType(0x5745504B), id: 1)
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_Space), shortcut.modifiers, identifier,
                                                GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func toggle() {
        if panel?.isVisible == true { dismiss() } else { show() }
    }

    func show() {
        if panel?.isVisible != true {
            if let linkSourceWindow {
                focusOriginWindow = linkSourceWindow
                focusOriginApplication = .current
            } else {
                let application = NSWorkspace.shared.frontmostApplication
                let keyWindow = NSApp.keyWindow === panel ? nil : NSApp.keyWindow
                focusOriginApplication = application
                focusOriginWindow = application?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    ? keyWindow ?? NSApp.mainWindow : nil
            }
        }
        if panel == nil { makePanel() }
        screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        reposition()
        panel?.makeKeyAndOrderFront(nil)
        focusRequest = UUID()
        installDismissMonitors()
    }

    func dismiss(restoringFocus: Bool = true) {
        let originWindow = focusOriginWindow
        let originApplication = focusOriginApplication
        let currentApplication = NSWorkspace.shared.frontmostApplication
        let currentPID = ProcessInfo.processInfo.processIdentifier
        // Outside clicks and app switches choose their own focus destination.
        let shouldRestoreFocus = restoringFocus && panel?.isKeyWindow == true
            && (currentApplication?.processIdentifier == currentPID
                || currentApplication?.processIdentifier == originApplication?.processIdentifier)
        focusOriginWindow = nil
        focusOriginApplication = nil
        panel?.orderOut(nil)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        mouseMonitor = nil
        localMonitor = nil
        // Closing a peek releases the page, storage and media immediately.
        webView?.stopLoading()
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        observations.removeAll()
        webView = nil
        isExpanded = false
        isLoading = false
        canGoBack = false
        pageURL = nil
        query = ""
        errorMessage = nil
        isPinned = false
        linkSourceWindow = nil
        linkSourceIsPrivate = nil
        if shouldRestoreFocus {
            if originApplication?.processIdentifier == currentPID {
                if let originWindow, originWindow.isVisible, !originWindow.isMiniaturized {
                    originWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else if let originApplication, !originApplication.isTerminated {
                originApplication.activate(options: [])
            }
        }
    }

    /// Opens an explicitly chosen link without creating a browser tab.
    func open(_ url: URL, from sourceWindow: NSWindow, isPrivate: Bool) {
        guard NavigationResolver.isWebURL(url) else { return }
        dismiss(restoringFocus: false)
        linkSourceWindow = sourceWindow
        linkSourceIsPrivate = isPrivate
        query = url.absoluteString
        show()
        load(url)
    }

    func submit() {
        guard let url = NavigationResolver.resolve(query, engine: engine) else {
            errorMessage = "Enter a web address or search."
            return
        }
        load(url)
    }

    private func load(_ url: URL) {
        guard NavigationResolver.isWebURL(url) else { return }
        errorMessage = nil
        if webView == nil { makeWebView() }
        pageURL = url
        isExpanded = true
        reposition(animated: true)
        webView?.load(URLRequest(url: url))
    }

    func back() { webView?.goBack() }
    func reload() {
        errorMessage = nil
        if isLoading { webView?.stopLoading() } else { webView?.reload() }
    }

    func openInWeb() {
        guard let url = webView?.url ?? pageURL, NavigationResolver.isWebURL(url) else { return }
        let sourcePrivacy = linkSourceIsPrivate
        let targetWindow = sourcePrivacy == nil ? browserWindow : linkSourceWindow
        if let window = targetWindow, window.isVisible || window.isMiniaturized,
           let target = browserTargets[ObjectIdentifier(window)], target.window === window {
            let promote = target.promote
            dismiss(restoringFocus: false)
            promote(url, sourcePrivacy == true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let openBrowserWindow else { return }
        pendingPromotionURL = url
        pendingPromotionIsPrivate = sourcePrivacy == true
        dismiss(restoringFocus: false)
        openBrowserWindow()
    }

    private func makePanel() {
        let panel = PeekPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glance"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: PeekView(controller: self))
        self.panel = panel
    }

    private func makeWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard self?.webView === view else { return }
                    self?.isLoading = view.isLoading
                }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard self?.webView === view else { return }
                    self?.canGoBack = view.canGoBack
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard self?.webView === view else { return }
                    self?.pageURL = view.url
                }
            }
        ]
    }

    private func reposition(animated: Bool = false) {
        guard let panel else { return }
        let availableScreens = NSScreen.screens
        if screen == nil || !availableScreens.contains(where: { $0 === screen }) {
            screen = NSScreen.main ?? availableScreens.first
        }
        guard let visible = screen?.visibleFrame else { return }
        let frame = PeekGeometry.frame(in: visible, expanded: isExpanded)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }

    private func installDismissMonitors() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in if self?.isPinned == false { self?.dismiss(restoringFocus: false) } }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.panel?.isVisible == true else { return event }
                if event.type == .keyDown, event.window === self.panel {
                    if event.keyCode == 53 { self.dismiss(); return nil }
                    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.keyCode == UInt16(kVK_ANSI_L) {
                        self.query = self.pageURL?.absoluteString ?? ""
                        self.focusRequest = UUID()
                        return nil
                    }
                } else if event.type != .keyDown, event.window !== self.panel, !self.isPinned {
                    self.dismiss(restoringFocus: false)
                }
                return event
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url, NavigationResolver.isWebURL(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationResponse.canShowMIMEType { decisionHandler(.allow) }
        else {
            errorMessage = "Open in Web to download this file."
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, NavigationResolver.isWebURL(url) { load(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { handle(error) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { handle(error) }
    }
    private func handle(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        errorMessage = "Couldn't load this page. Try again."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        isLoading = false
        errorMessage = "This page stopped. Reload to continue."
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}
