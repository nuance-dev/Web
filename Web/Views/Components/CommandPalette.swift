import AppKit
import SwiftUI

struct CommandPalette: View {
  var tabManager: TabManager? = nil
  @State private var query = ""
  @State private var selectionIndex = 0
  @FocusState private var searchFocused: Bool

  private var items: [PaletteItem] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [PaletteItem] = []
    if let manager = tabManager {
      let matchingTabs = manager.tabs.filter {
        term.isEmpty
          || "\($0.title) \($0.url?.absoluteString ?? "")".localizedCaseInsensitiveContains(term)
      }
      for tab in matchingTabs.prefix(term.isEmpty ? 6 : 12) {
        results.append(
          PaletteItem(
            id: tab.id.uuidString,
            title: tab.title.isEmpty ? "New tab" : tab.title,
            detail: tab.isIncognito ? "Private tab" : (tab.url?.host ?? "Open tab"),
            icon: tab.isIncognito ? "eye.slash" : "rectangle.on.rectangle",
            section: "Tabs", shortcut: tab.id == manager.activeTab?.id ? "Current" : nil
          ) {
            manager.setActiveTab(tab)
          })
      }
    }
    if let manager = tabManager, let tab = manager.activeTab {
      let tabActions: [PaletteItem] = [
        PaletteItem(
          id: "pin-current", title: tab.isPinned ? "Unpin current tab" : "Pin current tab",
          icon: "pin", section: "Actions"
        ) {
          manager.togglePin(tab)
        },
        PaletteItem(
          id: "deduplicate", title: "Close duplicate tabs", icon: "square.on.square",
          section: "Actions"
        ) {
          _ = manager.closeDuplicateTabs()
        },
      ]
      results += tabActions.filter {
        !term.isEmpty && $0.title.localizedCaseInsensitiveContains(term)
      }
    }
    let commands: [PaletteItem] = [
      command(
        "peek", "Open Glance", "rectangle.bottomthird.inset.filled",
        PeekController.shared.shortcut.label, .togglePeekRequested),
      command("new", "New tab", "plus", "⌘T", .newTabRequested),
      command("private", "New private tab", "eye.slash", "⇧⌘N", .newIncognitoTabRequested),
      command("reopen", "Reopen closed tab", "arrow.uturn.backward", "⇧⌘T", .reopenTabRequested),
      PaletteItem(id: "bookmarks", title: "Bookmarks", icon: "bookmark", section: "Actions") {
        KeyboardShortcutHandler.shared.showBookmarksPanel = true
      },
      PaletteItem(
        id: "history", title: "History", icon: "clock", section: "Actions", shortcut: "⌘Y"
      ) {
        KeyboardShortcutHandler.shared.showHistoryPanel = true
      },
      PaletteItem(
        id: "downloads", title: "Downloads", icon: "arrow.down.circle", section: "Actions"
      ) {
        KeyboardShortcutHandler.shared.showDownloadsPanel = true
      },
      command("summary", "Summarize this page", "text.alignleft", nil, .performTLDRRequested),
      command("ask", "Ask about this page", "bubble.left", nil, .performAskRequested),
      command("assistant", "Toggle assistant", "sidebar.right", nil, .toggleAISidebar),
      command("address", "Focus address bar", "magnifyingglass", "⌘L", .focusAddressBarRequested),
      command("settings", "Settings", "gearshape", "⌘,", .showSettingsRequested),
    ]
    results += commands.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) }
    if !term.isEmpty, let url = NavigationResolver.resolve(term) {
      let isSearch = term.contains(" ") || !term.contains(".") && !term.contains(":")
      results.append(
        PaletteItem(
          id: "navigate", title: isSearch ? "Search for “\(term)”" : "Open \(url.host ?? term)",
          detail: url.host, icon: isSearch ? "magnifyingglass" : "arrow.up.right", section: "Web"
        ) {
          NotificationCenter.default.post(name: .navigateCurrentTab, object: url)
        })
      if let youtube = BrowserSearchEngine.youtube.searchURL(for: term) {
        results.append(
          PaletteItem(
            id: "youtube", title: "Search YouTube", detail: term, icon: "play.rectangle",
            section: "Web"
          ) {
            NotificationCenter.default.post(name: .navigateCurrentTab, object: youtube)
          })
      }
    }
    return results
  }

  var body: some View {
    let available = items
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search tabs, commands, or the web", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 14))
          .focused($searchFocused)
          .onSubmit(executeSelected)
          .accessibilityLabel("Search tabs, commands, or the web")
        Text("esc")
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(4)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1)))
      }
      .padding(12)
      Divider().opacity(0.6)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(available.enumerated()), id: \.element.id) { index, item in
              if index == 0 || item.section != available[index - 1].section {
                Text(item.section)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 8)
                  .padding(.top, 7)
                  .padding(.bottom, 3)
              }
              resultRow(item, index: index)
                .id(item.id)
            }
            if available.isEmpty {
              Text("No results")
                .foregroundStyle(.secondary)
                .padding(16)
            }
          }
          .padding(.horizontal, 4)
          .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: 280)
        .onChange(of: selectionIndex) { _, index in
          if available.indices.contains(index) { proxy.scrollTo(available[index].id) }
        }
        .onChange(of: query) { _, _ in
          selectionIndex = 0
          if let first = available.first { proxy.scrollTo(first.id, anchor: .top) }
        }
      }
      Divider().opacity(0.6)
      HStack(spacing: 8) {
        Text("↑ ↓  Navigate")
        Spacer()
        Text("↵  Open")
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
    }
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .frame(maxWidth: 560)
    .fixedSize(horizontal: false, vertical: true)
    .task {
      selectionIndex = 0
      await Task.yield()
      searchFocused = true
    }
    .onExitCommand(perform: hide)
    .onKeyPress(.downArrow) {
      moveSelection(1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveSelection(-1)
      return .handled
    }
  }

  private func resultRow(_ item: PaletteItem, index: Int) -> some View {
    Button {
      execute(item)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: item.icon)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title).font(.system(size: 13)).lineLimit(1)
          if let detail = item.detail, !detail.isEmpty {
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if let shortcut = item.shortcut {
          Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        index == selectionIndex ? Color.primary.opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .onHover { if $0 { selectionIndex = index } }
    .accessibilityAddTraits(index == selectionIndex ? [.isSelected] : [])
  }

  private func command(
    _ id: String, _ title: String, _ icon: String, _ shortcut: String?,
    _ notification: Notification.Name
  ) -> PaletteItem {
    PaletteItem(id: id, title: title, icon: icon, section: "Actions", shortcut: shortcut) {
      NotificationCenter.default.post(name: notification, object: nil)
    }
  }

  private func moveSelection(_ offset: Int) {
    selectionIndex = min(max(0, selectionIndex + offset), max(items.count - 1, 0))
  }

  private func executeSelected() {
    let available = items
    guard available.indices.contains(selectionIndex) else { return }
    execute(available[selectionIndex])
  }

  private func execute(_ item: PaletteItem) {
    hide()
    item.handler()
  }
  private func hide() {
    NotificationCenter.default.post(name: .hideCommandPaletteRequested, object: nil)
    if let tab = tabManager?.activeTab, tab.url != nil, let webView = tab.webView {
      webView.window?.makeFirstResponder(webView)
    } else {
      NotificationCenter.default.post(name: .focusAddressBarRequested, object: nil)
    }
  }
}

private struct PaletteItem: Identifiable {
  let id: String
  let title: String
  var detail: String? = nil
  let icon: String
  let section: String
  var shortcut: String? = nil
  let handler: () -> Void
}
