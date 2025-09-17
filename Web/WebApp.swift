import SwiftUI
import os.log

@main
struct WebApp: App {
    let coreDataStack = CoreDataStack.shared
    let keyboardShortcutHandler = KeyboardShortcutHandler.shared

    init() {
        configureLogging()
        // Initialize keyboard shortcut handler
        _ = keyboardShortcutHandler
        // Initialize application state observer to manage background resource policies
        _ = ApplicationStateObserver.shared
        // CRITICAL: Initialize comprehensive background resource manager for proper hibernation
        _ = BackgroundResourceManager.shared
        // SECURITY: Initialize runtime security monitor for JIT entitlement risk mitigation
        _ = RuntimeSecurityMonitor.shared
        // Initialize update service and check for updates in background
        setupUpdateChecker()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowConfigurator())
                .background(WindowClipGuard())  // Guardrail: forces clipsToBounds=true to avoid TUINS crash
                .environment(\.managedObjectContext, coreDataStack.viewContext)
        }
        // Use hiddenTitleBar style to remove the system title bar entirely
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            BrowserCommands()
        }
    }

    private func configureLogging() {
        // Set environment variables to reduce WebKit verbosity
        setenv("WEBKIT_DISABLE_VERBOSE_LOGGING", "1", 1)
        setenv("WEBKIT_SUPPRESS_PROCESS_LOGS", "1", 1)
        setenv("OS_ACTIVITY_MODE", "disable", 1)

        // Only log startup message in verbose mode
        AppLog.debug("Web browser started with reduced WebKit logging")
    }

    private func setupUpdateChecker() {
        // Note: UpdateService is referenced but not implemented yet
        // For now, we'll implement a basic update checker that responds to suspension
        setupBackgroundAwareUpdateChecker()
    }

    private func setupBackgroundAwareUpdateChecker() {
        var updateTimer: Timer?

        // Function to create the update timer
        let createUpdateTimer = {
            updateTimer?.invalidate()
            updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
                // Check for updates only if app is not in background
                if !BackgroundResourceManager.shared.isAppInBackground {
                    if AppLog.isVerboseEnabled { AppLog.debug("Checking for updates…") }
                    // updateService.checkForUpdates(manual: false) - Commented until UpdateService is implemented
                }
            }
        }

        // Create initial timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            createUpdateTimer()
        }

        // Listen for suspension notifications
        NotificationCenter.default.addObserver(
            forName: .suspendUpdateTimer, object: nil, queue: .main
        ) { _ in
            if AppLog.isVerboseEnabled { AppLog.debug("Suspending update timer") }
            updateTimer?.invalidate()
            updateTimer = nil
        }

        // Listen for resumption notifications
        NotificationCenter.default.addObserver(
            forName: .resumeUpdateTimer, object: nil, queue: .main
        ) { _ in
            if AppLog.isVerboseEnabled { AppLog.debug("Resuming update timer") }
            createUpdateTimer()
        }
    }
}

struct BrowserCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                // TODO: Implement new tab shortcut
                NotificationCenter.default.post(name: .newTabRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                // TODO: Implement close tab shortcut
                NotificationCenter.default.post(name: .closeTabRequested, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Reopen Closed Tab") {
                // TODO: Implement reopen closed tab shortcut
                NotificationCenter.default.post(name: .reopenTabRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("New Incognito Tab") {
                NotificationCenter.default.post(name: .newIncognitoTabRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
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

        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") {
                NotificationCenter.default.post(
                    name: .bookmarkCurrentPageRequested,
                    object: nil
                )
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Show All Bookmarks") {
                NotificationCenter.default.post(name: .bookmarkPageRequested, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)

            Divider()

            BookmarksMenuContent()
        }

        CommandMenu("History") {
            Button("Show All History") {
                NotificationCenter.default.post(name: .showHistoryRequested, object: nil)
            }
            .keyboardShortcut("y", modifiers: .command)

            Button("Clear History...") {
                NotificationCenter.default.post(name: .clearHistoryRequested, object: nil)
            }

            Divider()

            HistoryMenuContent()
        }

        CommandMenu("Downloads") {
            Button("Show Downloads") {
                NotificationCenter.default.post(name: .showDownloadsRequested, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Clear Downloads...") {
                NotificationCenter.default.post(name: .clearDownloadsRequested, object: nil)
            }

            Divider()

            DownloadsMenuContent()
        }

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

            Button("Developer Tools") {
                NotificationCenter.default.post(name: .showDeveloperToolsRequested, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("Toggle Tab Display") {
                NotificationCenter.default.post(name: .toggleTabDisplay, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Toggle Edge-to-Edge Mode") {
                NotificationCenter.default.post(name: .toggleEdgeToEdge, object: nil)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("Toggle Top Bar") {
                NotificationCenter.default.post(name: .toggleTopBar, object: nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Next Tab") {
                NotificationCenter.default.post(name: .nextTabRequested, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Tab") {
                NotificationCenter.default.post(name: .previousTabRequested, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Tab (Arrow)") {
                NotificationCenter.default.post(name: .nextTabRequested, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Previous Tab (Arrow)") {
                NotificationCenter.default.post(name: .previousTabRequested, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

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

    // Data clearing actions
    static let clearHistoryRequested = Notification.Name("clearHistoryRequested")
    static let clearDownloadsRequested = Notification.Name("clearDownloadsRequested")
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
