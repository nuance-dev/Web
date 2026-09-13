import SwiftUI
import WebKit

struct PrivacySettingsView: View {
    @AppStorage("blockAutoplay") private var blockAutoplay = true
    @StateObject private var context = ContextManager.shared
    @State private var clearWebsiteData = false
    @State private var clearHistory = false
    @State private var isClearing = false
    @State private var status: String?

    var body: some View {
        SettingsStack {
            SettingsCard("Private browsing", icon: "eye.slash") {
                SettingsValueRow(title: "Website storage", value: "Temporary")
                SettingsNote("Private tabs skip history, saved passwords and AI page context. Downloads remain on your Mac.")
            }
            SettingsCard("Pages", icon: "play.circle") {
                SettingsToggle(title: "Click to play media", detail: "Applies to new tabs.", isOn: $blockAutoplay)
                SettingsNote("Automatic pop-ups are blocked. Sign-in pages may open a window to finish authentication.")
            }
            SettingsCard("AI context", icon: "sparkles") {
                SettingsToggle(title: "Include recent history", detail: "Adds recent page titles and URLs to AI context. Cloud page sharing still requires its own permission.", isOn: $context.isHistoryContextEnabled)
            }
            SettingsCard("Stored data", icon: "externaldrive") {
                HStack(spacing: 8) {
                    Button("Website data…") { clearWebsiteData = true }
                    Button("History…") { clearHistory = true }
                    if isClearing { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.glass)
                .disabled(isClearing)
                SettingsNote("Clearing cookies and website storage signs you out. Bookmarks and downloaded files are kept.")
                if let status { SettingsNote(status) }
            }
            SettingsCard("Network", icon: "network") {
                SettingsValueRow(title: "DNS", value: "Your Mac's settings")
                SettingsNote("Private browsing does not hide traffic from websites or your network.")
            }
        }
        .alert("Clear website data?", isPresented: $clearWebsiteData) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                isClearing = true
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast) {
                    isClearing = false
                    status = "Website data cleared. Open pages may store new data."
                }
            }
        } message: { Text("This clears cookies and storage for regular tabs. Saved files and passwords are kept.") }
        .alert("Clear browsing history?", isPresented: $clearHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                isClearing = true
                HistoryService.shared.clearAllHistory { success in
                    isClearing = false
                    if success {
                        AutofillService.shared.clearHistory()
                        context.clearContextCache()
                        context.lastExtractedContext = nil
                        status = "Browsing history cleared."
                    } else { status = "Couldn't clear history. Try again." }
                }
            }
        } message: { Text("This removes page visits and address suggestions. Bookmarks and downloads are kept.") }
    }
}
