import AppKit
import Foundation

/// Only the information needed to reopen a tab. No page contents, forms, or snapshots.
struct SessionTabSnapshot: Codable, Equatable {
    let url: String?
    let title: String
    let isPinned: Bool
    let zoomScale: Double

    init?(url: URL?, title: String, isPinned: Bool, zoomScale: Double, isPrivate: Bool) {
        guard !isPrivate else { return nil }
        if let url, !Self.isRestorableURL(url) { return nil }
        self.url = url?.absoluteString
        self.title = String(title.prefix(300))
        self.isPinned = isPinned
        self.zoomScale = zoomScale.isFinite ? min(3, max(0.5, zoomScale)) : 1
    }

    static func isRestorableURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              url.absoluteString.utf8.count <= 8_192 else { return false }
        // OAuth callback and one-time sign-in links should never replay on launch.
        let sensitiveNames: Set<String> = ["access_token", "id_token", "refresh_token", "token", "code", "password", "secret", "session", "sessionid", "api_key", "apikey"]
        if parts.queryItems?.contains(where: { sensitiveNames.contains($0.name.lowercased()) }) == true { return false }
        if let fragment = parts.fragment?.lowercased(),
           sensitiveNames.contains(where: { fragment.contains($0 + "=") }) { return false }
        return true
    }
}

struct WindowSessionSnapshot: Codable, Equatable {
    var tabs: [SessionTabSnapshot]
    var activeIndex: Int

    /// Validate again after decoding: session files are untrusted disk input.
    var validated: WindowSessionSnapshot {
        var restoredActiveIndex = 0
        var validCount = 0
        let safe = tabs.prefix(50).enumerated().compactMap { offset, item -> SessionTabSnapshot? in
            let url: URL?
            if let string = item.url {
                guard let parsed = URL(string: string), SessionTabSnapshot.isRestorableURL(parsed) else { return nil }
                url = parsed
            } else { url = nil }
            if offset == activeIndex { restoredActiveIndex = validCount }
            validCount += 1
            return SessionTabSnapshot(url: url, title: item.title, isPinned: item.isPinned,
                                      zoomScale: item.zoomScale, isPrivate: false)
        }
        return WindowSessionSnapshot(tabs: safe, activeIndex: restoredActiveIndex)
    }
}

/// Serial ownership prevents one window from overwriting another's session.
/// Existing windows are claimed once per launch; new windows receive new IDs.
final class SessionStore: @unchecked Sendable {
    static let shared = SessionStore()
    static let preferenceKey = "restorePreviousSession"

    struct Registration {
        let id: UUID
        let restored: WindowSessionSnapshot?
    }
    private struct Archive: Codable {
        let version: Int
        var windows: [String: WindowSessionSnapshot]
        var order: [String]
    }

    private let queue = DispatchQueue(label: "web.sessions", qos: .utility)
    private let defaults: UserDefaults
    private let fileURL: URL
    private var archive = Archive(version: 1, windows: [:], order: [])
    private var unclaimed: [String] = []
    private var registered: Set<UUID> = []
    private var pendingWrite: DispatchWorkItem?
    private var enabled: Bool
    private var terminating = false
    private var observers: [NSObjectProtocol] = []

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard, observeLifecycle: Bool = true) {
        self.defaults = defaults
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Web/Session/windows-v1.json")
        self.enabled = defaults.bool(forKey: Self.preferenceKey)
        if enabled,
           let size = try? self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size < 2_000_000,
           let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode(Archive.self, from: data), stored.version == 1 {
            var seen = Set<UUID>()
            for key in stored.order {
                guard archive.order.count < 20,
                      let id = UUID(uuidString: key), let snapshot = stored.windows[key],
                      seen.insert(id).inserted else { continue }
                archive.order.append(id.uuidString)
                archive.windows[id.uuidString] = snapshot.validated
            }
            unclaimed = archive.order
        } else if !enabled {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
        if observeLifecycle {
            observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                    object: defaults, queue: .main) { [weak self] _ in
                self?.refreshPreference()
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                self?.prepareForTermination()
            })
        }
    }

    func registerWindow() -> Registration {
        queue.sync {
            let restoredID = enabled && !unclaimed.isEmpty ? unclaimed.removeFirst() : nil
            let id = restoredID.flatMap(UUID.init(uuidString:)) ?? UUID()
            registered.insert(id)
            let snapshot = restoredID.flatMap { archive.windows[$0] }
            return Registration(id: id, restored: snapshot)
        }
    }

    func update(_ snapshot: WindowSessionSnapshot, for id: UUID) {
        queue.async {
            guard self.enabled, self.registered.contains(id) else { return }
            let key = id.uuidString
            self.archive.windows[key] = snapshot.validated
            if !self.archive.order.contains(key) { self.archive.order.append(key) }
            self.scheduleWrite()
        }
    }

    func closeWindow(_ id: UUID) {
        queue.async {
            self.registered.remove(id)
            guard !self.terminating else { return }
            self.archive.windows.removeValue(forKey: id.uuidString)
            self.archive.order.removeAll { $0 == id.uuidString }
            if self.enabled { self.scheduleWrite() }
        }
    }

    /// Turning restoration off removes its archive, including unclaimed windows.
    func refreshPreference() {
        let shouldEnable = defaults.bool(forKey: Self.preferenceKey)
        queue.sync {
            guard self.enabled != shouldEnable else { return }
            self.enabled = shouldEnable
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
            self.archive = Archive(version: 1, windows: [:], order: [])
            self.unclaimed = []
            if !shouldEnable { try? FileManager.default.removeItem(at: self.fileURL) }
        }
    }

    func flush() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeArchive()
        }
    }

    func prepareForTermination() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeArchive()
            terminating = true
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let write = DispatchWorkItem { [weak self] in self?.writeArchive() }
        pendingWrite = write
        queue.asyncAfter(deadline: .now() + 0.5, execute: write)
    }

    private func writeArchive() {
        guard enabled else { return }
        do {
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            let data = try JSONEncoder().encode(archive)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AppLog.warn("Session could not be saved.")
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
