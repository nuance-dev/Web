import AppKit
import Combine
import SwiftUI

struct URLBar: View {
  let tabID: UUID
  let themeColor: NSColor?
  let mixedContentStatus: MixedContentManager.MixedContentStatus?
  var isIncognito = false
  var tab: Tab? = nil
  let onSubmit: (String) -> Void
  @StateObject private var windowReference = BrowserWindowReference()
  @FocusState private var focused: Bool
  @State private var localURL = ""
  @State private var localTitle = ""
  @State private var editingText = ""
  @State private var suggestions: [BrowserAddressSuggestion] = []
  @State private var selectedSuggestion = -1
  @ObservedObject private var synchronizer = URLSynchronizer.shared

  private var currentURL: String { tab == nil ? synchronizer.currentURL : localURL }
  private var currentTitle: String { tab == nil ? synchronizer.pageTitle : localTitle }
  private var displayedAddress: String {
    currentURL.hasPrefix("https://") ? String(currentURL.dropFirst(8)) : currentURL
  }

  var body: some View {
    HStack(spacing: 2) {
      SecurityIndicator(urlString: currentURL, mixedContentStatus: mixedContentStatus)
      TextField(
        "Search or enter a link",
        text: Binding(
          get: { focused ? editingText : displayedAddress },
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
      .onExitCommand {
        focused = false
        suggestions = []
      }
      .onChange(of: focused) { _, value in
        if value {
          editingText = currentURL
          DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
          }
        } else {
          suggestions = []
          selectedSuggestion = -1
        }
      }
      BookmarkButton(urlString: currentURL, pageTitle: currentTitle)
      DownloadsButton()
      AIToggleButton()
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 2)
    .glassEffect(focused ? .regular.interactive() : .identity, in: .rect(cornerRadius: 8))
    .background(BrowserWindowReader(reference: windowReference))
    .onReceive(
      tab?.$url.map { $0?.absoluteString ?? "" }.eraseToAnyPublisher()
        ?? Just("").eraseToAnyPublisher()
    ) { localURL = $0 }
    .onReceive(tab?.$title.eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher()) {
      localTitle = $0
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusURLBarRequested)) { _ in
      if windowReference.acceptsCommands { focusAddress() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusAddressBarRequested)) { _ in
      if windowReference.acceptsCommands { focusAddress() }
    }
    .onChange(of: tabID) { _, _ in
      focused = false
      suggestions = []
    }
    .overlay(alignment: .topLeading) {
      if focused && !suggestions.isEmpty {
        VStack(spacing: 2) {
          ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
            Button {
              navigate(suggestion.url)
            } label: {
              HStack(spacing: 7) {
                Image(systemName: suggestion.icon).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                  Text(suggestion.title).font(.system(size: 12)).lineLimit(1)
                  Text(suggestion.url.host ?? suggestion.url.absoluteString)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
              }
              .foregroundStyle(.primary)
              .padding(.horizontal, 7)
              .padding(.vertical, 6)
              .background(
                selectedSuggestion == index ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(3)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .offset(y: 32)
        .zIndex(1000)
      }
    }
  }

  private func focusAddress() {
    focused = true
    DispatchQueue.main.async {
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }

  private func updateSuggestions() {
    selectedSuggestion = -1
    suggestions = focused && !isIncognito ? BrowserAddressSuggestion.matches(editingText) : []
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
    focused = false
    suggestions = []
  }
}

struct BrowserAddressSuggestion: Identifiable {
  var id: String { url.absoluteString }
  let title: String
  let url: URL
  let icon: String

  @MainActor static func matches(_ input: String) -> [BrowserAddressSuggestion] {
    let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count > 1 else { return [] }
    var seen = Set<String>()
    let bookmarks = BookmarkService.shared.searchBookmarks(query: query).compactMap {
      item -> BrowserAddressSuggestion? in
      guard let url = URL(string: item.url), NavigationResolver.isWebURL(url),
        seen.insert(item.url).inserted
      else { return nil }
      return BrowserAddressSuggestion(title: item.title, url: url, icon: "bookmark")
    }
    let history = HistoryService.shared.getAutofillSuggestions(for: query, limit: 5).compactMap {
      item -> BrowserAddressSuggestion? in
      guard let url = URL(string: item.url), NavigationResolver.isWebURL(url),
        seen.insert(item.url).inserted
      else { return nil }
      return BrowserAddressSuggestion(title: item.displayTitle, url: url, icon: "clock")
    }
    return Array((bookmarks + history).prefix(5))
  }
}
// Security indicator component
struct SecurityIndicator: View {
  let urlString: String
  let mixedContentStatus: MixedContentManager.MixedContentStatus?
  @State private var certificateStatus: CertificateStatus = .unknown
  @State private var showingSecurityDetails = false

  enum CertificateStatus {
    case secure
    case insecure
    case warning
    case error
    case mixedContent
    case mixedContentBlocked
    case unknown

    var icon: String {
      switch self {
      case .secure:
        return "lock"
      case .insecure:
        return "lock.open.fill"
      case .warning:
        return "exclamationmark.triangle.fill"
      case .error:
        return "xmark.shield.fill"
      case .mixedContent:
        return "exclamationmark.shield.fill"
      case .mixedContentBlocked:
        return "shield.slash.fill"
      case .unknown:
        return "magnifyingglass"
      }
    }

    var color: Color {
      switch self {
      case .secure:
        return .secondary
      case .insecure:
        return .red.opacity(0.8)
      case .warning:
        return .orange.opacity(0.8)
      case .error:
        return .red
      case .mixedContent:
        return .orange.opacity(0.9)
      case .mixedContentBlocked:
        return .blue.opacity(0.8)
      case .unknown:
        return .textSecondary
      }
    }

    var tooltip: String {
      switch self {
      case .secure:
        return "HTTPS connection"
      case .insecure:
        return "Connection is not secure"
      case .warning:
        return "Certificate has issues"
      case .error:
        return "Certificate validation failed"
      case .mixedContent:
        return "Mixed content detected - some resources loaded over HTTP"
      case .mixedContentBlocked:
        return "Mixed content blocked for security"
      case .unknown:
        return "Search or enter website"
      }
    }

    var hasSecurityIssue: Bool {
      switch self {
      case .secure, .unknown:
        return false
      case .insecure, .warning, .error, .mixedContent, .mixedContentBlocked:
        return true
      }
    }
  }

  private var hasURL: Bool {
    !urlString.isEmpty && (urlString.contains(".") || urlString.hasPrefix("http"))
  }

  var body: some View {
    Button(action: { showingSecurityDetails.toggle() }) {
      Image(systemName: certificateStatus.icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(certificateStatus.color)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(BrowserControlStyle())
    .help(certificateStatus.tooltip)
    .accessibilityLabel(certificateStatus.tooltip)
    .onChange(of: urlString) { _, newURL in
      updateCertificateStatus(for: newURL)
    }
    .onChange(of: mixedContentStatus) { _, _ in
      updateCertificateStatus(for: urlString)
    }
    .onAppear {
      updateCertificateStatus(for: urlString)
    }
    .popover(isPresented: $showingSecurityDetails) {
      SecurityDetailsPopover(
        urlString: urlString,
        certificateStatus: certificateStatus,
        mixedContentStatus: mixedContentStatus
      )
    }
  }

  private func updateCertificateStatus(for url: String) {
    guard hasURL else {
      certificateStatus = .unknown
      return
    }

    // SECURITY: Check mixed content status first for HTTPS pages
    if url.hasPrefix("https://"), let mixedStatus = mixedContentStatus {
      if mixedStatus.mixedContentDetected {
        // Determine if mixed content is being blocked or allowed
        let policy = MixedContentManager.shared.mixedContentPolicy
        switch policy {
        case .block:
          certificateStatus = .mixedContentBlocked
        case .warn, .allow:
          certificateStatus = .mixedContent
        }
        return
      }
    }

    // Basic URL scheme checking
    if url.hasPrefix("https://") {
      // For HTTPS URLs, we start with secure but will update based on actual validation
      certificateStatus = .secure

      // Check if there are any certificate exceptions for this host
      if let urlObj = URL(string: url), let host = urlObj.host {
        let port = urlObj.port ?? 443

        if CertificateManager.shared.hasException(for: host, port: port) {
          certificateStatus = .warning
        }

        // Mixed content status takes precedence over certificate issues
        // for better user understanding of the security context
      }
    } else if url.hasPrefix("http://") {
      certificateStatus = .insecure
    } else {
      certificateStatus = .unknown
    }
  }
}

// MARK: - Security Details Popover

struct SecurityDetailsPopover: View {
  let urlString: String
  let certificateStatus: SecurityIndicator.CertificateStatus
  let mixedContentStatus: MixedContentManager.MixedContentStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack {
        Image(systemName: certificateStatus.icon)
          .foregroundColor(certificateStatus.color)
          .font(.title2)

        VStack(alignment: .leading, spacing: 2) {
          Text("Connection Security")
            .font(.headline)
          Text(certificateStatus.tooltip)
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()
      }

      Divider()

      // URL Information
      VStack(alignment: .leading, spacing: 8) {
        Label("Website", systemImage: "globe")
          .font(.subheadline)
          .fontWeight(.medium)

        if let url = URL(string: urlString), let host = url.host {
          VStack(alignment: .leading, spacing: 4) {
            Text(host)
              .font(.system(.body, design: .monospaced))
              .foregroundColor(.primary)

            if url.port != nil && url.port != 80 && url.port != 443 {
              Text("Port: \(url.port!)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        } else {
          Text(urlString)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.primary)
        }
      }

      // Security Status Details
      VStack(alignment: .leading, spacing: 8) {
        Label("Security Status", systemImage: "shield")
          .font(.subheadline)
          .fontWeight(.medium)

        Text(securityStatusDescription)
          .font(.callout)
          .foregroundColor(.secondary)
      }

      // Certificate Exception Info (if applicable)
      if let url = URL(string: urlString),
        let host = url.host,
        CertificateManager.shared.hasException(for: host, port: url.port ?? 443)
      {

        VStack(alignment: .leading, spacing: 8) {
          Label("Certificate Exception", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.orange)

          Text(
            "You have granted a security exception for this website. This may pose security risks."
          )
          .font(.callout)
          .foregroundColor(.secondary)

          Button("Revoke Exception") {
            CertificateManager.shared.revokeException(for: host, port: url.port ?? 443)
          }
          .buttonStyle(.bordered)
          .foregroundColor(.red)
        }
      }

      // Mixed Content Information (if applicable)
      if let mixedStatus = mixedContentStatus,
        mixedStatus.mixedContentDetected
      {

        VStack(alignment: .leading, spacing: 8) {
          Label("Mixed Content Detected", systemImage: "exclamationmark.shield")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.orange)

          Text(
            "This HTTPS page contains HTTP resources, which compromises the security of the connection."
          )
          .font(.callout)
          .foregroundColor(.secondary)

          // Show current policy
          let policy = MixedContentManager.shared.mixedContentPolicy
          HStack {
            Text("Policy:")
              .font(.caption)
              .fontWeight(.medium)
            Text(policy.rawValue)
              .font(.caption)
              .foregroundColor(policy.securityLevel.color)
          }

          // Show violation count if available
          if mixedStatus.violationCount > 0 {
            Text(
              "\(mixedStatus.violationCount) mixed content \(mixedStatus.violationCount == 1 ? "resource" : "resources") detected"
            )
            .font(.caption2)
            .foregroundColor(.secondary)
          }

          Button("Mixed Content Settings...") {
            NotificationCenter.default.post(name: .showSettingsRequested, object: "mixedContent")
          }
          .buttonStyle(.bordered)
          .foregroundColor(.blue)
        }
      }

      // Security Settings Link
      Divider()

      Button("Security Settings...") {
        NotificationCenter.default.post(name: .showSettingsRequested, object: "security")
      }
      .buttonStyle(.borderless)
      .foregroundColor(.accentColor)
    }
    .padding(16)
    .frame(width: 300)
  }

  private var securityStatusDescription: String {
    switch certificateStatus {
    case .secure:
      return
        "This page uses HTTPS. Connection security does not guarantee that a website is trustworthy."
    case .insecure:
      return
        "Your connection to this site is not encrypted. Information you send can be intercepted."
    case .warning:
      return "This site's certificate has issues, but you've chosen to trust it."
    case .error:
      return "This site's certificate could not be validated. Avoid entering sensitive information."
    case .unknown:
      return "No security information available."
    case .mixedContent:
      return "This HTTPS site contains HTTP resources, which may compromise your security."
    case .mixedContentBlocked:
      return "HTTP resources on this HTTPS page have been blocked for your security."
    }
  }
}

// Bookmark button component
struct BookmarkButton: View {
  var urlString: String? = nil
  var pageTitle: String? = nil
  @ObservedObject private var synchronizer = URLSynchronizer.shared
  @ObservedObject private var bookmarks = BookmarkService.shared

  private var currentURL: String { urlString ?? synchronizer.currentURL }
  private var currentTitle: String { pageTitle ?? synchronizer.pageTitle }

  private var isBookmarked: Bool { bookmarks.isBookmarked(url: currentURL) }
  private var hasURL: Bool { URL(string: currentURL).map(NavigationResolver.isWebURL) ?? false }

  var body: some View {
    Button {
      KeyboardShortcutHandler.shared.toggleBookmark(url: currentURL, title: currentTitle)
    } label: {
      Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
        .font(.system(size: 12))
        .foregroundStyle(isBookmarked ? Color.accentColor : .secondary)
        .frame(width: 24, height: 24)
    }
    .buttonStyle(BrowserControlStyle())
    .disabled(!hasURL)
    .help(isBookmarked ? "Remove bookmark" : "Bookmark page (⌘D)")
    .accessibilityLabel(isBookmarked ? "Remove bookmark" : "Bookmark page")
  }
}

struct HistoryButton: View {
  var body: some View {
    Button {
      KeyboardShortcutHandler.shared.showHistoryPanel.toggle()
    } label: {
      Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary).frame(
        width: 24, height: 24)
    }
    .buttonStyle(BrowserControlStyle())
    .help("History (⌘Y)")
    .accessibilityLabel("History")
  }
}

struct DownloadsButton: View {
  @ObservedObject private var downloads = DownloadManager.shared
  var body: some View {
    Button {
      KeyboardShortcutHandler.shared.showDownloadsPanel.toggle()
    } label: {
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24, height: 24)
        .overlay(alignment: .topTrailing) {
          if downloads.totalActiveDownloads > 0 {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(3)
          }
        }
    }
    .buttonStyle(BrowserControlStyle())
    .help("Downloads")
    .accessibilityLabel(
      downloads.totalActiveDownloads > 0
        ? "Downloads, \(downloads.totalActiveDownloads) active" : "Downloads")
  }
}

struct AIToggleButton: View {
  @EnvironmentObject private var presentation: AssistantPresentationState
  var body: some View {
    if !presentation.isExpanded {
      Button {
        NotificationCenter.default.post(name: .toggleAISidebar, object: nil)
      } label: {
        Image(systemName: "sidebar.right")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(BrowserControlStyle())
      .help("Open assistant (⇧⌘A)")
      .accessibilityLabel("Open assistant")
    }
  }
}
