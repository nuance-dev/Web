import SwiftUI

struct PanelManager: View {
  var tabManager: TabManager? = nil
  @ObservedObject private var keyboardHandler = KeyboardShortcutHandler.shared
  @StateObject private var windowReference = BrowserWindowReference()

  private var presentedPanels: Set<BrowserPanel> { keyboardHandler.panels(in: windowReference.window) }
  private var hasPanel: Bool { !presentedPanels.isEmpty }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if hasPanel {
          Color.black.opacity(0.06)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissTopPanel)
          if presentedPanels.contains(.commands) {
            CommandPalette(tabManager: tabManager)
              .padding(12)
          } else {
            panelContent
              .frame(
                width: min(760, max(300, geometry.size.width - 20)),
                height: min(680, max(280, geometry.size.height - 20))
              )
              .glassEffect(.regular, in: .rect(cornerRadius: 12))
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .onExitCommand(perform: dismissTopPanel)
    }
    .background(BrowserWindowReader(reference: windowReference))
    .allowsHitTesting(hasPanel)
  }

  @ViewBuilder private var panelContent: some View {
    if presentedPanels.contains(.about) {
      AboutView()
    } else if presentedPanels.contains(.settings) {
      SettingsView()
    } else if presentedPanels.contains(.history) {
      HistoryView(tabManager: tabManager)
    } else if presentedPanels.contains(.downloads) {
      DownloadsView()
    } else if presentedPanels.contains(.bookmarks) {
      BookmarkView(tabManager: tabManager)
    }
  }

  private func dismissTopPanel() {
    guard windowReference.acceptsCommands else { return }
    keyboardHandler.dismissTopPanel(in: windowReference.window)
  }
}

struct DownloadsView: View {
  @ObservedObject private var manager = DownloadManager.shared

  private var currentDownloads: [Download] {
    manager.downloads.filter { download in
      download.status != .completed
        || !manager.downloadHistory.contains { $0.filePath == download.destinationURL.path }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Downloads").font(.system(size: 14, weight: .semibold))
        if manager.totalActiveDownloads > 0 {
          Text("\(manager.totalActiveDownloads) active").font(.system(size: 11)).foregroundStyle(
            .secondary)
        }
        Spacer()
        Button {
          KeyboardShortcutHandler.shared.showDownloadsPanel = false
        } label: {
          Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 24)
        }
        .buttonStyle(BrowserControlStyle())
        .accessibilityLabel("Close downloads")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider().opacity(0.5)
      if currentDownloads.isEmpty && manager.downloadHistory.isEmpty {
        Label("No downloads", systemImage: "arrow.down.circle")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if !currentDownloads.isEmpty {
              sectionLabel("Current")
              ForEach(currentDownloads) { download in
                BrowserDownloadRow(download: download)
              }
            }
            if !manager.downloadHistory.isEmpty {
              sectionLabel("Recent")
              ForEach(manager.downloadHistory.prefix(30)) { item in
                historyRow(item)
              }
            }
          }
          .padding(6)
        }
        .scrollIndicators(.hidden)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.top, 6)
      .padding(.bottom, 3)
  }

  private func historyRow(_ item: DownloadHistoryItem) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.filename).font(.system(size: 12)).lineLimit(1)
        HStack(spacing: 6) {
          Text(item.formattedFileSize)
          Text(item.downloadDate, style: .relative)
          if !item.fileExists { Text("Moved or removed") }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Button {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)])
      } label: {
        Image(systemName: "folder").font(.system(size: 12)).frame(width: 26, height: 26)
      }
      .buttonStyle(BrowserControlStyle())
      .disabled(!item.fileExists)
      .help("Show in Finder")
      .accessibilityLabel("Show \(item.filename) in Finder")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
  }
}

private struct BrowserDownloadRow: View {
  @ObservedObject var download: Download
  private let manager = DownloadManager.shared

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(download.filename).font(.system(size: 12)).lineLimit(1)
        HStack(spacing: 6) {
          if download.status == .downloading {
            if download.totalBytes > 0 {
              let progress = SafeNumericConversions.safeProgress(download.progress)
              ProgressView(value: progress).frame(maxWidth: 100)
              Text("\(Int(progress * 100))%")
            } else {
              Text("Downloading")
            }
          } else {
            Text(statusText)
            Text(download.formattedFileSize)
          }
        }
        .font(.system(size: 10))
        .foregroundStyle(download.status == .failed ? Color.red : .secondary)
      }
      Spacer(minLength: 4)
      if download.status == .completed {
        action("Open file", icon: "arrow.up.right") { manager.openDownloadedFile(download) }
        action("Show in Finder", icon: "folder") { manager.showInFinder(download) }
      } else if download.status == .downloading || download.status == .paused {
        if download.task != nil {
          action(
            download.status == .paused ? "Resume download" : "Pause download",
            icon: download.status == .paused ? "play" : "pause"
          ) {
            if download.status == .paused {
              manager.resumeDownload(download)
            } else {
              manager.pauseDownload(download)
            }
          }
        }
        action("Cancel download", icon: "xmark") { manager.cancelDownload(download) }
      } else {
        action("Remove from list", icon: "xmark") { manager.removeDownload(download) }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
  }

  private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      Image(systemName: icon).font(.system(size: 12)).frame(width: 26, height: 26)
    }
    .buttonStyle(BrowserControlStyle())
    .help(title)
    .accessibilityLabel(title)
  }

  private var statusText: String {
    switch download.status {
    case .downloading: return "Downloading"
    case .paused: return "Paused"
    case .completed: return "Completed"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }
}
