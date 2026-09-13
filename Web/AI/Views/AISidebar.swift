import Combine
import SwiftUI

/// One read-only conversation per browser window.
struct AISidebar: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var providers = AIProviderManager.shared
    @ObservedObject private var runner = SimplifiedMLXRunner.shared
    @StateObject private var assistant: AIAssistant
    @StateObject private var windowReference = BrowserWindowReference()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var isExpanded = false
    @State private var input = ""
    @State private var responseTask: Task<Void, Never>?
    @State private var showingPageOptions = false
    @State private var includeLocalPage = true
    @State private var sharingRevision = 0
    @State private var followsLatest = true

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        _assistant = StateObject(wrappedValue: AIAssistant(tabManager: tabManager))
    }

    private var hasPage: Bool {
        guard let tab = tabManager.activeTab, !tab.isIncognito,
              let scheme = tab.url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private var includesPage: Bool {
        _ = sharingRevision
        guard hasPage, let provider = providers.currentProvider else { return false }
        return provider.providerType == .local ? includeLocalPage :
            AIContextPolicy.canSharePage(providerID: provider.providerId, isPrivate: false)
    }

    private var isBusy: Bool { responseTask != nil || assistant.isProcessing }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        header
                        if providers.isInitializing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("Switching provider…").font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                            }.padding(.horizontal, 4)
                        }
                        transcript
                        if let error = assistant.lastError { errorNotice(error) }
                        composer
                    }
                    .padding(10)
                }
                .frame(width: 326)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: isExpanded ? 330 : 0)
        .frame(maxHeight: .infinity)
        .background(BrowserWindowReader(reference: windowReference))
        .onReceive(NotificationCenter.default.publisher(for: .toggleAISidebar)) { _ in
            guard windowReference.acceptsCommands else { return }
            setExpanded(!isExpanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAIInput)) { _ in
            guard windowReference.acceptsCommands else { return }
            setExpanded(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .performAskRequested)) { _ in
            guard windowReference.acceptsCommands else { return }
            setExpanded(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .performTLDRRequested)) { _ in
            guard windowReference.acceptsCommands else { return }
            summarizePage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiPageSharingChanged)) { _ in
            responseTask?.cancel()
            sharingRevision += 1
        }
        .onReceive(providers.$currentProvider.dropFirst()) { _ in responseTask?.cancel() }
        .onDisappear { responseTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.system(size: 14, weight: .semibold))
                modelMenu
            }
            Spacer(minLength: 0)
            Menu {
                Button("New conversation", systemImage: "square.and.pencil") {
                    assistant.clearConversation()
                    assistant.lastError = nil
                    inputFocused = true
                }
                .disabled(isBusy || assistant.messages.isEmpty)
                Divider()
                Button("AI settings", systemImage: "slider.horizontal.3") {
                    SettingsView.open(.aiProvider)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Assistant options")
            Button { setExpanded(false) } label: {
                Image(systemName: "sidebar.right").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Close assistant")
            .accessibilityLabel("Close assistant")
        }
        .padding(.horizontal, 2)
    }

    private var modelMenu: some View {
        Menu {
            if let provider = providers.currentProvider {
                Text(provider.displayName)
                ForEach(provider.availableModels, id: \.id) { model in
                    Button {
                        providers.updateSelectedModel(model)
                    } label: {
                        if provider.selectedModel?.id == model.id {
                            Label(model.name, systemImage: "checkmark")
                        } else { Text(model.name) }
                    }
                }
                Divider()
            }
            Button("Choose provider…") { SettingsView.open(.aiProvider) }
        } label: {
            HStack(spacing: 4) {
                Text(providers.currentProvider?.selectedModel?.name ?? "Choose model")
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isBusy || assistant.isInitializing || providers.isInitializing)
        .help("Choose model")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if assistant.messages.isEmpty { welcome }
                    ForEach(assistant.messages) { message in
                        AssistantMessageRow(message: message,
                            streamingText: assistant.animationState.streamingMessageId == message.id
                                ? assistant.streamingText : nil)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, atBottom in followsLatest = atBottom }
            .onChange(of: assistant.messageCount) { _, _ in
                proxy.scrollTo("latest", anchor: .bottom)
            }
            .onChange(of: assistant.streamingText) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
            Text("A little help, right here.").font(.system(size: 20, weight: .medium))
            Text(providers.currentProvider?.providerType == .local
                 ? "Ask a question or read a page together. Replies stay on this Mac."
                 : "Ask a question. You choose whether to share the page.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if assistant.isInitializing {
                loadingStatus
            } else if assistant.isInitialized {
                Button(action: summarizePage) {
                    Label("Summarize this page", systemImage: "text.alignleft")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(!hasPage || isBusy)
            }
        }
        .padding(.top, 28)
    }

    private var loadingStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(assistant.initializationStatus).font(.system(size: 12))
            }
            if providers.currentProvider?.providerType == .local, runner.isLoading {
                ProgressView(value: Double(runner.loadProgress)).tint(.secondary)
                Text("First use downloads the model. This can take a few minutes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func errorNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(5)
                .help(error)
            if !assistant.isInitialized {
                HStack {
                    Button("Try again") { Task { await assistant.initialize() } }
                        .disabled(assistant.isInitializing)
                    Button("Choose provider") { SettingsView.open(.aiProvider) }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .font(.system(size: 13)).lineLimit(1...5)
                .textFieldStyle(.plain).focused($inputFocused)
                .onSubmit { sendMessage() }
                .accessibilityLabel("Message to assistant")
            HStack(spacing: 6) {
                Button { showingPageOptions.toggle() } label: {
                    Label(includesPage ? "Page included" : "Page off",
                          systemImage: includesPage ? "doc.text" : "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(includesPage ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPageOptions, arrowEdge: .bottom) { pageOptions }
                Spacer()
                if isBusy {
                    Text("Responding").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button {
                    if isBusy { responseTask?.cancel() } else { sendMessage() }
                } label: {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(!isBusy && (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assistant.isInitialized || providers.isInitializing))
                .help(isBusy ? "Stop response" : "Send message")
                .accessibilityLabel(isBusy ? "Stop response" : "Send message")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var pageOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Page context").font(.headline)
            if tabManager.activeTab?.isIncognito == true {
                Text("Private pages are never shared with the assistant.")
            } else if let provider = providers.currentProvider, provider.providerType == .external {
                CloudPageSharingToggle(providerID: provider.providerId, providerName: provider.displayName)
            } else {
                Toggle("Include this page", isOn: $includeLocalPage)
                    .toggleStyle(.switch).controlSize(.small)
                Text("Page text is read on this Mac. Browsing history stays excluded.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).padding(16).frame(width: 280)
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isExpanded = expanded }
        NotificationCenter.default.post(name: .aISidebarStateChanged, object: expanded)
        inputFocused = expanded
        if expanded { Task { await assistant.initialize() } }
    }

    private func summarizePage() {
        setExpanded(true)
        guard hasPage else {
            assistant.lastError = "Open a regular webpage to summarize it."
            return
        }
        guard includesPage else { showingPageOptions = true; return }
        guard !isBusy else { return }
        input = "Summarize this page in three short bullet points. Use only the supplied page; say if it is unavailable."
        Task { await assistant.initialize(); sendMessage() }
    }

    private func sendMessage() {
        let message = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !providers.isInitializing, assistant.isInitialized, !message.isEmpty else { return }
        let sharePage = includesPage
        input = ""
        followsLatest = true
        assistant.lastError = nil
        responseTask = Task {
            defer { responseTask = nil }
            do {
                for try await _ in assistant.processStreamingQuery(message, includeContext: sharePage, includeHistory: false) {
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                // The producer preserves the partial reply and restores its idle state.
            } catch {
                assistant.lastError = error.localizedDescription
            }
        }
    }
}

private struct AssistantMessageRow: View {
    let message: ConversationMessage
    let streamingText: String?
    private var content: String { streamingText ?? message.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if message.role == .user {
                Text(content).font(.system(size: 13, weight: .medium))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 12))
            } else if content.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text((try? AttributedString(markdown: content,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content))
                    .font(.system(size: 13)).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
            .disabled(content.isEmpty)
        }
    }
}
