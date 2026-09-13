import SwiftUI

struct SafeBrowsingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = SafeBrowsingManager.shared
    @StateObject private var keys = SafeBrowsingKeyManager.shared
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var status: String?
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Safe Browsing").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            SettingsStack {
                SettingsCard("URL checks", icon: "checkmark.shield") {
                    SettingsToggle(title: "Allow Google URL checks", detail: "Sends visited URLs to Google. Private tabs skip remote checks.", isOn: $manager.allowRemoteLookups)
                }
                SettingsCard("Your API key", icon: "key") {
                    SecureField("Google Safe Browsing API key", text: $apiKey).textFieldStyle(.roundedBorder)
                    SettingsNote(keys.hasValidAPIKey ? "A validated key is configured." : "No validated key is configured.")
                    HStack(spacing: 8) {
                        Button("Save key", action: save).buttonStyle(.glassProminent)
                            .disabled(isSaving || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove…", role: .destructive) { confirmRemoval = true }
                            .buttonStyle(.glass).disabled(isSaving || !keys.hasValidAPIKey)
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                    if let status { SettingsNote(status) }
                }
            }
            SettingsNote("URL checks can miss threats. macOS certificate validation stays on independently.")
        }
        .padding(16)
        .frame(width: 430)
        .alert("Remove API key?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                isSaving = true
                Task {
                    await keys.removeAPIKey()
                    manager.allowRemoteLookups = false
                    isSaving = false
                    status = "URL checks are off."
                }
            }
        } message: { Text("Remote URL checks will be turned off.") }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await keys.storeAPIKey(apiKey)
                apiKey = ""
                status = keys.hasValidAPIKey ? "Key saved and validated." : "Key saved. Validation is unavailable."
            } catch { status = "Couldn't save this key. Check it and try again." }
            isSaving = false
        }
    }
}
