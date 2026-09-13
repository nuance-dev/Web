import AppKit
import Combine
import SwiftUI
import os.log

enum BrowserPanel: CaseIterable, Hashable {
    case commands, about, settings, history, downloads, bookmarks
}

@MainActor
final class PanelWindowRegistry {
    private final class Entry {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var entries: [Entry] = []
    private weak var lastActiveWindow: NSWindow?

    func register(_ window: NSWindow) {
        entries.removeAll { $0.window == nil }
        if !entries.contains(where: { $0.window === window }) { entries.append(Entry(window)) }
        if lastActiveWindow == nil || window.isKeyWindow || window.isMainWindow { lastActiveWindow = window }
    }

    func unregister(_ window: NSWindow) {
        entries.removeAll { $0.window == nil || $0.window === window }
        if lastActiveWindow === window { lastActiveWindow = nil }
    }

    func markActive(_ window: NSWindow) {
        guard contains(window) else { return }
        lastActiveWindow = window
    }

    func resolve(explicit: NSWindow? = nil, keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
        if let explicit {
            let owner = sheetOwner(of: explicit)
            return contains(owner) ? owner : nil
        }
        for candidate in [keyWindow, mainWindow].compactMap({ $0 }) {
            let owner = sheetOwner(of: candidate)
            if contains(owner), owner.isVisible || owner.isMiniaturized { return owner }
        }
        // A nonactivating panel can leave AppKit without a key/main window.
        // Keep menu actions attached to the last known live browser in that gap.
        if let lastActiveWindow, contains(lastActiveWindow),
           lastActiveWindow.isVisible || lastActiveWindow.isMiniaturized { return lastActiveWindow }
        return entries.compactMap(\.window).first { $0.isVisible || $0.isMiniaturized }
    }

    private func contains(_ window: NSWindow) -> Bool { entries.contains { $0.window === window } }
    private func sheetOwner(of window: NSWindow) -> NSWindow {
        var owner = window
        while let parent = owner.sheetParent { owner = parent }
        return owner
    }
}

/// Presentation belongs to the window that requested it, independently of focus.
struct PanelPresentationState {
    private var windows: [Int: Set<BrowserPanel>] = [:]

    func panels(in windowNumber: Int?) -> Set<BrowserPanel> {
        guard let windowNumber else { return [] }
        return windows[windowNumber] ?? []
    }

    mutating func set(_ panel: BrowserPanel, isPresented: Bool, in windowNumber: Int?) {
        guard let windowNumber else { return }
        if isPresented {
            windows[windowNumber, default: []].insert(panel)
        } else {
            windows[windowNumber]?.remove(panel)
            if windows[windowNumber]?.isEmpty == true { windows.removeValue(forKey: windowNumber) }
        }
    }

    mutating func dismissTopPanel(in windowNumber: Int?) {
        let presented = panels(in: windowNumber)
        if let top = BrowserPanel.allCases.first(where: { presented.contains($0) }) {
            set(top, isPresented: false, in: windowNumber)
        }
    }

    mutating func closeWindow(_ windowNumber: Int) {
        windows.removeValue(forKey: windowNumber)
    }
}

/// Service for handling keyboard shortcuts for history, bookmarks, and downloads
/// Provides a centralized way to manage keyboard shortcuts without overloading views
@MainActor
class KeyboardShortcutHandler: ObservableObject {
    static let shared = KeyboardShortcutHandler()

    private let logger = Logger(subsystem: "com.example.Web", category: "KeyboardShortcutHandler")
    private var cancellables = Set<AnyCancellable>()
    private let panelWindows = PanelWindowRegistry()

    @Published private(set) var presentations = PanelPresentationState()

    // Existing buttons and SettingsView.open use these properties. Resolve their
    // action's window once in the setter; changing focus never moves a panel.
    var showHistoryPanel: Bool {
        get { isPresented(.history) }
        set { setPresented(.history, newValue) }
    }
    var showBookmarksPanel: Bool {
        get { isPresented(.bookmarks) }
        set { setPresented(.bookmarks, newValue) }
    }
    var showDownloadsPanel: Bool {
        get { isPresented(.downloads) }
        set { setPresented(.downloads, newValue) }
    }
    var showSettingsPanel: Bool {
        get { isPresented(.settings) }
        set { setPresented(.settings, newValue) }
    }
    var showAboutPanel: Bool {
        get { isPresented(.about) }
        set { setPresented(.about, newValue) }
    }
    var showCommandPalette: Bool {
        get { isPresented(.commands) }
        set { setPresented(.commands, newValue) }
    }

    private var actionWindow: NSWindow? {
        panelWindows.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    private func isPresented(_ panel: BrowserPanel) -> Bool {
        presentations.panels(in: actionWindow?.windowNumber).contains(panel)
    }

    private func setPresented(_ panel: BrowserPanel, _ isPresented: Bool) {
        presentations.set(panel, isPresented: isPresented, in: actionWindow?.windowNumber)
    }

    func panels(in window: NSWindow?) -> Set<BrowserPanel> {
        presentations.panels(in: window?.windowNumber)
    }

    func dismissTopPanel(in window: NSWindow?) {
        presentations.dismissTopPanel(in: window?.windowNumber)
    }

    func registerBrowserWindow(_ window: NSWindow) { panelWindows.register(window) }

    func unregisterBrowserWindow(_ window: NSWindow) {
        panelWindows.unregister(window)
        presentations.closeWindow(window.windowNumber)
    }

    func browserWindowBecameActive(_ window: NSWindow) { panelWindows.markActive(window) }

    func togglePanel(_ panel: BrowserPanel, in window: NSWindow?) {
        guard let window else { return }
        panelWindows.register(window)
        let presented = presentations.panels(in: window.windowNumber).contains(panel)
        presentations.set(panel, isPresented: !presented, in: window.windowNumber)
    }

    func present(_ panel: BrowserPanel, in window: NSWindow?) {
        guard let window else { return }
        panelWindows.register(window)
        presentations.set(panel, isPresented: true, in: window.windowNumber)
    }

    // UI positioning for panels - using center-based coordinates that will be made safe by PanelManager
    @Published var historyPanelPosition = CGPoint(x: 400, y: 300)
    @Published var bookmarksPanelPosition = CGPoint(x: 450, y: 320)
    @Published var downloadsPanelPosition = CGPoint(x: 500, y: 340)
    @Published var settingsPanelPosition = CGPoint(x: 550, y: 360)
    @Published var aboutPanelPosition = CGPoint(x: 600, y: 380)

    // Dependencies
    private let historyService = HistoryService.shared
    private let bookmarkService = BookmarkService.shared
    private let downloadManager = DownloadManager.shared

    private init() {
        setupNotificationHandlers()
    }

    private func setupNotificationHandlers() {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                self?.unregisterBrowserWindow(window)
            }
            .store(in: &cancellables)

        // History shortcut (Cmd+Y)
        NotificationCenter.default.publisher(for: .showHistoryRequested)
            .sink { [weak self] _ in
                self?.handleShowHistory()
            }
            .store(in: &cancellables)

        // Bookmark shortcut (Cmd+D)
        NotificationCenter.default.publisher(for: .bookmarkPageRequested)
            .sink { [weak self] _ in
                self?.handleBookmarkPage()
            }
            .store(in: &cancellables)

        // Downloads shortcut (Cmd+Shift+J)
        NotificationCenter.default.publisher(for: .showDownloadsRequested)
            .sink { [weak self] _ in
                self?.handleShowDownloads()
            }
            .store(in: &cancellables)

        // Settings shortcut (Cmd+,)
        NotificationCenter.default.publisher(for: .showSettingsRequested)
            .sink { [weak self] _ in
                self?.handleShowSettings()
            }
            .store(in: &cancellables)

        // About shortcut
        NotificationCenter.default.publisher(for: .showAboutRequested)
            .sink { [weak self] _ in
                self?.handleShowAbout()
            }
            .store(in: &cancellables)

        // Command palette
        NotificationCenter.default.publisher(for: .showCommandPaletteRequested)
            .sink { [weak self] _ in
                self?.handleToggleCommandPalette(true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .hideCommandPaletteRequested)
            .sink { [weak self] _ in
                self?.handleToggleCommandPalette(false)
            }
            .store(in: &cancellables)
    }

    // MARK: - Handler Methods

    /// Handle Cmd+Y - Show History
    private func handleShowHistory() {
        showHistoryPanel.toggle()
        logger.info("History panel toggled: \(self.showHistoryPanel)")

    }

    /// Show the bookmark library without changing the current page's bookmark.
    private func handleBookmarkPage() {
        showBookmarksPanel.toggle()
    }

    /// Handle Cmd+Shift+J - Show Downloads
    @MainActor
    private func handleShowDownloads() {
        showDownloadsPanel.toggle()
        self.downloadManager.isVisible = showDownloadsPanel
        logger.info("Downloads panel toggled: \(self.showDownloadsPanel)")

        // Log current downloads
        logger.debug("Active downloads: \(self.downloadManager.totalActiveDownloads)")
        logger.debug("Total downloads in history: \(self.downloadManager.downloadHistory.count)")
    }

    /// Handle Cmd+, - Show Settings
    private func handleShowSettings() {
        showSettingsPanel.toggle()
        logger.info("Settings panel toggled: \(self.showSettingsPanel)")
    }

    /// Handle About - Show About
    private func handleShowAbout() {
        showAboutPanel.toggle()
        logger.info("About panel toggled: \(self.showAboutPanel)")
    }

    private func handleToggleCommandPalette(_ show: Bool) {
        showCommandPalette = show
        logger.info("Command Palette \(show ? "shown" : "hidden")")
    }

    // MARK: - Public Interface

    /// Bookmark the current page with explicit tab info
    func bookmarkCurrentPage(url: String, title: String) {
        bookmarkService.quickBookmark(url: url, title: title)
        logger.info("Bookmarked: \(title)")
    }

    /// Get autofill suggestions for URL bar
    func getAutofillSuggestions(for query: String, limit: Int = 10) -> [HistoryItem] {
        return historyService.getAutofillSuggestions(for: query, limit: limit)
    }

    /// Search history
    func searchHistory(query: String) -> [HistoryItem] {
        return historyService.searchHistory(query: query)
    }

    /// Search bookmarks
    func searchBookmarks(query: String) -> [Bookmark] {
        return bookmarkService.searchBookmarks(query: query)
    }

    /// Get recent downloads
    @MainActor
    func getRecentDownloads() -> [DownloadHistoryItem] {
        return Array(downloadManager.downloadHistory.prefix(20))
    }

    /// Check if URL is bookmarked
    func isBookmarked(url: String) -> Bool {
        return bookmarkService.isBookmarked(url: url)
    }

    /// Toggle bookmark for URL
    func toggleBookmark(url: String, title: String) {
        if isBookmarked(url: url) {
            // Find and remove bookmark
            if let bookmark = bookmarkService.getAllBookmarks().first(where: { $0.url == url }) {
                bookmarkService.deleteBookmark(bookmark)
                logger.info("Removed bookmark: \(title)")
            }
        } else {
            bookmarkService.quickBookmark(url: url, title: title)
            logger.info("Added bookmark: \(title)")
        }
    }
}
