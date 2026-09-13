import SwiftUI

struct TopBarTabView: View {
  @ObservedObject var tabManager: TabManager
  @State private var hoveredTabID: UUID?
  @State private var dropTargetID: UUID?

  var body: some View {
    HStack(spacing: 2) {
      CompactWindowControls()
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(tabManager.tabs) { tab in
            TopBarTabItem(
              tab: tab,
              isActive: tab.id == tabManager.activeTab?.id,
              isHovered: hoveredTabID == tab.id || dropTargetID == tab.id,
              isDragging: false,
              onTap: { tabManager.setActiveTab(tab) }, tabManager: tabManager
            )
            .frame(width: 160)
            .onHover { hoveredTabID = $0 ? tab.id : nil }
            .contextMenu { TabContextMenu(tab: tab, tabManager: tabManager) }
            .draggable(tab) { TopBarTabPreview(tab: tab) }
            .dropDestination(for: Tab.self) { tabs, _ in
              guard let dropped = tabs.first,
                let from = tabManager.tabs.firstIndex(where: { $0.id == dropped.id }),
                let to = tabManager.tabs.firstIndex(where: { $0.id == tab.id }), from != to
              else { return false }
              return tabManager.moveTabSafely(fromIndex: from, toIndex: to > from ? to + 1 : to)
            } isTargeted: {
              dropTargetID = $0 ? tab.id : nil
            }

          }
          Button {
            _ = tabManager.createNewTab()
          } label: {
            Image(systemName: "plus").font(.system(size: 13)).frame(width: 26, height: 26)
          }
          .buttonStyle(BrowserControlStyle())
          .help("New tab (⌘T)")
          .accessibilityLabel("New tab")
          .dropDestination(for: Tab.self) { tabs, _ in
            guard let dropped = tabs.first,
              let from = tabManager.tabs.firstIndex(where: { $0.id == dropped.id })
            else { return false }
            return tabManager.moveTabSafely(fromIndex: from, toIndex: tabManager.tabs.count)
          }
        }
        .padding(.trailing, 2)
      }
    }
    .frame(height: 36)
    .background(WindowDragArea())
  }
}

struct TopBarTabItem: View {
  @ObservedObject var tab: Tab
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  let onTap: () -> Void
  let tabManager: TabManager

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onTap) {
        HStack(spacing: 2) {
          if tab.isLoading {
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
          } else {
            FaviconView(tab: tab, size: 16)
          }
          if tab.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
          }
          Text(tab.title.isEmpty ? "New tab" : tab.title)
            .font(.system(size: 12, weight: isActive ? .medium : .regular))
            .lineLimit(1)
          Spacer(minLength: 0)
          if tab.isIncognito {
            Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.leading, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isActive ? [.isSelected] : [])
      Button {
        tabManager.closeTab(tab)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 26)
          .opacity(isActive || isHovered ? 1 : 0.65)
      }
      .buttonStyle(BrowserControlStyle())
      .accessibilityLabel("Close \(tab.title.isEmpty ? "tab" : tab.title)")
      .help("Close tab")
    }
    .background(
      Color.primary.opacity(isHovered && !isActive ? 0.05 : 0),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .glassEffect(isActive ? .regular : .identity, in: .rect(cornerRadius: 7))
    .help(tab.url?.absoluteString ?? "New tab")
  }
}

struct TopBarTabPreview: View {
  let tab: Tab
  var isDragging = false

  var body: some View { SidebarTabPreview(tab: tab, isDragging: isDragging) }
}
