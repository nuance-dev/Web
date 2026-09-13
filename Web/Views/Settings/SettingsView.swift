import SwiftUI
import WebKit

struct SettingsView: View {
    @AppStorage("settingsCategory") private var selectedCategory: SettingsCategory = .general

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case privacy = "Privacy"
        case security = "Security"
        case advanced = "Advanced"
        case aiProvider = "Providers"
        case modelManagement = "Local models"
        case usageBilling = "Usage"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "sidebar.left"
            case .privacy: "hand.raised"
            case .security: "lock.shield"
            case .advanced: "terminal"
            case .aiProvider: "sparkles"
            case .modelManagement: "externaldrive"
            case .usageBilling: "chart.bar"
            }
        }
    }

    static func open(_ category: SettingsCategory) {
        UserDefaults.standard.set(category.rawValue, forKey: "settingsCategory")
        KeyboardShortcutHandler.shared.showSettingsPanel = true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            sidebar
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(selectedCategory.rawValue).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { KeyboardShortcutHandler.shared.showSettingsPanel = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close settings")
                    .help("Close settings · Esc")
                }
                .padding(.horizontal, 4)
                .frame(height: 30)
                ScrollView {
                    settingsContent
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .openUsageBilling)) { _ in selectedCategory = .usageBilling }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
            List(selection: Binding<SettingsCategory?>(get: { selectedCategory }, set: { if let value = $0 { selectedCategory = value } })) {
                Section("Browser") {
                    ForEach(Array(SettingsCategory.allCases.prefix(5))) { category in sidebarRow(category) }
                }
                Section("Assistant") {
                    ForEach(Array(SettingsCategory.allCases.suffix(3))) { category in sidebarRow(category) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 4)
        .frame(width: 152)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        Label(category.rawValue, systemImage: category.icon)
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .tag(category)
    }

    @ViewBuilder private var settingsContent: some View {
        switch selectedCategory {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .privacy: PrivacySettingsView()
        case .security: BasicSecuritySettingsView()
        case .advanced: AdvancedSettingsView()
        case .aiProvider: AIProviderSettingsView()
        case .modelManagement: ModelManagementView()
        case .usageBilling: UsageBillingView()
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("searchEngine") private var searchEngine: BrowserSearchEngine = .google
    @AppStorage("restorePreviousSession") private var restoreSession = false

    var body: some View {
        SettingsStack {
            SettingsCard("Search", icon: "magnifyingglass") {
                HStack {
                    Text("Search engine")
                    Spacer()
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(BrowserSearchEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 140)
                }
            }
            SettingsCard("Glance", icon: "rectangle.bottomthird.inset.filled") { PeekSettingsView() }
            SettingsCard("At launch", icon: "arrow.clockwise") {
                SettingsToggle(title: "Reopen tabs", detail: "Saves normal tabs. Private tabs are never restored.", isOn: $restoreSession)
            }
        }
    }
}

struct BasicSecuritySettingsView: View {
    @StateObject private var safeBrowsing = SafeBrowsingManager.shared
    @StateObject private var adBlock = AdBlockService.shared
    @StateObject private var downloads = DownloadManager.shared
    @State private var showLookupSettings = false

    var body: some View {
        SettingsStack {
            SettingsCard("Connections", icon: "lock") {
                SettingsValueRow(title: "HTTPS certificates", value: "Verified by macOS")
                SettingsNote("Invalid certificates are blocked. HTTP pages remain available.")
            }
            SettingsCard("Content", icon: "shield.lefthalf.filled") {
                SettingsToggle(title: "Block ads and trackers", detail: "Applies to new tabs. Filter rules may miss some content.", isOn: $adBlock.isEnabled)
            }
            SettingsCard("Website checks", icon: "checkmark.shield") {
                SettingsToggle(title: "Google Safe Browsing", detail: "Sends visited URLs to Google. Requires an API key. Private tabs skip these checks.", isOn: $safeBrowsing.allowRemoteLookups)
                Button("Configure API key…") { showLookupSettings = true }.buttonStyle(.glass)
            }
            SettingsCard("Downloads", icon: "arrow.down.circle") {
                SettingsToggle(title: "Check for suspicious files", isOn: $downloads.securityScanEnabled)
                Divider()
                SettingsToggle(title: "Show warnings", isOn: $downloads.showSecurityWarnings)
                Divider()
                SettingsToggle(title: "Apply macOS quarantine", isOn: $downloads.autoQuarantineDownloads)
                SettingsNote("Checks can miss threats. Open only files you trust.")
            }
        }
        .sheet(isPresented: $showLookupSettings) { SafeBrowsingSettingsView() }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("tabDisplayMode") private var tabDisplay: TabDisplayMode = .sidebar
    @AppStorage("hideTopBar") private var hideTopBar = false
    @AppStorage("matchPageColor") private var matchPageColor = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SettingsStack {
            SettingsCard("Browser chrome", icon: "macwindow") {
                Picker("Tabs", selection: $tabDisplay) {
                    Text("Sidebar").tag(TabDisplayMode.sidebar)
                    Text("Top").tag(TabDisplayMode.topBar)
                    Text("Hidden").tag(TabDisplayMode.hidden)
                }.pickerStyle(.segmented)
                Divider()
                SettingsToggle(title: "Show address bar", detail: "⌘L always brings the address into focus.",
                    isOn: Binding(get: { !hideTopBar }, set: { hideTopBar = !$0 }))
                SettingsToggle(title: "Match page color", detail: "Use the page’s color behind browser controls.",
                    isOn: $matchPageColor)
            }
            SettingsCard("System appearance", icon: "circle.lefthalf.filled") {
                SettingsValueRow(title: "Color scheme", value: "Follows macOS")
                SettingsValueRow(title: "Reduce Motion", value: reduceMotion ? "On" : "Off")
                SettingsValueRow(title: "Reduce Transparency", value: reduceTransparency ? "On" : "Off")
                SettingsNote("Liquid Glass and motion follow your macOS accessibility settings.")
            }
        }
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("enableDeveloperTools") private var enableDeveloperTools = false

    var body: some View {
        SettingsStack {
            SettingsCard("Developer", icon: "terminal") {
                SettingsToggle(title: "Web Inspector", detail: "New tabs appear in Safari's Develop menu.", isOn: $enableDeveloperTools)
            }
            SettingsCard("Browsing data", icon: "externaldrive") {
                SettingsNote("Clear website storage and page visits in Privacy settings. Downloaded files stay on your Mac.")
            }
        }
    }
}

#Preview { SettingsView().frame(width: 720, height: 570) }
