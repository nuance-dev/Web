import SwiftUI

struct ModelManagementView: View {
    @ObservedObject private var discovery = ModelDiscoveryService.shared
    @ObservedObject private var providers = AIProviderManager.shared
    @State private var inspectedModel: ModelDiscoveryService.DiscoveredModel?
    @State private var isRefreshing = false

    private var localProvider: LocalMLXProvider? {
        providers.availableProviders.first(where: { $0.providerType == .local }) as? LocalMLXProvider
    }

    var body: some View {
        SettingsStack {
            SettingsCard("Included model", icon: "cpu") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalModelDefaults.displayName).fontWeight(.medium)
                        Text("733 MB download on first use · Apple Silicon")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use local AI") { SettingsView.open(.aiProvider) }.buttonStyle(.glass)
                }
                Text("Replies run on this Mac. Downloading requires an internet connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Found on this Mac", icon: "externaldrive") {
                HStack {
                    Text("\(discovery.discoveredModels.count) models").foregroundStyle(.secondary)
                    Spacer()
                    if discovery.isScanning || isRefreshing { ProgressView().controlSize(.mini) }
                    Button("Scan again", systemImage: "arrow.clockwise", action: refresh)
                        .buttonStyle(.glass).disabled(discovery.isScanning || isRefreshing)
                }
                if discovery.discoveredModels.isEmpty {
                    Text("No model folders found. The included model works without adding one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.discoveredModels) { model in
                        Divider()
                        Button { inspectedModel = model } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name).lineLimit(1)
                                    Text(model.isValid ? "Model files found" : "Incomplete model files")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(model.sizeGB, specifier: "%.1f") GB")
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SettingsCard("Model folders", icon: "folder") {
                HStack {
                    Text("Scan your own MLX model folders.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add folder", systemImage: "plus", action: chooseFolder)
                        .buttonStyle(.glass).disabled(discovery.isScanning)
                }
                ForEach(discovery.getUserModelPaths(), id: \.self) { path in
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { removeFolder(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Stop scanning this folder; keep its files")
                            .accessibilityLabel("Remove \(URL(fileURLWithPath: path).lastPathComponent) from model folders")
                            .disabled(discovery.isScanning)
                    }
                }
            }
        }
        .sheet(item: $inspectedModel) { model in
            VStack(alignment: .leading, spacing: 14) {
                Text(model.name).font(.title3.weight(.semibold))
                LabeledContent("Size", value: String(format: "%.1f GB", model.sizeGB))
                LabeledContent("Source", value: model.source.displayName)
                if let architecture = model.metadata?.architecture {
                    LabeledContent("Architecture", value: architecture)
                }
                if let quantization = model.metadata?.quantization {
                    LabeledContent("Quantization", value: quantization)
                }
                Text("Compatibility is checked when you load the model.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
                    }
                    Spacer()
                    Button("Done") { inspectedModel = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 390)
        }
    }

    private func refresh() {
        guard !isRefreshing, !discovery.isScanning else { return }
        isRefreshing = true
        Task {
            if let localProvider { await localProvider.refreshModels() }
            else { await discovery.scanForModels() }
            providers.objectWillChange.send()
            isRefreshing = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add folder"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let localProvider { await localProvider.addUserModelDirectory(url.path) }
                else { await discovery.addUserModelPath(url.path) }
                providers.objectWillChange.send()
            }
        }
    }

    private func removeFolder(_ path: String) {
        Task {
            if let localProvider { await localProvider.removeUserModelDirectory(path) }
            else { await discovery.removeUserModelPath(path) }
            providers.objectWillChange.send()
        }
    }
}
