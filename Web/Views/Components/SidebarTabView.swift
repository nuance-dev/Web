import SwiftUI

struct SidebarTabView: View {
  @ObservedObject var tabManager: TabManager
  @State private var hoveredTabID: UUID?
  @State private var dropTargetID: UUID?
  @StateObject private var windowReference = BrowserWindowReference()

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 6) {
        tabStack
          .frame(height: min(CGFloat(tabManager.tabs.count) * 36 + 36,
                             max(36, geometry.size.height - 104)))
          .glassEffect(.regular, in: .rect(cornerRadius: 12))
        Spacer(minLength: 0).background(WindowDragArea())
        VStack(spacing: 0) {
          railButton("Commands (⌘K)", icon: "command") {
            KeyboardShortcutHandler.shared.present(.commands, in: windowReference.window)
          }
          railButton(
            "Glance (\(PeekController.shared.shortcut.label))",
            icon: "rectangle.bottomthird.inset.filled"
          ) {
            NotificationCenter.default.post(name: .togglePeekRequested, object: nil)
          }
          railButton("Settings (⌘,)", icon: "gearshape") {
            KeyboardShortcutHandler.shared.togglePanel(.settings, in: windowReference.window)
          }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
      }
    }
    .frame(width: 44)
    .background(BrowserWindowReader(reference: windowReference))
  }

  private var tabStack: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 2) {
          ForEach(tabManager.tabs) { tab in
            SidebarTabItem(
              tab: tab,
              isActive: tab.id == tabManager.activeTab?.id,
              isHovered: hoveredTabID == tab.id || dropTargetID == tab.id,
              isDragging: false,
              tabManager: tabManager
            ) { tabManager.setActiveTab(tab) }
            .id(tab.id)
            .onHover { hoveredTabID = $0 ? tab.id : nil }
            .contextMenu { TabContextMenu(tab: tab, tabManager: tabManager) }
            .draggable(tab) { SidebarTabPreview(tab: tab) }
            .dropDestination(for: Tab.self) { tabs, _ in
              move(tabs.first, to: tab)
            } isTargeted: {
              dropTargetID = $0 ? tab.id : nil
            }
          }
          railButton("New tab", icon: "plus") { _ = tabManager.createNewTab() }
            .dropDestination(for: Tab.self) { tabs, _ in
              guard let tab = tabs.first,
                let from = tabManager.tabs.firstIndex(where: { $0.id == tab.id })
              else { return false }
              return tabManager.moveTabSafely(fromIndex: from, toIndex: tabManager.tabs.count)
            }
        }
        .padding(4)
      }
      .onAppear { revealActiveTab(using: proxy) }
      .onChange(of: tabManager.activeTab?.id) { _, _ in
        revealActiveTab(using: proxy)
      }
    }
  }

  private func revealActiveTab(using proxy: ScrollViewProxy) {
    guard let id = tabManager.activeTab?.id else { return }
    DispatchQueue.main.async { proxy.scrollTo(id) }
  }

  private func railButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(BrowserControlStyle())
    .help(title)
    .accessibilityLabel(title)
  }

  private func move(_ dropped: Tab?, to target: Tab) -> Bool {
    guard let dropped,
      let from = tabManager.tabs.firstIndex(where: { $0.id == dropped.id }),
      let to = tabManager.tabs.firstIndex(where: { $0.id == target.id }), from != to
    else { return false }
    return tabManager.moveTabSafely(fromIndex: from, toIndex: to > from ? to + 1 : to)
  }
}

struct SidebarTabItem: View {
  @ObservedObject var tab: Tab
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  let tabManager: TabManager
  let onTap: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onTap) {
        ZStack(alignment: .bottomTrailing) {
          Group {
            if tab.isLoading {
              ProgressView().controlSize(.mini).frame(width: 16, height: 16)
            } else {
              FaviconView(tab: tab, size: 16)
            }
          }
          .frame(width: 36, height: 34)
          if tab.isIncognito || tab.isPinned {
            Image(systemName: tab.isIncognito ? "eye.slash.fill" : "pin.fill")
              .font(.system(size: 8))
              .foregroundStyle(.secondary)
              .padding(2)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(BrowserControlStyle())
      .help("\(tab.title.isEmpty ? "New tab" : tab.title)\(tab.url?.host.map { "\n\($0)" } ?? "")")
      .accessibilityLabel(tab.title.isEmpty ? "New tab" : tab.title)
      .accessibilityValue(tab.isIncognito ? "Private" : "")
      .accessibilityAddTraits(isActive ? [.isSelected] : [])
      .accessibilityAction(named: "Close tab") { tabManager.closeTab(tab) }

      if isHovered {
        Button { tabManager.closeTab(tab) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 12)
            // Keep the row's original center available for selecting the tab.
            .frame(width: 20, height: 16, alignment: .topTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserControlStyle())
        .help("Close tab")
        .accessibilityLabel("Close \(tab.title.isEmpty ? "tab" : tab.title)")
      }
    }
    .frame(width: 36, height: 34)
    .background(
      Color.primary.opacity(isActive ? 0.09 : isHovered ? 0.045 : 0),
      in: RoundedRectangle(cornerRadius: 7)
    )
  }
}

struct SidebarTabPreview: View {
  let tab: Tab
  var isDragging = false

  var body: some View {
    HStack(spacing: 6) {
      FaviconView(tab: tab, size: 20)
      Text(tab.title.isEmpty ? "New tab" : tab.title)
        .font(.system(size: 12)).lineLimit(1)
    }
    .padding(8)
    .frame(maxWidth: 220)
    .glassEffect(.regular, in: .rect(cornerRadius: 10))
  }
}
