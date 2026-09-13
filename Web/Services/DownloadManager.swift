import Combine
import CryptoKit
import SwiftUI
import WebKit
import os.log

@MainActor
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    private let logger = Logger(subsystem: "com.example.Web", category: "DownloadManager")

    @Published var downloads: [Download] = []
    @Published var isVisible: Bool = false
    @Published var totalActiveDownloads: Int = 0
    @Published var downloadHistory: [DownloadHistoryItem] = []

    // MARK: - Security Services Integration
    @Published var securityScanEnabled: Bool = true {
        didSet { UserDefaults.standard.set(securityScanEnabled, forKey: "DownloadManager.SecurityScanEnabled") }
    }
    @Published var showSecurityWarnings: Bool = true {
        didSet { UserDefaults.standard.set(showSecurityWarnings, forKey: "DownloadManager.ShowSecurityWarnings") }
    }
    @Published var autoQuarantineDownloads: Bool = true {
        didSet { UserDefaults.standard.set(autoQuarantineDownloads, forKey: "DownloadManager.AutoQuarantineDownloads") }
    }

    // WKWebView integration
    private var webViewDownloads: [String: WKDownload] = [:]
    private var webViewContexts: [String: WebKitDownloadContext] = [:]

    private final class WebKitDownloadContext {
        let isPrivate: Bool
        var model: Download?
        var stagedFile: StagedDownloadFile?
        var mimeType: String?
        var observations: [NSKeyValueObservation] = []

        init(isPrivate: Bool) { self.isPrivate = isPrivate }
    }

    // Security services
    private let fileSecurityValidator: FileSecurityValidator
    private let malwareScanner: MalwareScanner
    private let quarantineManager: QuarantineManager
    private let securityMonitor: SecurityMonitor

    // Security UI state
    @Published var pendingSecurityWarning: PendingSecurityWarning?

    struct PendingSecurityWarning {
        let download: Download
        let securityAnalysis: FileSecurityValidator.FileSecurityAnalysis
        let scanResult: MalwareScanner.ScanResult?
        let onProceed: () -> Void
        let onCancel: () -> Void
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let downloadDirectory: URL = {
        guard
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first
        else {
            // Fallback to Documents directory if Downloads is not accessible
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return directory
    }()

    override init() {
        // Initialize security services
        self.fileSecurityValidator = FileSecurityValidator.shared
        self.malwareScanner = MalwareScanner.shared
        self.quarantineManager = QuarantineManager.shared
        self.securityMonitor = SecurityMonitor.shared

        super.init()
        loadExistingDownloads()
        loadDownloadHistory()
        loadSecuritySettings()

        AppLog.debug("DownloadManager init (enhanced security)")
    }

    func startDownload(from url: URL, suggestedFilename: String? = nil, isPrivate: Bool = false) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return }
        // ENHANCED SECURITY: Comprehensive security validation pipeline
        Task { @MainActor in
            let filename = BrowserSecurityPolicy.downloadFilename(suggestedFilename ?? url.lastPathComponent)

            // Log download initiation
            logDownloadSecurityEvent(
                isPrivate: isPrivate,
                filename: filename,
                sourceURL: url,
                eventType: .downloadInitiated,
                severity: .info,
                details: ["userInitiated": true]
            )

            // Step 1: Safe Browsing URL validation
            let safetyResult = await SafeBrowsingManager.shared.checkURLSafety(url, allowRemoteLookup: !isPrivate)

            switch safetyResult {
            case .safe:
                // URL is safe - proceed with comprehensive security validation
                await self.performSecurityValidationAndDownload(
                    from: url, suggestedFilename: suggestedFilename, isPrivate: isPrivate)

            case .unsafe(let threat):
                // URL is malicious - block download and log security event
                self.logger.warning(
                    "Safe Browsing blocked a download (Threat: \(threat.threatType.userFriendlyName))"
                )

                logDownloadSecurityEvent(
                    isPrivate: isPrivate,
                    filename: filename,
                    sourceURL: url,
                    eventType: .threatBlocked,
                    severity: .critical,
                    details: [
                        "threatType": threat.threatType.userFriendlyName,
                        "blockReason": "Safe Browsing detection",
                    ]
                )

                // Post notification to show download threat warning
                NotificationCenter.default.post(
                    name: .safeBrowsingThreatDetected,
                    object: nil,
                    userInfo: [
                        "url": url,
                        "threat": threat,
                        "isDownload": true,
                    ]
                )

            case .unknown:
                // Unable to determine safety - proceed with caution and enhanced security
                self.logger.warning(
                    "Download reputation could not be checked"
                )

                logDownloadSecurityEvent(
                    isPrivate: isPrivate,
                    filename: filename,
                    sourceURL: url,
                    eventType: .suspiciousActivity,
                    severity: .warning,
                    details: ["reason": "Safe Browsing check failed"]
                )

                await self.performSecurityValidationAndDownload(
                    from: url, suggestedFilename: suggestedFilename, isPrivate: isPrivate)
            }
        }
    }

    @MainActor
    private func performSecurityValidationAndDownload(from url: URL, suggestedFilename: String?, isPrivate: Bool = false)
        async
    {
        let filename = BrowserSecurityPolicy.downloadFilename(suggestedFilename ?? url.lastPathComponent)

        // Step 2: File security analysis
        let securityAnalysis = await fileSecurityValidator.analyzeFileSecurity(
            url: url,
            suggestedFilename: filename,
            mimeType: nil,
            expectedFileSize: -1
        )

        logDownloadSecurityEvent(
            isPrivate: isPrivate,
            filename: filename,
            sourceURL: url,
            eventType: .securityScanStarted,
            severity: .info,
            details: [
                "riskLevel": securityAnalysis.riskLevel.displayName,
                "isExecutable": securityAnalysis.isExecutable,
                "isSpoofed": securityAnalysis.isSpoofed,
            ]
        )

        // Step 3: Check if download should be blocked
        if fileSecurityValidator.shouldBlockDownload(securityAnalysis) {
            logger.warning(
                "🚫 Download blocked by security policy: \(filename) (Risk: \(securityAnalysis.riskLevel.displayName))"
            )

            logDownloadSecurityEvent(
                isPrivate: isPrivate,
                filename: filename,
                sourceURL: url,
                eventType: .threatBlocked,
                severity: .error,
                details: [
                    "blockReason": "Security policy violation",
                    "riskReasons": securityAnalysis.riskReasons.joined(separator: ", "),
                ]
            )

            // Show security warning (blocked)
            if showSecurityWarnings {
                showSecurityWarning(securityAnalysis: securityAnalysis, scanResult: nil) {
                    // Blocked - no proceed action
                } onCancel: {
                    // User acknowledged block
                }
            }
            return
        }

        // Step 4: Check if user confirmation is required
        if securityAnalysis.requiresUserConfirmation && showSecurityWarnings {
            // Create download but don't start yet - wait for user confirmation
            let download = createDownload(from: url, suggestedFilename: suggestedFilename, isPrivate: isPrivate)

            // Show security warning with user choice
            showSecurityWarning(securityAnalysis: securityAnalysis, scanResult: nil) {
                // User chose to proceed
                Task { @MainActor in
                    await self.proceedWithSecureDownload(
                        download: download, securityAnalysis: securityAnalysis)
                }
            } onCancel: {
                // User cancelled
                self.cancelDownload(download)
                self.removeDownload(download)
            }
        } else {
            // Low risk or warnings disabled - proceed directly
            let download = createDownload(from: url, suggestedFilename: suggestedFilename, isPrivate: isPrivate)
            await proceedWithSecureDownload(download: download, securityAnalysis: securityAnalysis)
        }
    }

    @MainActor
    private func proceedWithSecureDownload(
        download: Download, securityAnalysis: FileSecurityValidator.FileSecurityAnalysis
    ) async {
        // Add download to list if not already added
        if !downloads.contains(where: { $0.id == download.id }) {
            downloads.append(download)
        }

        // Start URLSession download task
        let task = session.downloadTask(with: download.url)
        download.task = task
        download.securityAnalysis = securityAnalysis
        task.resume()

        updateActiveDownloadsCount()

        AppLog.debug("Started secure download: \(download.filename)")

        logDownloadSecurityEvent(
            isPrivate: download.isPrivate,
            filename: download.filename,
            sourceURL: download.url,
            eventType: .securityScanCompleted,
            severity: .info,
            details: [
                "downloadStarted": true,
                "securityValidationPassed": true,
                "riskLevel": securityAnalysis.riskLevel.displayName,
            ]
        )
    }

    private func logDownloadSecurityEvent(
        isPrivate: Bool, filename: String, sourceURL: URL,
        eventType: SecurityMonitor.SecurityEvent.EventType,
        severity: SecurityMonitor.SecurityEvent.Severity, details: [String: Any] = [:]
    ) {
        guard !isPrivate else { return }
        securityMonitor.logDownloadSecurityEvent(filename: filename, sourceURL: sourceURL,
            eventType: eventType, severity: severity, details: details)
    }

    private func createDownload(from url: URL, suggestedFilename: String?, isPrivate: Bool) -> Download {
        let filename = BrowserSecurityPolicy.downloadFilename(suggestedFilename ?? url.lastPathComponent)
        let destinationURL = downloadDirectory.appendingPathComponent(filename)
        let finalURL = createUniqueFileURL(for: destinationURL)

        return Download(
            url: url,
            destinationURL: finalURL,
            filename: finalURL.lastPathComponent,
            isPrivate: isPrivate
        )
    }

    private func showSecurityWarning(
        securityAnalysis: FileSecurityValidator.FileSecurityAnalysis,
        scanResult: MalwareScanner.ScanResult?,
        onProceed: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        // This will be handled by the UI layer showing DownloadSecurityWarningView
        pendingSecurityWarning = PendingSecurityWarning(
            download: Download(
                url: securityAnalysis.url,
                destinationURL: downloadDirectory.appendingPathComponent(BrowserSecurityPolicy.downloadFilename(securityAnalysis.filename)),
                filename: securityAnalysis.filename
            ),
            securityAnalysis: securityAnalysis,
            scanResult: scanResult,
            onProceed: onProceed,
            onCancel: onCancel
        )
    }

    // Legacy method - now redirects to secure download pipeline
    @MainActor
    private func performDownload(from url: URL, suggestedFilename: String?) {
        // Redirect to new secure download pipeline
        Task {
            await performSecurityValidationAndDownload(
                from: url, suggestedFilename: suggestedFilename)
        }
    }

    func pauseDownload(_ download: Download) {
        guard let task = download.task, download.status == .downloading else { return }
        task.suspend()
        download.status = .paused
    }

    func resumeDownload(_ download: Download) {
        guard let task = download.task, download.status == .paused else { return }
        task.resume()
        download.status = .downloading
    }

    func cancelDownload(_ download: Download) {
        download.task?.cancel()
        if let identifier = download.webKitDownloadId,
           let webDownload = webViewDownloads.removeValue(forKey: identifier) {
            webDownload.delegate = nil
            webDownload.cancel { _ in }
        }
        if let identifier = download.webKitDownloadId {
            webViewContexts.removeValue(forKey: identifier)
        }
        download.status = .cancelled
        updateActiveDownloadsCount()
    }

    func removeDownload(_ download: Download) {
        if download.status == .downloading || download.status == .paused {
            cancelDownload(download)
        }
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
        }
    }

    private func createUniqueFileURL(for url: URL, excluding id: UUID? = nil) -> URL {
        DownloadFileDestination.uniqueURL(for: url, reservedURLs: downloads.filter {
            $0.id != id && ($0.status == .downloading || $0.status == .paused)
        }.map(\.destinationURL))
    }

    private func updateActiveDownloadsCount() {
        totalActiveDownloads =
            downloads.filter {
                $0.status == .downloading
            }.count
    }

    private func loadExistingDownloads() {
        // Load download history from UserDefaults if needed
    }

    private func loadDownloadHistory() {
        // Load download history from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "downloadHistory"),
            let history = try? JSONDecoder().decode([DownloadHistoryItem].self, from: data)
        {
            downloadHistory = history
        }
    }

    private func saveDownloadHistory() {
        if let data = try? JSONEncoder().encode(downloadHistory) {
            UserDefaults.standard.set(data, forKey: "downloadHistory")
        }
    }

    // MARK: - WKWebView Integration

    /// Continue the original WebKit request, preserving its cookies and request body.
    func handleWebViewDownload(_ download: WKDownload, isPrivate: Bool = false) {
        guard download.originalRequest?.url != nil else {
            download.cancel { _ in }
            return
        }
        guard !webViewDownloads.values.contains(where: { $0 === download }) else { return }
        let identifier = UUID().uuidString
        webViewDownloads[identifier] = download
        webViewContexts[identifier] = WebKitDownloadContext(isPrivate: isPrivate)
        download.delegate = self
    }

    private func webDownloadIdentifier(_ download: WKDownload) -> String? {
        webViewDownloads.first(where: { $0.value === download })?.key
    }

    private func finishWebDownload(_ identifier: String) {
        webViewDownloads.removeValue(forKey: identifier)?.delegate = nil
        webViewContexts.removeValue(forKey: identifier)
    }

    /// Open file in default application
    func openDownloadedFile(_ download: Download) {
        guard download.status == .completed else { return }

        if FileManager.default.fileExists(atPath: download.destinationURL.path) {
            NSWorkspace.shared.open(download.destinationURL)
            AppLog.debug("Opened downloaded file: \(download.filename)")
        } else {
            logger.error("Downloaded file not found: \(download.destinationURL.path)")
        }
    }

    /// Show file in Finder
    func showInFinder(_ download: Download) {
        guard download.status == .completed else { return }

        if FileManager.default.fileExists(atPath: download.destinationURL.path) {
            NSWorkspace.shared.selectFile(
                download.destinationURL.path, inFileViewerRootedAtPath: downloadDirectory.path)
            AppLog.debug("Showed file in Finder: \(download.filename)")
        }
    }

    /// Get download progress for UI
    func getOverallProgress() -> Double {
        let activeDownloads = downloads.filter { $0.status == .downloading }
        guard !activeDownloads.isEmpty else { return 0.0 }

        let totalProgress = activeDownloads.reduce(0.0) { $0 + $1.progress }
        return totalProgress / Double(activeDownloads.count)
    }

    /// Clear completed downloads
    func clearCompletedDownloads() {
        downloads.removeAll {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
        updateActiveDownloadsCount()
        AppLog.debug("Cleared completed downloads")
    }

    /// Get download by URL
    func getDownload(for url: URL) -> Download? {
        return downloads.first { $0.url == url }
    }

    // MARK: - Security Management

    /// Get security report for all downloads
    func getSecurityReport() -> DownloadSecurityReport {
        let totalDownloads = downloadHistory.count
        let secureDownloads = downloadHistory.filter { $0.securityValidated }.count
        let riskyDownloads = downloadHistory.filter {
            $0.riskLevel != nil && $0.riskLevel != "Safe"
        }.count
        let quarantinedDownloads = downloads.filter { $0.quarantineInfo?.isQuarantined == true }
            .count

        var riskBreakdown: [String: Int] = [:]
        for item in downloadHistory {
            if let riskLevel = item.riskLevel {
                riskBreakdown[riskLevel, default: 0] += 1
            }
        }

        return DownloadSecurityReport(
            totalDownloads: totalDownloads,
            secureDownloads: secureDownloads,
            riskyDownloads: riskyDownloads,
            quarantinedDownloads: quarantinedDownloads,
            riskBreakdown: riskBreakdown,
            securityScanEnabled: securityScanEnabled,
            autoQuarantineEnabled: autoQuarantineDownloads,
            lastScanDate: downloads.last?.securityScanTimestamp
        )
    }

    /// Remove quarantine from a trusted download
    func removeQuarantine(from download: Download) async -> Bool {
        guard let quarantineInfo = download.quarantineInfo, quarantineInfo.isQuarantined else {
            return false
        }

        let success = await quarantineManager.removeQuarantine(from: download.destinationURL)

        if success {
            // Update quarantine info
            download.quarantineInfo = await quarantineManager.getQuarantineInfo(
                for: download.destinationURL)

            logDownloadSecurityEvent(
                isPrivate: download.isPrivate,
                filename: download.filename,
                sourceURL: download.url,
                eventType: .quarantineRemoved,
                severity: .info,
                details: ["userRequested": true]
            )
        }

        return success
    }

    /// Rescan a download for threats
    func rescanDownload(_ download: Download) async {
        guard download.status == .completed,
            FileManager.default.fileExists(atPath: download.destinationURL.path)
        else {
            return
        }

        download.malwareScanResult = await malwareScanner.scanFile(
            at: download.destinationURL,
            fileSize: download.totalBytes,
            fileHash: download.fileHash
        )

        download.securityScanTimestamp = Date()

        logDownloadSecurityEvent(
            isPrivate: download.isPrivate,
            filename: download.filename,
            sourceURL: download.url,
            eventType: .securityScanCompleted,
            severity: .info,
            details: ["rescan": true]
        )
    }

    /// Clear security warnings (dismiss pending warning)
    func clearSecurityWarnings() {
        pendingSecurityWarning = nil
    }

    /// Update security settings
    func updateSecuritySettings(
        scanEnabled: Bool? = nil,
        showWarnings: Bool? = nil,
        autoQuarantine: Bool? = nil
    ) {
        if let scanEnabled = scanEnabled {
            securityScanEnabled = scanEnabled
        }
        if let showWarnings = showWarnings {
            showSecurityWarnings = showWarnings
        }
        if let autoQuarantine = autoQuarantine {
            autoQuarantineDownloads = autoQuarantine
        }

        // Save settings
        UserDefaults.standard.set(
            securityScanEnabled, forKey: "DownloadManager.SecurityScanEnabled")
        UserDefaults.standard.set(
            showSecurityWarnings, forKey: "DownloadManager.ShowSecurityWarnings")
        UserDefaults.standard.set(
            autoQuarantineDownloads, forKey: "DownloadManager.AutoQuarantineDownloads")

        AppLog.debug(
            "Download security settings updated - Scan: \(self.securityScanEnabled), Warnings: \(self.showSecurityWarnings), Quarantine: \(self.autoQuarantineDownloads)"
        )
    }

    // MARK: - Security Settings Persistence

    private func loadSecuritySettings() {
        securityScanEnabled =
            UserDefaults.standard.object(forKey: "DownloadManager.SecurityScanEnabled") as? Bool ?? true  // Default true
        showSecurityWarnings =
            UserDefaults.standard.object(forKey: "DownloadManager.ShowSecurityWarnings") as? Bool ?? true  // Default true
        autoQuarantineDownloads =
            UserDefaults.standard.object(forKey: "DownloadManager.AutoQuarantineDownloads") as? Bool ?? true  // Default true
    }
}

// MARK: - Security Report Structure

struct DownloadSecurityReport {
    let totalDownloads: Int
    let secureDownloads: Int
    let riskyDownloads: Int
    let quarantinedDownloads: Int
    let riskBreakdown: [String: Int]
    let securityScanEnabled: Bool
    let autoQuarantineEnabled: Bool
    let lastScanDate: Date?

    var securityScore: Double {
        guard totalDownloads > 0 else { return 1.0 }
        return Double(secureDownloads) / Double(totalDownloads)
    }

    var formattedSecurityScore: String {
        return String(format: "%.1f%%", securityScore * 100)
    }
}

// Enhanced Download model with security integration
class Download: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var destinationURL: URL
    @Published var filename: String
    let startDate = Date()
    let isPrivate: Bool

    @Published var status: Status = .downloading
    @Published var totalBytes: Int64 = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var speed: Double = 0  // bytes per second
    @Published var completedDate: Date?

    var task: URLSessionDownloadTask?
    var webKitDownloadId: String?  // For WKDownload integration

    // MARK: - Security Integration
    var securityAnalysis: FileSecurityValidator.FileSecurityAnalysis?
    var malwareScanResult: MalwareScanner.ScanResult?
    var quarantineInfo: QuarantineManager.QuarantineInfo?
    var fileHash: String?
    var isSecurityValidated: Bool = false
    var securityScanTimestamp: Date?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    var remainingTime: TimeInterval? {
        guard speed > 0 && totalBytes > downloadedBytes else { return nil }
        let remainingBytes = max(0, totalBytes - downloadedBytes)
        guard remainingBytes > 0 else { return 0 }
        let time = Double(remainingBytes) / speed
        guard time.isFinite && time <= Double(Int.max) else { return nil }
        return time
    }

    enum Status {
        case downloading, paused, completed, failed, cancelled
    }

    init(url: URL, destinationURL: URL, filename: String, isPrivate: Bool = false) {
        self.url = url
        self.destinationURL = destinationURL
        self.filename = filename
        self.isPrivate = isPrivate
    }

    /// Get formatted file size
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file

        if status == .completed || totalBytes > 0 {
            return formatter.string(fromByteCount: totalBytes)
        } else {
            return "Unknown"
        }
    }

    /// Get formatted download speed
    var formattedSpeed: String {
        guard speed > 0 else { return "" }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file

        return "\(formatter.string(fromByteCount: Int64(speed)))/s"
    }

    /// Get estimated time remaining
    var formattedTimeRemaining: String {
        guard let remaining = remainingTime, remaining > 0 && remaining.isFinite else { return "" }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated

        return formatter.string(from: remaining) ?? ""
    }
}

// Enhanced Download history item with security metadata
struct DownloadHistoryItem: Codable, Identifiable {
    let id: UUID
    let url: String
    let filename: String
    let filePath: String
    let fileSize: Int64
    let downloadDate: Date
    let mimeType: String?
    let securityValidated: Bool
    let riskLevel: String?
    let fileHash: String?

    // Backward compatibility initializer
    init(
        id: UUID, url: String, filename: String, filePath: String, fileSize: Int64,
        downloadDate: Date, mimeType: String?
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.filePath = filePath
        self.fileSize = fileSize
        self.downloadDate = downloadDate
        self.mimeType = mimeType
        self.securityValidated = false
        self.riskLevel = nil
        self.fileHash = nil
    }

    // Enhanced initializer with security metadata
    init(
        id: UUID, url: String, filename: String, filePath: String, fileSize: Int64,
        downloadDate: Date, mimeType: String?, securityValidated: Bool, riskLevel: String?,
        fileHash: String?
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.filePath = filePath
        self.fileSize = fileSize
        self.downloadDate = downloadDate
        self.mimeType = mimeType
        self.securityValidated = securityValidated
        self.riskLevel = riskLevel
        self.fileHash = fileHash
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var fileExists: Bool {
        return FileManager.default.fileExists(atPath: filePath)
    }
}

// Download manager URLSession delegate
extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard let download = self.downloads.first(where: { $0.task == task }),
                  download.status != .cancelled else { return }
            download.status = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed
            self.updateActiveDownloadsCount()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession removes its temporary file when this callback returns.
        // Take ownership synchronously before starting asynchronous validation.
        let stagedFile: StagedDownloadFile
        do {
            stagedFile = try StagedDownloadFile(taking: location)
        } catch {
            Task { @MainActor in
                self.downloads.first(where: { $0.task == downloadTask })?.status = .failed
                self.updateActiveDownloadsCount()
            }
            return
        }
        Task { @MainActor in
            guard let download = self.downloads.first(where: { $0.task == downloadTask }) else { return }
            await self.completeDownload(download, stagedFile: stagedFile, mimeType: downloadTask.response?.mimeType)
        }
    }

    private func completeDownload(_ download: Download, stagedFile: StagedDownloadFile, mimeType: String?) async {
        let location = stagedFile.url
        defer { withExtendedLifetime(stagedFile) {} }
        guard download.status != .cancelled else { return }
            do {
                // Step 1: Calculate file hash for integrity verification
                let (fileHash, fileSize) = try await Task.detached(priority: .utility) {
                    let handle = try FileHandle(forReadingFrom: location)
                    defer { try? handle.close() }
                    var digest = SHA256()
                    var count: Int64 = 0
                    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                        digest.update(data: chunk)
                        count += Int64(chunk.count)
                    }
                    return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
                }.value
                download.fileHash = fileHash
                download.totalBytes = fileSize
                download.downloadedBytes = fileSize
                guard download.status != .cancelled else { return }

                // Step 2: Perform malware scanning if enabled
                if securityScanEnabled {
                    logDownloadSecurityEvent(
                        isPrivate: download.isPrivate,
                        filename: download.filename,
                        sourceURL: download.url,
                        eventType: .securityScanStarted,
                        severity: .info,
                        details: ["scanType": "post_download", "fileSize": "\(fileSize)"]
                    )

                    download.malwareScanResult = await malwareScanner.scanFile(
                        at: location,
                        fileSize: fileSize,
                        fileHash: download.fileHash
                    )

                    // Check scan results
                    if let scanResult = download.malwareScanResult, scanResult.isThreat {
                        logger.warning(
                            "🦠 Malware detected in downloaded file: \(download.filename)")

                        logDownloadSecurityEvent(
                            isPrivate: download.isPrivate,
                            filename: download.filename,
                            sourceURL: download.url,
                            eventType: .threatDetected,
                            severity: scanResult.severity >= .high ? .critical : .error,
                            details: [
                                "scanResult": scanResult.severity.displayName,
                                "threatType": "malware",
                            ]
                        )

                        // Block the download - don't move to final location
                        download.status = .failed
                        updateActiveDownloadsCount()

                        // Show security warning for detected threat
                        if showSecurityWarnings, let analysis = download.securityAnalysis {
                            showSecurityWarning(securityAnalysis: analysis, scanResult: scanResult)
                            {
                                // User wants to proceed despite threat
                                Task {
                                    await self.proceedWithRiskyDownload(
                                        download: download, location: stagedFile.url)
                                }
                            } onCancel: {
                                // User cancelled - remove the download
                                self.removeDownload(download)
                            }
                        }
                        return
                    }
                }

                // Apply quarantine before exposing bytes at the final path.
                if autoQuarantineDownloads {
                    let quarantineSuccess = await quarantineManager.quarantineDownloadedFile(
                        at: location,
                        sourceURL: download.url,
                        isPrivate: download.isPrivate
                    )

                    if quarantineSuccess {
                        download.quarantineInfo = await quarantineManager.getQuarantineInfo(
                            for: download.destinationURL)

                        logDownloadSecurityEvent(
                            isPrivate: download.isPrivate,
                            filename: download.filename,
                            sourceURL: download.url,
                            eventType: .quarantineApplied,
                            severity: .info,
                            details: ["quarantineType": "web_download"]
                        )
                    } else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }

                guard download.status != .cancelled else { return }
                download.destinationURL = createUniqueFileURL(for: download.destinationURL, excluding: download.id)
                download.filename = download.destinationURL.lastPathComponent
                try FileManager.default.moveItem(at: location, to: download.destinationURL)
                if autoQuarantineDownloads {
                    download.quarantineInfo = await quarantineManager.getQuarantineInfo(for: download.destinationURL)
                }

                // Step 5: Mark download as completed and validated
                download.status = .completed
                download.completedDate = Date()
                if case .clean? = download.malwareScanResult {
                    download.isSecurityValidated = true
                } else {
                    download.isSecurityValidated = false
                }
                download.securityScanTimestamp = Date()
                updateActiveDownloadsCount()

                // Step 6: Add to download history with security metadata
                let historyItem = DownloadHistoryItem(
                    id: UUID(),
                    url: download.url.absoluteString,
                    filename: download.filename,
                    filePath: download.destinationURL.path,
                    fileSize: download.totalBytes,
                    downloadDate: Date(),
                    mimeType: mimeType,
                    securityValidated: download.isSecurityValidated,
                    riskLevel: download.securityAnalysis?.riskLevel.displayName,
                    fileHash: download.fileHash
                )

                if !download.isPrivate {
                    downloadHistory.insert(historyItem, at: 0)
                }

                // Keep only last 100 downloads in history
                if downloadHistory.count > 100 {
                    downloadHistory = Array(downloadHistory.prefix(100))
                }

                if !download.isPrivate { saveDownloadHistory() }

                // Log successful completion
                logger.info("Download completed")

                logDownloadSecurityEvent(
                    isPrivate: download.isPrivate,
                    filename: download.filename,
                    sourceURL: download.url,
                    eventType: .securityScanCompleted,
                    severity: .info,
                    details: [
                        "downloadCompleted": true,
                        "securityValidated": download.isSecurityValidated,
                        "quarantined": download.quarantineInfo?.isQuarantined ?? false,
                        "fileHash": download.fileHash?.prefix(16) ?? "unknown",
                    ]
                )

            } catch {
                guard download.status != .cancelled else { return }
                download.status = .failed
                updateActiveDownloadsCount()

                logger.error("Failed to complete secure download: \(error.localizedDescription)")

                logDownloadSecurityEvent(
                    isPrivate: download.isPrivate,
                    filename: download.filename,
                    sourceURL: download.url,
                    eventType: .securityViolation,
                    severity: .error,
                    details: ["error": error.localizedDescription]
                )
            }
    }

    @MainActor
    private func proceedWithRiskyDownload(download: Download, location: URL) async {
        do {
            // Still apply quarantine even for risky files
            if autoQuarantineDownloads {
                guard await quarantineManager.quarantineDownloadedFile(at: location, sourceURL: download.url, isPrivate: download.isPrivate) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            guard download.status != .cancelled else { return }
            try FileManager.default.moveItem(at: location, to: download.destinationURL)

            download.status = .completed
            download.completedDate = Date()
            updateActiveDownloadsCount()

            logDownloadSecurityEvent(
                isPrivate: download.isPrivate,
                filename: download.filename,
                sourceURL: download.url,
                eventType: .userSecurityDecision,
                severity: .warning,
                details: [
                    "action": "proceeded_with_risky_download",
                    "threatDetected": true,
                ]
            )

            logger.warning("User proceeded with risky download: \(download.filename)")

        } catch {
            download.status = .failed
            updateActiveDownloadsCount()
            logger.error("Failed to move risky download: \(error.localizedDescription)")
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let download = self.downloads.first(where: { $0.task == downloadTask }) else {
                return
            }
            download.downloadedBytes = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite

            // Calculate speed with safety checks
            let timeElapsed = Date().timeIntervalSince(download.startDate)
            if timeElapsed > 0 && timeElapsed.isFinite {
                let speed = Double(totalBytesWritten) / timeElapsed
                download.speed = speed.isFinite && speed >= 0 ? speed : 0
            } else {
                download.speed = 0
            }
        }
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(
        _ webDownload: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
    ) {
        guard let identifier = webDownloadIdentifier(webDownload),
              let context = webViewContexts[identifier] else {
            completionHandler(nil)
            return
        }
        guard let sourceURL = response.url ?? webDownload.originalRequest?.url,
              sourceURL.user == nil, sourceURL.password == nil else {
            finishWebDownload(identifier)
            completionHandler(nil)
            return
        }
        let download = createDownload(from: sourceURL, suggestedFilename: suggestedFilename,
            isPrivate: context.isPrivate)
        download.webKitDownloadId = identifier
        download.totalBytes = response.expectedContentLength
        context.model = download
        context.mimeType = response.mimeType
        downloads.append(download)
        updateActiveDownloadsCount()

        Task { @MainActor in
            let analysis = await fileSecurityValidator.analyzeFileSecurity(
                url: sourceURL, suggestedFilename: download.filename,
                mimeType: response.mimeType, expectedFileSize: response.expectedContentLength)
            download.securityAnalysis = analysis
            guard webViewContexts[identifier] === context, download.status != .cancelled else {
                completionHandler(nil)
                return
            }
            if ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
               case .unsafe = await SafeBrowsingManager.shared.checkURLSafety(
                sourceURL, allowRemoteLookup: !context.isPrivate) {
                download.status = .failed
                finishWebDownload(identifier)
                updateActiveDownloadsCount()
                completionHandler(nil)
                return
            }
            guard webViewContexts[identifier] === context, download.status != .cancelled else {
                completionHandler(nil)
                return
            }
            let blocked = fileSecurityValidator.shouldBlockDownload(analysis)
            if blocked || (analysis.requiresUserConfirmation && showSecurityWarnings) {
                let approved = await confirmWebDownload(
                    download, analysis: analysis, blocked: blocked, window: webDownload.webView?.window)
                guard approved else {
                    if download.status != .cancelled { download.status = blocked ? .failed : .cancelled }
                    finishWebDownload(identifier)
                    updateActiveDownloadsCount()
                    completionHandler(nil)
                    return
                }
            }
            guard webViewContexts[identifier] === context, download.status != .cancelled else {
                completionHandler(nil)
                return
            }
            do {
                let stagedFile = try StagedDownloadFile(filename: download.filename)
                context.stagedFile = stagedFile
                let progress = webDownload.progress
                context.observations = [
                    progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
                        let completed = progress.completedUnitCount
                        let total = progress.totalUnitCount
                        Task { @MainActor in
                            guard let self, self.webViewContexts[identifier] != nil,
                                  download.status == .downloading else { return }
                            download.downloadedBytes = max(0, completed)
                            download.totalBytes = total
                            let elapsed = Date().timeIntervalSince(download.startDate)
                            download.speed = elapsed > 0 ? Double(max(0, completed)) / elapsed : 0
                        }
                    }
                ]
                completionHandler(stagedFile.url)
            } catch {
                download.status = .failed
                finishWebDownload(identifier)
                updateActiveDownloadsCount()
                completionHandler(nil)
            }
        }
    }

    func downloadDidFinish(_ webDownload: WKDownload) {
        guard let identifier = webDownloadIdentifier(webDownload),
              let context = webViewContexts[identifier] else { return }
        guard let download = context.model, let stagedFile = context.stagedFile else {
            context.model?.status = .failed
            finishWebDownload(identifier)
            updateActiveDownloadsCount()
            return
        }
        finishWebDownload(identifier)
        Task { @MainActor in
            await completeDownload(download, stagedFile: stagedFile, mimeType: context.mimeType)
        }
    }

    func download(_ webDownload: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let identifier = webDownloadIdentifier(webDownload) else { return }
        if let download = webViewContexts[identifier]?.model, download.status != .cancelled {
            download.status = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed
        }
        finishWebDownload(identifier)
        updateActiveDownloadsCount()
    }

    func download(
        _ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else {
            if let identifier = webDownloadIdentifier(download) {
                webViewContexts[identifier]?.model?.status = .failed
                finishWebDownload(identifier)
                updateActiveDownloadsCount()
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func confirmWebDownload(
        _ download: Download, analysis: FileSecurityValidator.FileSecurityAnalysis,
        blocked: Bool, window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = blocked ? "Download blocked" : "Download this file?"
        alert.informativeText = download.filename + "\n\n" + analysis.riskReasons.joined(separator: "\n")
        alert.addButton(withTitle: blocked ? "OK" : "Cancel")
        if !blocked { alert.addButton(withTitle: "Download") }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        return !blocked && response == .alertSecondButtonReturn
    }
}

enum DownloadFileDestination {
    static func uniqueURL(for url: URL, reservedURLs: [URL] = []) -> URL {
        let directory = url.deletingLastPathComponent()
        let safeURL = directory.appendingPathComponent(BrowserSecurityPolicy.downloadFilename(url.lastPathComponent))
        let reserved = Set(reservedURLs.map(\.standardizedFileURL))
        var candidate = safeURL
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.standardizedFileURL) {
            let stem = safeURL.deletingPathExtension().lastPathComponent
            let suffix = safeURL.pathExtension.isEmpty ? "" : "." + safeURL.pathExtension
            candidate = directory.appendingPathComponent("\(stem) (\(counter))\(suffix)")
            counter += 1
        }
        return candidate
    }
}


/// Owns a download's temporary bytes until validation or a user decision finishes.
final class StagedDownloadFile: @unchecked Sendable {
    let url: URL
    private let directory: URL

    init(filename: String = "download") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(BrowserSecurityPolicy.downloadFilename(filename))
    }

    convenience init(taking source: URL) throws {
        try self.init(filename: source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: url)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
