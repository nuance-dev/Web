import CoreServices
import Foundation
import Security
import os.log

/// QuarantineManager
///
/// Comprehensive macOS quarantine integration for downloaded file protection.
///
/// Key Features:
/// - Native macOS quarantine attribute management
/// - Integration with Gatekeeper and XProtect systems
/// - Extended attribute management for downloaded files
/// - Quarantine removal for trusted files
/// - Security event logging and audit trails
/// - User-friendly quarantine status reporting
///
/// Security Design:
/// - Leverages macOS built-in security frameworks
/// - Proper integration with system security policies
/// - Comprehensive quarantine metadata tracking
/// - Safe quarantine removal with validation
/// - Integration with download source validation
@MainActor
class QuarantineManager: ObservableObject {
    static let shared = QuarantineManager()

    private let logger = Logger(subsystem: "com.example.Web", category: "QuarantineManager")

    // MARK: - Configuration

    @Published var isEnabled: Bool = true
    @Published var autoQuarantineDownloads: Bool = true
    @Published var strictQuarantineMode: Bool = false
    @Published var totalFilesQuarantined: Int = 0
    @Published var totalQuarantineRemovals: Int = 0

    // MARK: - Quarantine Constants

    private let kLSQuarantineTypeKey = "LSQuarantineType"
    private let kLSQuarantineAgentNameKey = "LSQuarantineAgentName"
    private let kLSQuarantineAgentBundleIdentifierKey = "LSQuarantineAgentBundleIdentifier"
    private let kLSQuarantineTimeStampKey = "LSQuarantineTimeStamp"
    private let kLSQuarantineDataURLKey = "LSQuarantineDataURL"
    private let kLSQuarantineOriginURLKey = "LSQuarantineOriginURL"

    // MARK: - Quarantine Types

    enum QuarantineType: String {
        case webDownload = "LSQuarantineTypeWebDownload"
        case emailAttachment = "LSQuarantineTypeEmailAttachment"
        case instantMessage = "LSQuarantineTypeInstantMessage"
        case calendar = "LSQuarantineTypeCalendar"
        case other = "LSQuarantineTypeOther"

        var displayName: String {
            switch self {
            case .webDownload: return "Web Download"
            case .emailAttachment: return "Email Attachment"
            case .instantMessage: return "Instant Message"
            case .calendar: return "Calendar Event"
            case .other: return "Other"
            }
        }
    }

    // MARK: - Quarantine Status

    struct QuarantineInfo {
        let isQuarantined: Bool
        let quarantineType: QuarantineType?
        let sourceURL: URL?
        let agentName: String?
        let agentBundleId: String?
        let quarantineDate: Date?
        let canRemoveQuarantine: Bool
        let gateKeeperStatus: GateKeeperStatus

        var displayDescription: String {
            if !isQuarantined {
                return "File is not quarantined"
            }

            var description = "Quarantined as \(quarantineType?.displayName ?? "Unknown Type")"
            if let agent = agentName {
                description += " by \(agent)"
            }
            if let date = quarantineDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                description += " on \(formatter.string(from: date))"
            }
            return description
        }
    }

    enum GateKeeperStatus {
        case signed(developer: String)
        case unsigned
        case invalid
        case notApplicable
        case unknown

        var displayName: String {
            switch self {
            case .signed(let developer): return "Signed by \(developer)"
            case .unsigned: return "Unsigned"
            case .invalid: return "Invalid Signature"
            case .notApplicable: return "Not Applicable"
            case .unknown: return "Unknown"
            }
        }

        var isSecure: Bool {
            switch self {
            case .signed: return true
            case .notApplicable: return true
            default: return false
            }
        }
    }

    // MARK: - Initialization

    private init() {
        loadQuarantineSettings()
        loadQuarantineStatistics()
        AppLog.debug("QuarantineManager init: auto=\(self.autoQuarantineDownloads)")
    }

    // MARK: - Public API

    /**
     * Apply quarantine attributes to a downloaded file
     *
     * Sets appropriate quarantine attributes including:
     * - Quarantine type (web download)
     * - Source URL and referrer information
     * - Download agent information (browser)
     * - Timestamp and metadata
     *
     * - Parameter fileURL: Local file URL to quarantine
     * - Parameter sourceURL: The URL where the file was downloaded from
     * - Parameter referrerURL: The page URL that initiated the download
     * - Returns: Bool indicating success of quarantine application
     */
    func quarantineDownloadedFile(
        at fileURL: URL,
        sourceURL: URL,
        referrerURL: URL? = nil,
        isPrivate: Bool = false
    ) async -> Bool {
        guard isEnabled && autoQuarantineDownloads else {
            logger.debug("Quarantine disabled, skipping file: \(fileURL.lastPathComponent)")
            return true
        }

        logger.info("Applying quarantine to downloaded file: \(fileURL.lastPathComponent)")

        do {
            let result = try QuarantineFileMetadata.apply(
                to: fileURL, sourceURL: sourceURL, referrerURL: referrerURL, isPrivate: isPrivate)

            if result {
                await incrementFilesQuarantined()
                logger.info("Successfully quarantined file: \(fileURL.lastPathComponent)")

                // Log security event
                logSecurityEvent(
                    event: "file_quarantined",
                    fileURL: fileURL,
                    sourceURL: isPrivate ? nil : sourceURL,
                    details: ["agent": "Web Browser", "type": "web_download"],
                    isPrivate: isPrivate
                )

                return true
            } else {
                logger.error(
                    "Failed to apply quarantine attributes to: \(fileURL.lastPathComponent)")
                return false
            }

        } catch {
            logger.error("Quarantine operation failed: \(error.localizedDescription)")
            return false
        }
    }

    /**
     * Get quarantine information for a file
     *
     * Retrieves comprehensive quarantine status including:
     * - Current quarantine state
     * - Quarantine metadata and source information
     * - Gatekeeper signature status
     * - Removal permissions and recommendations
     */
    func getQuarantineInfo(for fileURL: URL) async -> QuarantineInfo {
        do {
            // Get quarantine properties
            let resourceValues = try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey])

            guard let quarantineProps = resourceValues.quarantineProperties,
                !quarantineProps.isEmpty
            else {
                // File is not quarantined
                let gateKeeperStatus = await checkGateKeeperStatus(fileURL: fileURL)
                return QuarantineInfo(
                    isQuarantined: false,
                    quarantineType: nil,
                    sourceURL: nil,
                    agentName: nil,
                    agentBundleId: nil,
                    quarantineDate: nil,
                    canRemoveQuarantine: false,
                    gateKeeperStatus: gateKeeperStatus
                )
            }

            // Parse quarantine properties
            let quarantineType = parseQuarantineType(from: quarantineProps)
            let sourceURL = parseSourceURL(from: quarantineProps)
            let agentName = quarantineProps[kLSQuarantineAgentNameKey] as? String
            let agentBundleId = quarantineProps[kLSQuarantineAgentBundleIdentifierKey] as? String
            let quarantineDate = quarantineProps[kLSQuarantineTimeStampKey] as? Date

            // Check Gatekeeper status
            let gateKeeperStatus = await checkGateKeeperStatus(fileURL: fileURL)

            // Determine if quarantine can be safely removed
            let canRemove = await canSafelyRemoveQuarantine(
                fileURL: fileURL, gateKeeperStatus: gateKeeperStatus)

            return QuarantineInfo(
                isQuarantined: true,
                quarantineType: quarantineType,
                sourceURL: sourceURL,
                agentName: agentName,
                agentBundleId: agentBundleId,
                quarantineDate: quarantineDate,
                canRemoveQuarantine: canRemove,
                gateKeeperStatus: gateKeeperStatus
            )

        } catch {
            logger.error("Failed to get quarantine info: \(error.localizedDescription)")

            // Return unknown status
            return QuarantineInfo(
                isQuarantined: false,
                quarantineType: nil,
                sourceURL: nil,
                agentName: nil,
                agentBundleId: nil,
                quarantineDate: nil,
                canRemoveQuarantine: false,
                gateKeeperStatus: .unknown
            )
        }
    }

    /**
     * Remove quarantine from a trusted file
     *
     * Safely removes quarantine attributes after validation:
     * - Verifies file is safe to unquarantine
     * - Checks digital signatures and Gatekeeper status
     * - Logs security event for audit trail
     * - Applies additional safety checks in strict mode
     */
    func removeQuarantine(from fileURL: URL, userConfirmed: Bool = false) async -> Bool {
        logger.info("Attempting to remove quarantine from: \(fileURL.lastPathComponent)")

        // Get current quarantine info
        let quarantineInfo = await getQuarantineInfo(for: fileURL)

        guard quarantineInfo.isQuarantined else {
            logger.debug("File is not quarantined: \(fileURL.lastPathComponent)")
            return true
        }

        // Safety checks
        if strictQuarantineMode && !userConfirmed {
            logger.warning("Strict quarantine mode requires user confirmation")
            return false
        }

        if !quarantineInfo.canRemoveQuarantine && !userConfirmed {
            logger.warning("Quarantine removal not recommended without user confirmation")
            return false
        }

        do {
            // Remove quarantine extended attributes
            let result = try removeQuarantineExtendedAttributes(fileURL: fileURL)

            if result {
                await incrementQuarantineRemovals()
                logger.info("Successfully removed quarantine from: \(fileURL.lastPathComponent)")

                // Log security event
                logSecurityEvent(
                    event: "quarantine_removed",
                    fileURL: fileURL,
                    sourceURL: quarantineInfo.sourceURL,
                    details: [
                        "userConfirmed": userConfirmed,
                        "gateKeeperStatus": quarantineInfo.gateKeeperStatus.displayName,
                        "originalType": quarantineInfo.quarantineType?.displayName ?? "Unknown",
                    ]
                )

                return true
            } else {
                logger.error("Failed to remove quarantine attributes")
                return false
            }

        } catch {
            logger.error("Quarantine removal failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Implementation

    private func removeQuarantineExtendedAttributes(fileURL: URL) throws -> Bool {
        let result = removexattr(fileURL.path, "com.apple.quarantine", 0)
        return result == 0 || errno == ENOATTR  // Success or attribute doesn't exist
    }

    private func parseQuarantineType(from properties: [String: Any]) -> QuarantineType? {
        guard let typeString = properties[kLSQuarantineTypeKey] as? String else {
            return nil
        }
        return QuarantineType(rawValue: typeString)
    }

    private func parseSourceURL(from properties: [String: Any]) -> URL? {
        if let url = properties[kLSQuarantineDataURLKey] as? URL { return url }
        if let urlString = properties[kLSQuarantineDataURLKey] as? String {
            return URL(string: urlString)
        }
        return nil
    }

    private func checkGateKeeperStatus(fileURL: URL) async -> GateKeeperStatus {
        // Check if file is an executable that would be subject to Gatekeeper
        let fileExtension = fileURL.pathExtension.lowercased()
        let executableExtensions = ["app", "dmg", "pkg", "mpkg"]

        guard executableExtensions.contains(fileExtension) else {
            return .notApplicable
        }

        // Use codesign to check signature status
        return await checkCodeSignature(fileURL: fileURL)
    }

    private func checkCodeSignature(fileURL: URL) async -> GateKeeperStatus {
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.launchPath = "/usr/bin/codesign"
            task.arguments = ["--verify", "--verbose", fileURL.path]

            let pipe = Pipe()
            task.standardError = pipe

            task.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if task.terminationStatus == 0 {
                    // Parse developer information from output
                    if let range = output.range(of: "Authority="),
                        let endRange = output[range.upperBound...].range(of: "\n")
                    {
                        let developer = String(output[range.upperBound..<endRange.lowerBound])
                        continuation.resume(returning: .signed(developer: developer))
                    } else {
                        continuation.resume(returning: .signed(developer: "Unknown Developer"))
                    }
                } else if output.contains("not signed") {
                    continuation.resume(returning: .unsigned)
                } else {
                    continuation.resume(returning: .invalid)
                }
            }

            do {
                try task.run()
            } catch {
                continuation.resume(returning: .unknown)
            }
        }
    }

    private func canSafelyRemoveQuarantine(fileURL: URL, gateKeeperStatus: GateKeeperStatus) async
        -> Bool
    {
        // Files with valid signatures can generally be safely unquarantined
        if gateKeeperStatus.isSecure {
            return true
        }

        // In strict mode, be more conservative
        if strictQuarantineMode {
            return gateKeeperStatus.isSecure
        }

        // For non-executable files, quarantine removal is generally safe
        let fileExtension = fileURL.pathExtension.lowercased()
        let executableExtensions = ["app", "dmg", "pkg", "mpkg", "command", "tool"]

        return !executableExtensions.contains(fileExtension)
    }

    // MARK: - Security Event Logging

    private func logSecurityEvent(
        event: String,
        fileURL: URL,
        sourceURL: URL?,
        details: [String: Any],
        isPrivate: Bool = false
    ) {
        var logDetails = details
        if !isPrivate {
            logDetails["filename"] = fileURL.lastPathComponent
            logDetails["filePath"] = fileURL.path
            if let source = sourceURL { logDetails["sourceURL"] = source.absoluteString }
        }
        logDetails["timestamp"] = Date().timeIntervalSince1970

        logger.info("Security Event: \(event) - Details: \(logDetails)")

        // In production, you might want to send these events to a security monitoring system
        NotificationCenter.default.post(
            name: .quarantineSecurityEvent,
            object: nil,
            userInfo: [
                "event": event,
                "details": logDetails,
            ]
        )
    }

    // MARK: - Statistics Management

    private func incrementFilesQuarantined() async {
        totalFilesQuarantined += 1
        UserDefaults.standard.set(
            totalFilesQuarantined, forKey: "QuarantineManager.FilesQuarantined")
    }

    private func incrementQuarantineRemovals() async {
        totalQuarantineRemovals += 1
        UserDefaults.standard.set(
            totalQuarantineRemovals, forKey: "QuarantineManager.QuarantineRemovals")
    }

    private func loadQuarantineStatistics() {
        totalFilesQuarantined = UserDefaults.standard.integer(
            forKey: "QuarantineManager.FilesQuarantined")
        totalQuarantineRemovals = UserDefaults.standard.integer(
            forKey: "QuarantineManager.QuarantineRemovals")
    }

    // MARK: - Settings Management

    private func loadQuarantineSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "QuarantineManager.Enabled") != false  // Default true
        autoQuarantineDownloads =
            UserDefaults.standard.bool(forKey: "QuarantineManager.AutoQuarantine") != false  // Default true
        strictQuarantineMode = UserDefaults.standard.bool(forKey: "QuarantineManager.StrictMode")  // Default false
    }

    func saveQuarantineSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "QuarantineManager.Enabled")
        UserDefaults.standard.set(
            autoQuarantineDownloads, forKey: "QuarantineManager.AutoQuarantine")
        UserDefaults.standard.set(strictQuarantineMode, forKey: "QuarantineManager.StrictMode")

        logger.info(
            "Quarantine settings saved - Enabled: \(self.isEnabled), Auto: \(self.autoQuarantineDownloads), Strict: \(self.strictQuarantineMode)"
        )
    }

    /**
     * Get quarantine statistics for reporting
     */
    func getQuarantineStatistics() -> [String: Any] {
        return [
            "enabled": isEnabled,
            "autoQuarantineDownloads": autoQuarantineDownloads,
            "strictQuarantineMode": strictQuarantineMode,
            "totalFilesQuarantined": totalFilesQuarantined,
            "totalQuarantineRemovals": totalQuarantineRemovals,
        ]
    }

    /**
     * Reset quarantine statistics
     */
    func resetStatistics() {
        totalFilesQuarantined = 0
        totalQuarantineRemovals = 0
        UserDefaults.standard.removeObject(forKey: "QuarantineManager.FilesQuarantined")
        UserDefaults.standard.removeObject(forKey: "QuarantineManager.QuarantineRemovals")
        logger.info("Quarantine statistics reset")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let quarantineSecurityEvent = Notification.Name("quarantineSecurityEvent")
}


/// Use Launch Services' native quarantine encoding. Private files retain protection
/// without carrying a source URL in quarantine or Spotlight metadata.
enum QuarantineFileMetadata {
    static func apply(to fileURL: URL, sourceURL: URL, referrerURL: URL? = nil, isPrivate: Bool) throws -> Bool {
        if isPrivate {
            for attribute in ["com.apple.quarantine", "com.apple.metadata:kMDItemWhereFroms"] {
                let result = removexattr(fileURL.path, attribute, 0)
                if result != 0 && errno != ENOATTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
        var properties: [String: Any] = [
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
            "LSQuarantineAgentName": "Web Browser",
            "LSQuarantineAgentBundleIdentifier": Bundle.main.bundleIdentifier ?? "com.example.Web",
            "LSQuarantineTimeStamp": Date()
        ]
        if !isPrivate {
            properties["LSQuarantineDataURL"] = sourceURL
            if let referrerURL { properties["LSQuarantineOriginURL"] = referrerURL }
        }
        try (fileURL as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
        let freshURL = URL(fileURLWithPath: fileURL.path)
        let values = try freshURL.resourceValues(forKeys: [.quarantinePropertiesKey])
        return values.quarantineProperties?.isEmpty == false
    }
}
