import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject private var providers = AIProviderManager.shared
    @ObservedObject private var runner = SimplifiedMLXRunner.shared
    @State private var keyProvider: SecureKeyStorage.AIProvider?
    @State private var showingKeySheet = false
    @State private var pendingKey = ""
    @State private var status: String?
    @State private var keyError: String?
    @State private var switchingName: String?
    private let storage = SecureKeyStorage.shared

    var body: some View {
        SettingsStack {
            SettingsCard("Use a model", icon: "cpu") {
                if let local = providers.availableProviders.first(where: { $0.providerType == .local }) {
                    providerRow(local, detail: "On this Mac · no API key")
                }
                ForEach(SecureKeyStorage.AIProvider.allCases, id: \.self) { type in
                    Divider()
                    if let provider = providers.availableProviders.first(where: { $0.providerId == type.rawValue }) {
                        providerRow(provider, detail: "API key connected", keyType: type)
                    } else {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName).fontWeight(.medium)
                                Text("Your API key").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { beginKeyEntry(type) }.buttonStyle(.glass)
                        }
                    }
                }
                if providers.isInitializing {
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(switchingName ?? "provider")…").foregroundStyle(.secondary)
                    }
                    if runner.isLoading {
                        ProgressView(value: Double(runner.loadProgress))
                        Text("The first download can take a few minutes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let provider = providers.currentProvider {
                SettingsCard("\(provider.displayName)", icon: "slider.horizontal.3") {
                    HStack {
                        Text("Model")
                        Spacer()
                        Picker("Model", selection: Binding(
                            get: { provider.selectedModel?.id ?? "" },
                            set: { id in
                                guard let model = provider.availableModels.first(where: { $0.id == id }) else { return }
                                providers.updateSelectedModel(model)
                            })) {
                                ForEach(provider.availableModels, id: \.id) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 260)
                            .disabled(providers.isInitializing)
                    }
                    if let model = provider.selectedModel, let price = model.pricing,
                       let input = price.inputPerMTokensUSD, let output = price.outputPerMTokensUSD {
                        Text("Per million tokens: \(input, format: .currency(code: "USD")) in · \(output, format: .currency(code: "USD")) out")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if provider.providerType == .external {
                        Divider()
                        CloudPageSharingToggle(providerID: provider.providerId, providerName: provider.displayName)
                    } else {
                        Text("Page text and replies stay on this Mac. Private pages are excluded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard("API billing", icon: "creditcard") {
                Text("ChatGPT, Codex and Claude subscriptions don't cover these API requests.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Keys are stored in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Usage & limits") { SettingsView.open(.usageBilling) }.buttonStyle(.glass)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.horizontal, 4)
            }
        }
        .sheet(isPresented: $showingKeySheet, onDismiss: {
            pendingKey = ""
            keyError = nil
        }) { keySheet }
    }

    private func providerRow(_ provider: AIProvider, detail: String,
                             keyType: SecureKeyStorage.AIProvider? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if providers.currentProvider?.providerId == provider.providerId {
                Label("Selected", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Use") { switchProvider(provider) }
                    .buttonStyle(.glass).disabled(providers.isInitializing)
                    .accessibilityLabel("Use \(provider.displayName)")
            }
            if let keyType {
                Menu {
                    Button("Replace API key") { beginKeyEntry(keyType) }
                    Button("Remove API key", role: .destructive) { removeKey(keyType) }
                } label: { Image(systemName: "ellipsis").frame(width: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(providers.isInitializing).help("\(provider.displayName) options")
            }
        }
    }

    private var keySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(keyProvider?.displayName ?? "provider")").font(.title3.weight(.semibold))
            SecureField("API key", text: $pendingKey).textFieldStyle(.roundedBorder)
                .onSubmit(saveKey)
                .accessibilityLabel("API key")
            HStack {
                if let type = keyProvider { Link("Get an API key", destination: keyURL(type)) }
                Spacer()
                Text("Saved in Keychain").font(.caption).foregroundStyle(.secondary)
            }
            if let keyError { Text(keyError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { showingKeySheet = false }.keyboardShortcut(.cancelAction)
                Button("Save key", action: saveKey).buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 410)
    }

    private func beginKeyEntry(_ type: SecureKeyStorage.AIProvider) {
        keyProvider = type
        pendingKey = ""
        keyError = nil
        showingKeySheet = true
    }

    private func saveKey() {
        guard let type = keyProvider else { return }
        do {
            try storage.storeAPIKey(pendingKey.trimmingCharacters(in: .whitespacesAndNewlines), for: type)
            providers.addExternalProvider(type)
            pendingKey = ""
            showingKeySheet = false
            status = "Key saved. Choose Use to connect."
        } catch { keyError = error.localizedDescription }
    }

    private func removeKey(_ type: SecureKeyStorage.AIProvider) {
        do {
            try storage.deleteAPIKey(for: type)
            providers.removeExternalProvider(type)
            status = "\(type.displayName) key removed."
        } catch { status = error.localizedDescription }
    }

    private func switchProvider(_ provider: AIProvider) {
        guard !providers.isInitializing else { return }
        switchingName = provider.displayName
        status = nil
        Task {
            do { try await providers.switchProvider(to: provider) }
            catch { status = error.localizedDescription }
            switchingName = nil
        }
    }

    private func keyURL(_ type: SecureKeyStorage.AIProvider) -> URL {
        switch type {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }
}

/// Explicit consent is separate for each cloud provider and starts off.
struct CloudPageSharingToggle: View {
    let providerID: String
    let providerName: String
    @AppStorage private var enabled: Bool

    init(providerID: String, providerName: String) {
        self.providerID = providerID
        self.providerName = providerName
        _enabled = AppStorage(wrappedValue: false, AIContextPolicy.sharingKey(for: providerID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Share pages with \(providerName)", isOn: $enabled)
                .toggleStyle(.switch).controlSize(.small)
            Text("Sends page text with your questions and summaries. Private pages and browsing history stay excluded.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: enabled) { _, _ in
            NotificationCenter.default.post(name: .aiPageSharingChanged, object: providerID)
        }
    }
}

extension Notification.Name {
    static let aiPageSharingChanged = Notification.Name("aiPageSharingChanged")
}
