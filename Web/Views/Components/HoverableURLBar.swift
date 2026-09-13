import AppKit
import Combine
import SwiftUI

/// An address field for focus mode. Keyboard access is immediate; pointer access stays at the top edge.
struct HoverableURLBar: View {
  let tabID: UUID
  let themeColor: NSColor?
  let onSubmit: (String) -> Void
  @ObservedObject var tabManager: TabManager
  var showsWindowControls = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = false
  @State private var hovering = false
  @State private var localURL = ""
  @State private var localTitle = ""
  @State private var editingText = ""
  @State private var suggestions: [BrowserAddressSuggestion] = []
  @State private var selectedSuggestion = -1
  @State private var hideTask: Task<Void, Never>?
  @StateObject private var windowReference = BrowserWindowReference()
  @FocusState private var focused: Bool
  @ObservedObject private var synchronizer = URLSynchronizer.shared

  var body: some View {
    VStack(spacing: 3) {
      // A small edge target avoids covering the website with a transparent hover layer.
      Color.clear.frame(height: 4).contentShape(Rectangle())
        .onHover { if $0 { reveal(animated: true) } }
      if visible {
        VStack(spacing: 0) {
          HStack(spacing: 5) {
            if showsWindowControls { CompactWindowControls() }
            if let tab = tabManager.activeTab { NavigationControls(tab: tab) }
            Divider().frame(height: 16)
            SecurityIndicator(urlString: localURL, mixedContentStatus: nil)
            TextField(
              "Search or enter a link",
              text: Binding(
                get: { focused ? editingText : localURL },
                set: {
                  editingText = $0
                  updateSuggestions()
                }
              )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .accessibilityLabel("Address and search")
            .onSubmit(submit)
            .onKeyPress(.downArrow) {
              guard !suggestions.isEmpty else { return .ignored }
              selectedSuggestion = min(selectedSuggestion + 1, suggestions.count - 1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              guard !suggestions.isEmpty else { return .ignored }
              selectedSuggestion = max(-1, selectedSuggestion - 1)
              return .handled
            }
            .onExitCommand { dismiss() }
            .onChange(of: focused) { _, value in
              if value {
                hideTask?.cancel()
                editingText = localURL
                DispatchQueue.main.async {
                  NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
              } else {
                suggestions = []
                scheduleHide()
              }
            }
            if focused && !editingText.isEmpty {
              Button {
                editingText = ""
                suggestions = []
              } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(
                  width: 22, height: 26)
              }
              .buttonStyle(BrowserControlStyle())
              .accessibilityLabel("Clear address")
            }
            BookmarkButton(urlString: localURL, pageTitle: localTitle)
            AIToggleButton()
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          if focused && !suggestions.isEmpty {
            Divider().opacity(0.6)
            VStack(spacing: 2) {
              ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                Button {
                  navigate(item.url)
                } label: {
                  HStack(spacing: 7) {
                    Image(systemName: item.icon).foregroundStyle(.secondary).frame(width: 18)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.url.host ?? "").foregroundStyle(.secondary).lineLimit(1)
                  }
                  .font(.system(size: 12))
                  .padding(.horizontal, 7)
                  .padding(.vertical, 6)
                  .background(
                    index == selectedSuggestion ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                  )
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
            .padding(3)
          }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 5)
        .onHover { value in
          hovering = value
          if value { hideTask?.cancel() } else { scheduleHide() }
        }
        .transition(.opacity)
      }
    }
    .frame(maxWidth: 780)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(BrowserWindowReader(reference: windowReference))
    .onReceive(
      tabManager.activeTab?.$url.map { $0?.absoluteString ?? "" }.eraseToAnyPublisher()
        ?? Just("").eraseToAnyPublisher()
    ) { localURL = $0 }
    .onReceive(tabManager.activeTab?.$title.eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher())
    { localTitle = $0 }
    .onReceive(NotificationCenter.default.publisher(for: .focusURLBarRequested)) { _ in
      if windowReference.acceptsCommands { focus() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusAddressBarRequested)) { _ in
      if windowReference.acceptsCommands { focus() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .dismissHoverableURLBar)) { _ in
      guard visible else { return }
      dismiss()
      NotificationCenter.default.post(name: .hoverableURLBarDismissed, object: nil)
    }
    .onChange(of: tabID) { _, _ in dismiss() }
    .onDisappear { hideTask?.cancel() }
  }

  private func updateSuggestions() {
    selectedSuggestion = -1
    suggestions =
      focused && tabManager.activeTab?.isIncognito != true
      ? BrowserAddressSuggestion.matches(editingText) : []
  }

  private func reveal(animated: Bool) {
    hideTask?.cancel()
    withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.16) : nil) { visible = true }
  }

  private func focus() {
    reveal(animated: false)
    focused = true
    DispatchQueue.main.async {
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }

  private func scheduleHide() {
    hideTask?.cancel()
    guard !focused && !hovering else { return }
    hideTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled, !focused, !hovering else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { visible = false }
    }
  }

  private func dismiss() {
    hideTask?.cancel()
    focused = false
    visible = false
    suggestions = []
  }

  private func submit() {
    if suggestions.indices.contains(selectedSuggestion) {
      navigate(suggestions[selectedSuggestion].url)
    } else if let url = NavigationResolver.resolve(editingText) {
      navigate(url)
    }
  }

  private func navigate(_ url: URL) {
    synchronizer.updateFromUserInput(urlString: url.absoluteString, tabID: tabID)
    onSubmit(url.absoluteString)
    dismiss()
  }
}
