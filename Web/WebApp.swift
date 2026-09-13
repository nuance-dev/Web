import SwiftUI

@main
struct WebApp: App {
    @NSApplicationDelegateAdaptor(WebApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "browser") {
            ContentView()
                .background(WindowConfigurator())
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands { BrowserCommands() }
    }
}

final class WebApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = KeyboardShortcutHandler.shared
        _ = ApplicationStateObserver.shared
        _ = BackgroundResourceManager.shared
        PeekController.shared.start()
    }
}

struct BrowserCommands: Commands {
    @AppStorage("tabDisplayMode") private var tabDisplayMode = TabDisplayMode.sidebar
    @AppStorage("hideTopBar") private var hideAddressBar = false
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NotificationCenter.default.post(name: .newTabRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                NotificationCenter.default.post(name: .closeTabRequested, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Reopen Closed Tab") {
                NotificationCenter.default.post(name: .reopenTabRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("New Private Tab") {
                NotificationCenter.default.post(name: .newIncognitoTabRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Picker("Tabs", selection: $tabDisplayMode) {
                Text("Sidebar").tag(TabDisplayMode.sidebar)
                Text("Top").tag(TabDisplayMode.topBar)
                Text("Hidden").tag(TabDisplayMode.hidden)
            }
            Button(tabDisplayMode == .sidebar ? "Move Tabs to Top" : "Move Tabs to Sidebar") {
                NotificationCenter.default.post(name: .toggleTabDisplay, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            Button(tabDisplayMode == .hidden ? "Show Tabs" : "Hide Tabs") {
                NotificationCenter.default.post(name: .toggleTabVisibility, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Toggle("Show Address Bar", isOn: Binding(
                get: { !hideAddressBar }, set: { hideAddressBar = !$0 }))
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Focus Mode") {
                NotificationCenter.default.post(name: .toggleEdgeToEdge, object: nil)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Glance") {
                PeekController.shared.toggle()
            }

            Button("Reload") {
                NotificationCenter.default.post(name: .reloadRequested, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Focus Address Bar") {
                NotificationCenter.default.post(name: .focusAddressBarRequested, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Page") {
                NotificationCenter.default.post(name: .findInPageRequested, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            // Removed emergency focus reset - no longer needed with simplified focus

        }

        BrowserLibraryCommands()

        CommandMenu("Settings") {
            Button("Preferences...") {
                NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Web") {
                NotificationCenter.default.post(name: .showAboutRequested, object: nil)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Commands and Shortcuts") {
                NotificationCenter.default.post(name: .showCommandPaletteRequested, object: nil)
            }
        }

        CommandMenu("AI Assistant") {
            Button("Toggle AI Sidebar") {
                NotificationCenter.default.post(name: .toggleAISidebar, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("Focus AI Input") {
                NotificationCenter.default.post(name: .focusAIInput, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Divider()

            Button("Command Palette…") {
                NotificationCenter.default.post(name: .showCommandPaletteRequested, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {

            Button("Next Tab") {
                NotificationCenter.default.post(name: .nextTabRequested, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Tab") {
                NotificationCenter.default.post(name: .previousTabRequested, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Tab (Control-Tab)") {
                NotificationCenter.default.post(name: .nextTabRequested, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: .control)

            Button("Previous Tab (Control-Tab)") {
                NotificationCenter.default.post(name: .previousTabRequested, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            // Tab selection shortcuts (Cmd+1 through Cmd+9)
            ForEach(1...9, id: \.self) { number in
                Button("Go to Tab \(number)") {
                    NotificationCenter.default.post(name: .selectTabByNumber, object: number)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}

private struct BrowserLibraryCommands: Commands {
    var body: some Commands {
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") {
                NotificationCenter.default.post(
                    name: .bookmarkCurrentPageRequested,
                    object: nil
                )
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Show All Bookmarks") {
                NotificationCenter.default.post(name: .bookmarkPageRequested, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            BookmarksMenuContent()
        }

        CommandMenu("History") {
            Button("Show All History") {
                NotificationCenter.default.post(name: .showHistoryRequested, object: nil)
            }
            .keyboardShortcut("y", modifiers: .command)

            Divider()

            HistoryMenuContent()
        }

        CommandMenu("Downloads") {
            Button("Show Downloads") {
                NotificationCenter.default.post(name: .showDownloadsRequested, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            DownloadsMenuContent()
        }
    }
}

// Notification names for keyboard shortcuts
extension Notification.Name {
    static let newTabRequested = Notification.Name("newTabRequested")
    static let newTabInBackgroundRequested = Notification.Name("newTabInBackgroundRequested")
    static let closeTabRequested = Notification.Name("closeTabRequested")
    static let reopenTabRequested = Notification.Name("reopenTabRequested")
    static let reloadRequested = Notification.Name("reloadRequested")
    static let focusAddressBarRequested = Notification.Name("focusAddressBarRequested")
    static let findInPageRequested = Notification.Name("findInPageRequested")
    static let showHistoryRequested = Notification.Name("showHistoryRequested")
    static let bookmarkPageRequested = Notification.Name("bookmarkPageRequested")
    static let bookmarkCurrentPageRequested = Notification.Name("bookmarkCurrentPageRequested")
    static let showDownloadsRequested = Notification.Name("showDownloadsRequested")
    static let showSettingsRequested = Notification.Name("showSettingsRequested")
    static let showAboutRequested = Notification.Name("showAboutRequested")
    static let showDeveloperToolsRequested = Notification.Name("showDeveloperToolsRequested")
    static let dismissHoverableURLBar = Notification.Name("dismissHoverableURLBar")
    static let hoverableURLBarDismissed = Notification.Name("hoverableURLBarDismissed")
    // Removed clearFocusForID - no longer needed with simplified focus

    // Phase 2: Next-Gen UI shortcuts
    static let toggleTabDisplay = Notification.Name("toggleTabDisplay")
    static let toggleTabVisibility = Notification.Name("toggleTabVisibility")
    static let toggleEdgeToEdge = Notification.Name("toggleEdgeToEdge")
    static let navigateBack = Notification.Name("navigateBack")
    static let navigateForward = Notification.Name("navigateForward")

    // Tab navigation shortcuts
    static let nextTabRequested = Notification.Name("nextTabRequested")
    static let previousTabRequested = Notification.Name("previousTabRequested")
    static let selectTabByNumber = Notification.Name("selectTabByNumber")
    static let navigateCurrentTab = Notification.Name("navigateCurrentTab")
    static let toggleTopBar = Notification.Name("toggleTopBar")
    static let createNewTabWithURL = Notification.Name("createNewTabWithURL")
    static let focusURLBarRequested = Notification.Name("focusURLBarRequested")

    // AI Assistant shortcuts are declared in `Utils/Extensions/Notifications+Names.swift`

    // Network error handling shortcuts
    static let showNoInternetConnection = Notification.Name("showNoInternetConnection")

    // Security and Privacy shortcuts
    // Note: newIncognitoTabRequested is defined in IncognitoSession.swift
}

// MARK: - Menu Content Views

/// Displays actual bookmarks in the Bookmarks menu
struct BookmarksMenuContent: View {
    @ObservedObject private var bookmarkService = BookmarkService.shared

    var body: some View {
        let bookmarks = bookmarkService.getAllBookmarks()

        if bookmarks.isEmpty {
            Text("No bookmarks")
                .foregroundColor(.secondary)
        } else {
            ForEach(bookmarks.prefix(15), id: \.id) { bookmark in
                Button(bookmark.title.isEmpty ? bookmark.url : bookmark.title) {
                    if let url = URL(string: bookmark.url) {
                        NotificationCenter.default.post(name: .createNewTabWithURL, object: url)
                    }
                }
                .truncationMode(.tail)
            }

            if bookmarks.count > 15 {
                Divider()
                Text("... and \(bookmarks.count - 15) more")
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Displays recent history in the History menu
struct HistoryMenuContent: View {
    @ObservedObject private var historyService = HistoryService.shared

    var body: some View {
        let recentHistory = historyService.recentHistory

        if recentHistory.isEmpty {
            Text("No history")
                .foregroundColor(.secondary)
        } else {
            // Show first 10 items directly
            ForEach(recentHistory.prefix(10), id: \.id) { item in
                Button(item.displayTitle) {
                    if let url = URL(string: item.url) {
                        NotificationCenter.default.post(name: .createNewTabWithURL, object: url)
                    }
                }
                .truncationMode(.tail)
            }

            // If there are more than 10 items, show them in submenus
            if recentHistory.count > 10 {
                Divider()

                // Show next 25 items in "Earlier Today" submenu
                if recentHistory.count > 10 {
                    let earlierItems = Array(recentHistory.dropFirst(10).prefix(25))
                    if !earlierItems.isEmpty {
                        Menu("Earlier Today") {
                            ForEach(earlierItems, id: \.id) { item in
                                Button(item.displayTitle) {
                                    if let url = URL(string: item.url) {
                                        NotificationCenter.default.post(
                                            name: .createNewTabWithURL, object: url)
                                    }
                                }
                                .truncationMode(.tail)
                            }
                        }
                    }
                }

                // Show next 50 items in "Yesterday & Earlier" submenu
                if recentHistory.count > 35 {
                    let olderItems = Array(recentHistory.dropFirst(35).prefix(50))
                    if !olderItems.isEmpty {
                        Menu("Yesterday & Earlier") {
                            ForEach(olderItems, id: \.id) { item in
                                Button(item.displayTitle) {
                                    if let url = URL(string: item.url) {
                                        NotificationCenter.default.post(
                                            name: .createNewTabWithURL, object: url)
                                    }
                                }
                                .truncationMode(.tail)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Displays recent downloads in the Downloads menu
struct DownloadsMenuContent: View {
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        let activeDownloads = downloadManager.downloads
        let recentHistory = downloadManager.downloadHistory

        if activeDownloads.isEmpty && recentHistory.isEmpty {
            Text("No downloads")
                .foregroundColor(.secondary)
        } else {
            // Show active downloads first
            if !activeDownloads.isEmpty {
                ForEach(activeDownloads, id: \.id) { download in
                    Button(download.filename) {
                        if download.status == .completed {
                            downloadManager.openDownloadedFile(download)
                        }
                    }
                    .disabled(download.status != .completed)
                }

                if !recentHistory.isEmpty {
                    Divider()
                }
            }

            // Show recent download history
            ForEach(recentHistory.prefix(10), id: \.id) { item in
                Button(item.filename) {
                    if item.fileExists {
                        NSWorkspace.shared.selectFile(item.filePath, inFileViewerRootedAtPath: "")
                    }
                }
                .disabled(!item.fileExists)
            }
        }
    }
}
