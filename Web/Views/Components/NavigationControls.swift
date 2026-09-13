import SwiftUI
import WebKit

struct NavigationControls: View {
  @ObservedObject var tab: Tab
  @State private var showHistory = false

  var body: some View {
    HStack(spacing: 2) {
      NavigationButton(
        icon: "chevron.left", isEnabled: tab.canGoBack, label: "Back", action: tab.goBack
      )
      .contextMenu {
        ForEach(
          Array((tab.webView?.backForwardList.backList ?? []).reversed().enumerated()),
          id: \.offset
        ) { _, item in
          Button(item.title ?? item.url.host ?? item.url.absoluteString) {
            tab.webView?.go(to: item)
          }
        }
      }
      .onLongPressGesture { if tab.canGoBack { showHistory = true } }
      .popover(isPresented: $showHistory) { BackHistoryView(tab: tab) }
      NavigationButton(
        icon: "chevron.right", isEnabled: tab.canGoForward, label: "Forward",
        action: tab.goForward)
      NavigationButton(
        icon: tab.isLoading ? "xmark" : "arrow.clockwise", isEnabled: true,
        label: tab.isLoading ? "Stop loading" : "Reload"
      ) {
        if tab.isLoading { tab.stopLoading() } else { tab.reload() }
      }
    }
  }
}

struct NavigationButton: View {
  let icon: String
  let isEnabled: Bool
  var isLoading = false
  var label: String = ""
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(BrowserControlStyle())
    .disabled(!isEnabled)
    .onHover { hovering = $0 }
    .help(label)
    .accessibilityLabel(label)
  }
}

struct BackHistoryView: View {
  @ObservedObject var tab: Tab
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Back history")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(6)
      let entries = Array((tab.webView?.backForwardList.backList ?? []).reversed())
      if entries.isEmpty {
        Text("No earlier pages").foregroundStyle(.secondary).padding(6)
      }
      ForEach(Array(entries.enumerated()), id: \.offset) { _, item in
        Button {
          tab.webView?.go(to: item)
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(item.title ?? item.url.host ?? "Page").lineLimit(1)
            Text(item.url.host ?? item.url.absoluteString)
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }
        .buttonStyle(BrowserControlStyle())
      }
    }
    .padding(6)
    .frame(width: 280)
  }
}
