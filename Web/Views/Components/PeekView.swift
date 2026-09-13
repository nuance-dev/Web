import SwiftUI
import WebKit

struct PeekView: View {
    @ObservedObject var controller: PeekController
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(.secondary)
                    Text("Glance").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if controller.isExpanded {
                        tool(controller.isPinned ? "pin.fill" : "pin", label: controller.isPinned ? "Unpin Glance" : "Keep Glance open") { controller.isPinned.toggle() }
                        tool("arrow.up.left.and.arrow.down.right", label: "Open in Web") { controller.openInWeb() }
                    } else {
                        Text(controller.shortcut.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    tool("xmark", label: "Close Glance") { controller.dismiss() }
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search or paste a link", text: $controller.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($inputFocused)
                        .onSubmit { controller.submit(); inputFocused = false }
                        .accessibilityLabel("Glance search")
                    Menu {
                        ForEach(BrowserSearchEngine.allCases) { engine in
                            Button(engine.title) { controller.engine = engine }
                        }
                    } label: {
                        Text(controller.engine.title).font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Search engine")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            }
            .padding(10)

            if controller.isExpanded {
                Divider()
                HStack(spacing: 8) {
                    tool("chevron.left", label: "Back") { controller.back() }
                        .disabled(!controller.canGoBack)
                    tool(controller.isLoading ? "xmark" : "arrow.clockwise", label: controller.isLoading ? "Stop loading" : "Reload") { controller.reload() }
                    HStack(spacing: 5) {
                        Image(systemName: controller.pageURL?.scheme == "https" ? "lock" : "exclamationmark.triangle")
                            .font(.system(size: 9))
                        Text(controller.pageURL?.host ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    Spacer()
                    if controller.isLoading { ProgressView().controlSize(.mini) }
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Temporary session. Closing Glance clears its page and cookies.")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                if let error = controller.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "network.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button("Try again") { controller.reload() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let webView = controller.webView {
                    PeekWebSurface(webView: webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { inputFocused = true }
        .onChange(of: controller.focusRequest) { _, _ in inputFocused = true }
    }

    private func tool(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(BrowserControlStyle())
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct PeekWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PeekSettingsView: View {
    @ObservedObject private var controller = PeekController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortcut")
                Spacer()
                Picker("Shortcut", selection: $controller.shortcut) {
                    ForEach(PeekShortcut.allCases) { shortcut in Text(shortcut.label).tag(shortcut) }
                }.labelsHidden().frame(width: 150)
            }
            Text(controller.shortcutAvailable ? "A quick browser, in your screen corner." : "Shortcut in use. Choose another.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
