import SwiftUI

struct SidebarTabView: View {
  @ObservedObject var tabManager: TabManager
  @State private var hoveredTabID: UUID?
  @State private var dropTargetID: UUID?
  @StateObject private var windowReference = BrowserWindowReference()

  var body: some View {
    VStack(spacing: 2) {
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
        .padding(.top, 4)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
      }
      Spacer(minLength: 0).background(WindowDragArea())
      VStack(spacing: 1) {
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
      .padding(.horizontal, 4)
      .padding(.bottom, 4)
    }
    .frame(width: 48)
    .background(BrowserWindowReader(reference: windowReference))
  }

  private func railButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 40, height: 30)
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
    Button(action: onTap) {
      ZStack(alignment: .bottomTrailing) {
        Group {
          if tab.isLoading {
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
          } else {
            FaviconView(tab: tab, size: 16)
          }
        }
        .frame(width: 40, height: 36)
        if tab.isIncognito || tab.isPinned {
          Image(systemName: tab.isIncognito ? "eye.slash.fill" : "pin.fill")
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .padding(2)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .background(
        Color.primary.opacity(isActive ? 0.09 : isHovered ? 0.045 : 0),
        in: RoundedRectangle(cornerRadius: 7)
      )
    }
    .buttonStyle(BrowserControlStyle())
    .help("\(tab.title.isEmpty ? "New tab" : tab.title)\(tab.url?.host.map { "\n\($0)" } ?? "")")
    .accessibilityLabel(tab.title.isEmpty ? "New tab" : tab.title)
    .accessibilityValue(tab.isIncognito ? "Private" : "")
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .accessibilityAction(named: "Close tab") { tabManager.closeTab(tab) }
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
