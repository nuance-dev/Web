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
    @Published var securityScanEnabled: Bool = true
    @Published var showSecurityWarnings: Bool = true
    @Published var autoQuarantineDownloads: Bool = true

    // WKWebView integration
    private var webViewDownloads: [String: WKDownload] = [:]

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
        let config = URLSessionConfiguration.default
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

    func startDownload(from url: URL, suggestedFilename: String? = nil) {
        // ENHANCED SECURITY: Comprehensive security validation pipeline
        Task { @MainActor in
            let filename = suggestedFilename ?? url.lastPathComponent

            // Log download initiation
            securityMonitor.logDownloadSecurityEvent(
                filename: filename,
                sourceURL: url,
                eventType: .downloadInitiated,
                severity: .info,
                details: ["userInitiated": true]
            )

            // Step 1: Safe Browsing URL validation
            let safetyResult = await SafeBrowsingManager.shared.checkURLSafety(url)

            switch safetyResult {
            case .safe:
                // URL is safe - proceed with comprehensive security validation
                await self.performSecurityValidationAndDownload(
                    from: url, suggestedFilename: suggestedFilename)

            case .unsafe(let threat):
                // URL is malicious - block download and log security event
                self.logger.warning(
                    "Safe Browsing blocked malicious download: \(url.absoluteString) (Threat: \(threat.threatType.userFriendlyName))"
                )

                securityMonitor.logDownloadSecurityEvent(
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
                    "Safe Browsing check failed for download URL: \(url.absoluteString) - proceeding with enhanced security"
                )

                securityMonitor.logDownloadSecurityEvent(
                    filename: filename,
                    sourceURL: url,
                    eventType: .suspiciousActivity,
                    severity: .warning,
                    details: ["reason": "Safe Browsing check failed"]
                )

                await self.performSecurityValidationAndDownload(
                    from: url, suggestedFilename: suggestedFilename)
            }
        }
    }

    @MainActor
    private func performSecurityValidationAndDownload(from url: URL, suggestedFilename: String?)
        async
    {
        let filename = suggestedFilename ?? url.lastPathComponent

        // Step 2: File security analysis
        let securityAnalysis = await fileSecurityValidator.analyzeFileSecurity(
            url: url,
            suggestedFilename: filename,
            mimeType: nil,
            expectedFileSize: -1
        )

        securityMonitor.logDownloadSecurityEvent(
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

            securityMonitor.logDownloadSecurityEvent(
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
            let download = createDownload(from: url, suggestedFilename: suggestedFilename)

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
            let download = createDownload(from: url, suggestedFilename: suggestedFilename)
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

        securityMonitor.logDownloadSecurityEvent(
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

    private func createDownload(from url: URL, suggestedFilename: String?) -> Download {
        let filename = suggestedFilename ?? url.lastPathComponent
        let destinationURL = downloadDirectory.appendingPathComponent(filename)
        let finalURL = createUniqueFileURL(for: destinationURL)

        return Download(
            url: url,
            destinationURL: finalURL,
            filename: finalURL.lastPathComponent
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
                destinationURL: downloadDirectory.appendingPathComponent(securityAnalysis.filename),
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
        download.task?.suspend()
        download.status = .paused
    }

    func resumeDownload(_ download: Download) {
        download.task?.resume()
        download.status = .downloading
    }

    func cancelDownload(_ download: Download) {
        download.task?.cancel()
        download.status = .cancelled
        updateActiveDownloadsCount()
    }

    func removeDownload(_ download: Download) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
        }
    }

    private func createUniqueFileURL(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        while FileManager.default.fileExists(atPath: finalURL.path) {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            finalURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(name) (\(counter))")
                .appendingPathExtension(ext)
            counter += 1
        }

        return finalURL
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

    /// Clear persisted download history entries
    func clearDownloadHistory() {
        downloadHistory.removeAll()
        saveDownloadHistory()
        AppLog.debug("Cleared download history")
    }

    /// Clear completed/failed/cancelled downloads and history records
    func clearCompletedAndHistory() {
        clearCompletedDownloads()
        clearDownloadHistory()
    }

    // MARK: - WKWebView Integration

    /// Handle WKDownload from WKWebView
    func handleWebViewDownload(_ download: WKDownload) {
        guard let url = download.originalRequest?.url else {
            logger.error("WKDownload missing original request URL")
            return
        }

        // Safely extract filename with fallback
        let filename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let downloadId = UUID().uuidString
        webViewDownloads[downloadId] = download

        let webDownload = Download(
            url: url,
            destinationURL: downloadDirectory.appendingPathComponent(filename),
            filename: filename
        )
        webDownload.webKitDownloadId = downloadId

        downloads.append(webDownload)
        updateActiveDownloadsCount()

        logger.info("Started WKWebView download: \(filename)")
    }

    /// Check if navigation should trigger download based on MIME type
    func shouldDownloadResponse(_ response: URLResponse) -> Bool {
        guard let mimeType = response.mimeType else { return false }

        let downloadableMimeTypes = [
            "application/pdf",
            "application/zip",
            "application/x-zip-compressed",
            "application/octet-stream",
            "application/msword",
            "application/vnd.ms-excel",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument",
            "image/jpeg",
            "image/png",
            "image/gif",
            "image/svg+xml",
            "video/mp4",
            "video/quicktime",
            "audio/mpeg",
            "audio/wav",
        ]

        return downloadableMimeTypes.contains { mimeType.hasPrefix($0) }
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

            securityMonitor.logDownloadSecurityEvent(
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

        securityMonitor.logDownloadSecurityEvent(
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
            UserDefaults.standard.bool(forKey: "DownloadManager.SecurityScanEnabled") != false  // Default true
        showSecurityWarnings =
            UserDefaults.standard.bool(forKey: "DownloadManager.ShowSecurityWarnings") != false  // Default true
        autoQuarantineDownloads =
            UserDefaults.standard.bool(forKey: "DownloadManager.AutoQuarantineDownloads") != false  // Default true
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
    let destinationURL: URL
    let filename: String
    let startDate = Date()

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

    init(url: URL, destinationURL: URL, filename: String) {
        self.url = url
        self.destinationURL = destinationURL
        self.filename = filename
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
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // ENHANCED SECURITY: Comprehensive post-download validation
        Task { @MainActor in
            guard let download = self.downloads.first(where: { $0.task == downloadTask }) else {
                return
            }
            do {
                // Step 1: Calculate file hash for integrity verification
                let fileData = try Data(contentsOf: location)
                let hash = SHA256.hash(data: fileData)
                download.fileHash = hash.compactMap { String(format: "%02x", $0) }.joined()

                // Step 2: Perform malware scanning if enabled
                if securityScanEnabled {
                    securityMonitor.logDownloadSecurityEvent(
                        filename: download.filename,
                        sourceURL: download.url,
                        eventType: .securityScanStarted,
                        severity: .info,
                        details: ["scanType": "post_download", "fileSize": "\(fileData.count)"]
                    )

                    download.malwareScanResult = await malwareScanner.scanFile(
                        at: location,
                        fileSize: Int64(fileData.count),
                        fileHash: download.fileHash
                    )

                    // Check scan results
                    if let scanResult = download.malwareScanResult, scanResult.isThreat {
                        logger.warning(
                            "🦠 Malware detected in downloaded file: \(download.filename)")

                        securityMonitor.logDownloadSecurityEvent(
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
                                        download: download, location: location)
                                }
                            } onCancel: {
                                // User cancelled - remove the download
                                self.removeDownload(download)
                            }
                        }
                        return
                    }
                }

                // Step 3: Move file to final destination
                try FileManager.default.moveItem(at: location, to: download.destinationURL)

                // Step 4: Apply quarantine attributes if enabled
                if autoQuarantineDownloads {
                    let quarantineSuccess = await quarantineManager.quarantineDownloadedFile(
                        at: download.destinationURL,
                        sourceURL: download.url
                    )

                    if quarantineSuccess {
                        download.quarantineInfo = await quarantineManager.getQuarantineInfo(
                            for: download.destinationURL)

                        securityMonitor.logDownloadSecurityEvent(
                            filename: download.filename,
                            sourceURL: download.url,
                            eventType: .quarantineApplied,
                            severity: .info,
                            details: ["quarantineType": "web_download"]
                        )
                    } else {
                        logger.warning("Failed to apply quarantine to: \(download.filename)")
                    }
                }

                // Step 5: Mark download as completed and validated
                download.status = .completed
                download.completedDate = Date()
                download.isSecurityValidated = true
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
                    mimeType: downloadTask.response?.mimeType,
                    securityValidated: download.isSecurityValidated,
                    riskLevel: download.securityAnalysis?.riskLevel.displayName,
                    fileHash: download.fileHash
                )

                downloadHistory.insert(historyItem, at: 0)

                // Keep only last 100 downloads in history
                if downloadHistory.count > 100 {
                    downloadHistory = Array(downloadHistory.prefix(100))
                }

                saveDownloadHistory()

                // Log successful completion
                logger.info("Secure download completed with full validation: \(download.filename)")

                securityMonitor.logDownloadSecurityEvent(
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
                download.status = .failed
                updateActiveDownloadsCount()

                logger.error("Failed to complete secure download: \(error.localizedDescription)")

                securityMonitor.logDownloadSecurityEvent(
                    filename: download.filename,
                    sourceURL: download.url,
                    eventType: .securityViolation,
                    severity: .error,
                    details: ["error": error.localizedDescription]
                )
            }
        }
    }

    @MainActor
    private func proceedWithRiskyDownload(download: Download, location: URL) async {
        do {
            // User chose to proceed despite threat detection
            try FileManager.default.moveItem(at: location, to: download.destinationURL)

            // Still apply quarantine even for risky files
            if autoQuarantineDownloads {
                _ = await quarantineManager.quarantineDownloadedFile(
                    at: download.destinationURL,
                    sourceURL: download.url
                )
            }

            download.status = .completed
            download.completedDate = Date()
            updateActiveDownloadsCount()

            securityMonitor.logDownloadSecurityEvent(
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
