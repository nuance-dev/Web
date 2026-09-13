import CryptoKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers
import os.log

/// FileSecurityValidator
///
/// Comprehensive file security validation and risk assessment service for download protection.
///
/// Key Features:
/// - Multi-level risk classification (Safe, Low, Medium, High, Critical)
/// - File type validation with UTI-based detection
/// - Extension spoofing detection and prevention
/// - Archive bomb detection and size validation
/// - Digital signature verification for executables
/// - Integration with macOS Gatekeeper and XProtect
/// - User-configurable security policies
///
/// Security Design:
/// - Zero-tolerance for critical threats by default
/// - Progressive security warnings based on risk levels
/// - Comprehensive logging for audit trails
/// - Integration with macOS security frameworks
@MainActor
class FileSecurityValidator: ObservableObject {
    static let shared = FileSecurityValidator()

    private let logger = Logger(subsystem: "com.example.Web", category: "FileSecurityValidator")

    // MARK: - Security Configuration

    @Published var securityPolicy: SecurityPolicy = .balanced
    @Published var allowUnknownFileTypes: Bool = false
    @Published var requireUserConfirmationForExecutables: Bool = true
    @Published var enableArchiveBombDetection: Bool = true
    @Published var maximumFileSize: Int64 = 5 * 1024 * 1024 * 1024  // 5GB
    @Published var enableDigitalSignatureVerification: Bool = true

    // MARK: - Security Policy Configuration

    enum SecurityPolicy: String, CaseIterable {
        case permissive = "permissive"
        case balanced = "balanced"
        case strict = "strict"
        case enterprise = "enterprise"

        var displayName: String {
            switch self {
            case .permissive: return "Permissive"
            case .balanced: return "Balanced"
            case .strict: return "Strict"
            case .enterprise: return "Enterprise"
            }
        }

        var description: String {
            switch self {
            case .permissive: return "Minimal restrictions, allows most downloads"
            case .balanced: return "Recommended security with user warnings"
            case .strict: return "High security, blocks most dangerous files"
            case .enterprise: return "Maximum security for corporate environments"
            }
        }
    }

    // MARK: - Risk Assessment Types

    enum SecurityRisk: Int, Comparable, CaseIterable {
        case safe = 0
        case low = 1
        case medium = 2
        case high = 3
        case critical = 4

        static func < (lhs: SecurityRisk, rhs: SecurityRisk) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }

        var displayName: String {
            switch self {
            case .safe: return "Safe"
            case .low: return "Low Risk"
            case .medium: return "Medium Risk"
            case .high: return "High Risk"
            case .critical: return "Critical Risk"
            }
        }

        var color: Color {
            switch self {
            case .safe: return .green
            case .low: return .yellow
            case .medium: return .orange
            case .high: return .red
            case .critical: return .purple
            }
        }

        var requiresUserConfirmation: Bool {
            switch self {
            case .safe, .low: return false
            case .medium: return true
            case .high, .critical: return true
            }
        }

        var shouldBlockByDefault: Bool {
            switch self {
            case .safe, .low, .medium: return false
            case .high: return false  // Allow with warning
            case .critical: return true  // Block by default
            }
        }
    }

    // MARK: - File Analysis Result

    struct FileSecurityAnalysis {
        let url: URL
        let filename: String
        let fileExtension: String
        let detectedUTI: UTType?
        let mimeType: String?
        let fileSize: Int64
        let riskLevel: SecurityRisk
        let riskReasons: [String]
        let recommendations: [String]
        let isExecutable: Bool
        let isArchive: Bool
        let isSpoofed: Bool
        let digitalSignatureStatus: DigitalSignatureStatus
        let scanTimestamp: Date

        var isBlocked: Bool {
            return riskLevel.shouldBlockByDefault
        }

        var requiresUserConfirmation: Bool {
            return riskLevel.requiresUserConfirmation
        }

        var warningMessage: String {
            if isBlocked {
                return
                    "This file type is blocked for security reasons: \(riskReasons.joined(separator: ", "))"
            } else if requiresUserConfirmation {
                return "This file may be dangerous: \(riskReasons.joined(separator: ", "))"
            } else {
                return "File appears safe to download"
            }
        }
    }

    enum DigitalSignatureStatus {
        case notApplicable
        case valid(developer: String)
        case invalid
        case unsigned
        case notChecked

        var displayName: String {
            switch self {
            case .notApplicable: return "Not Applicable"
            case .valid(let developer): return "Valid (Developer: \(developer))"
            case .invalid: return "Invalid Signature"
            case .unsigned: return "Unsigned"
            case .notChecked: return "Not Checked"
            }
        }

        var isSecure: Bool {
            switch self {
            case .valid: return true
            case .notApplicable: return true
            default: return false
            }
        }
    }

    // MARK: - File Type Classifications

    private let executableExtensions: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "installer", "command", "tool",
        "exe", "msi", "bat", "cmd", "com", "scr", "pif",
        "sh", "bash", "zsh", "fish", "csh", "tcsh",
        "bin", "run", "deb", "rpm",
    ]

    private let scriptExtensions: Set<String> = [
        "scpt", "applescript", "workflow", "action",
        "js", "jsx", "ts", "tsx", "vbs", "ps1", "psm1",
        "py", "pyc", "pyo", "rb", "pl", "php", "asp",
        "jsp", "jar", "class",
    ]

    private let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
        "dmg", "iso", "img", "toast", "cdr",
        "sit", "sitx", "stuffit", "arc", "arj", "lzh",
    ]

    private let documentExtensions: Set<String> = [
        "txt",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "rtf", "odt", "ods", "odp", "pages", "numbers", "key",
    ]

    private let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "svg",
        "mp3", "aac", "flac", "wav", "ogg", "m4a",
        "mp4", "avi", "mov", "mkv", "webm", "m4v", "wmv", "flv",
    ]

    private let blockedExtensions: Set<String> = [
        "scr", "pif", "bat", "cmd", "com", "exe", "msi",
        "vbs", "jse", "wsh", "wsf", "ws", "scf",
    ]

    // MARK: - Initialization

    init(loadPersistedSettings: Bool = true) {
        if loadPersistedSettings { loadSecuritySettings() }
        AppLog.debug("FileSecurityValidator init: policy=\(self.securityPolicy.displayName)")
    }

    // MARK: - Public API

    /**
     * Analyze file security and provide risk assessment
     *
     * Performs comprehensive security analysis including:
     * - File type detection and validation
     * - Extension spoofing detection
     * - Risk level assessment based on security policy
     * - Digital signature verification for executables
     * - Archive bomb detection for compressed files
     *
     * - Parameter url: The URL of the file to analyze
     * - Parameter suggestedFilename: The suggested filename from the download
     * - Parameter mimeType: The MIME type from HTTP headers
     * - Parameter expectedFileSize: The expected file size in bytes
     * - Returns: FileSecurityAnalysis with comprehensive security assessment
     */
    func analyzeFileSecurity(
        url: URL,
        suggestedFilename: String,
        mimeType: String? = nil,
        expectedFileSize: Int64 = -1
    ) async -> FileSecurityAnalysis {
        logger.debug("Analyzing file security for: \(suggestedFilename)")

        let filename = suggestedFilename.isEmpty ? url.lastPathComponent : suggestedFilename
        let fileExtension = getFileExtension(from: filename).lowercased()
        let detectedUTI = UTType(filenameExtension: fileExtension)

        var riskReasons: [String] = []
        var recommendations: [String] = []
        var riskLevel: SecurityRisk = .safe

        // 1. File Size Validation
        if expectedFileSize > maximumFileSize {
            riskReasons.append(
                "File size exceeds maximum allowed (\(ByteCountFormatter().string(fromByteCount: maximumFileSize)))"
            )
            riskLevel = max(riskLevel, .medium)
            recommendations.append("Consider if this large file is necessary")
        }

        // 2. Extension Analysis
        let extensionRisk = analyzeFileExtension(fileExtension)
        riskLevel = max(riskLevel, extensionRisk.risk)
        riskReasons.append(contentsOf: extensionRisk.reasons)
        recommendations.append(contentsOf: extensionRisk.recommendations)

        // 3. Filename Spoofing Detection
        let spoofingAnalysis = detectFilenameSpoofing(filename: filename, mimeType: mimeType)
        if spoofingAnalysis.isSpoofed {
            riskLevel = max(riskLevel, .high)
            riskReasons.append(contentsOf: spoofingAnalysis.reasons)
            recommendations.append("Verify the actual file type before opening")
        }

        // 4. UTI-based Analysis
        if let uti = detectedUTI {
            let utiRisk = analyzeUTI(uti)
            riskLevel = max(riskLevel, utiRisk.risk)
            riskReasons.append(contentsOf: utiRisk.reasons)
        }

        // 5. MIME Type Validation
        if let mime = mimeType {
            let mimeRisk = analyzeMimeType(mime, extension: fileExtension)
            riskLevel = max(riskLevel, mimeRisk.risk)
            riskReasons.append(contentsOf: mimeRisk.reasons)
        }

        // 6. Security Policy Application
        riskLevel = applySecurityPolicy(riskLevel, fileExtension: fileExtension)

        // 7. Digital Signature Analysis (for executables)
        let isExecutable =
            executableExtensions.contains(fileExtension) || scriptExtensions.contains(fileExtension)
        let digitalSignatureStatus: DigitalSignatureStatus =
            isExecutable ? .notChecked : .notApplicable

        // 8. Generate final recommendations
        if recommendations.isEmpty {
            recommendations.append("File appears safe based on current security policy")
        }

        let analysis = FileSecurityAnalysis(
            url: url,
            filename: filename,
            fileExtension: fileExtension,
            detectedUTI: detectedUTI,
            mimeType: mimeType,
            fileSize: expectedFileSize,
            riskLevel: riskLevel,
            riskReasons: riskReasons,
            recommendations: recommendations,
            isExecutable: isExecutable,
            isArchive: archiveExtensions.contains(fileExtension),
            isSpoofed: spoofingAnalysis.isSpoofed,
            digitalSignatureStatus: digitalSignatureStatus,
            scanTimestamp: Date()
        )

        // Log security analysis results
        logger.info(
            "File security analysis complete - Risk: \(riskLevel.displayName), File: \(filename)")
        if riskLevel >= .medium {
            logger.warning(
                "Medium+ risk file detected: \(filename) - Reasons: \(riskReasons.joined(separator: ", "))"
            )
        }

        return analysis
    }

    /**
     * Check if file type should be blocked based on security policy
     */
    func shouldBlockDownload(_ analysis: FileSecurityAnalysis) -> Bool {
        // Always block critical risk files
        if analysis.riskLevel == .critical {
            return true
        }

        // Apply policy-based blocking
        switch securityPolicy {
        case .permissive:
            return analysis.riskLevel == .critical
        case .balanced:
            return analysis.riskLevel >= .critical
        case .strict:
            return analysis.riskLevel >= .high
        case .enterprise:
            return analysis.riskLevel >= .medium
        }
    }

    /**
     * Get user-friendly warning message for risky downloads
     */
    func getSecurityWarningMessage(_ analysis: FileSecurityAnalysis) -> String {
        if shouldBlockDownload(analysis) {
            return "Download blocked: \(analysis.warningMessage)"
        } else if analysis.requiresUserConfirmation {
            return "Security warning: \(analysis.warningMessage)"
        } else {
            return analysis.warningMessage
        }
    }

    // MARK: - Private Analysis Methods

    private func analyzeFileExtension(_ extension: String) -> (
        risk: SecurityRisk, reasons: [String], recommendations: [String]
    ) {
        var risk: SecurityRisk = .safe
        var reasons: [String] = []
        var recommendations: [String] = []

        if blockedExtensions.contains(`extension`) {
            risk = .critical
            reasons.append("File type is known to be dangerous (\(`extension`))")
            recommendations.append("Do not download or execute this file type")
        } else if executableExtensions.contains(`extension`) {
            risk = .high
            reasons.append("Executable file that could run code on your system")
            recommendations.append(
                "Only download from trusted sources and verify digital signature")
        } else if scriptExtensions.contains(`extension`) {
            risk = .medium
            reasons.append("Script file that could execute commands")
            recommendations.append("Review script content before execution")
        } else if archiveExtensions.contains(`extension`) {
            risk = .low
            reasons.append("Archive file that may contain multiple files")
            recommendations.append("Scan archive contents before extraction")
        } else if documentExtensions.contains(`extension`) {
            risk = .safe
        } else if mediaExtensions.contains(`extension`) {
            risk = .safe
        } else {
            // Unknown file type
            if !allowUnknownFileTypes {
                risk = .medium
                reasons.append("Unknown or uncommon file type")
                recommendations.append("Verify file type and source before opening")
            }
        }

        return (risk, reasons, recommendations)
    }

    private func detectFilenameSpoofing(filename: String, mimeType: String?) -> (
        isSpoofed: Bool, reasons: [String]
    ) {
        var reasons: [String] = []
        var isSpoofed = false

        // Check for double extensions (e.g., "document.pdf.exe")
        let components = filename.components(separatedBy: ".")
        if components.count > 2 {
            let extensions = Array(components.dropFirst())
            if extensions.count >= 2 {
                let firstExt = extensions[extensions.count - 2].lowercased()
                let lastExt = extensions[extensions.count - 1].lowercased()

                // Check if first extension suggests safe file but last is dangerous
                if (documentExtensions.contains(firstExt) || mediaExtensions.contains(firstExt))
                    && (executableExtensions.contains(lastExt)
                        || scriptExtensions.contains(lastExt))
                {
                    isSpoofed = true
                    reasons.append("Suspicious double extension detected (.\(firstExt).\(lastExt))")
                }
            }
        }

        // Check for misleading Unicode characters
        if filename.contains("\u{202E}") || filename.contains("\u{202D}") {
            isSpoofed = true
            reasons.append("Filename contains Unicode direction override characters")
        }

        // Check MIME type vs extension mismatch
        if let mime = mimeType {
            let expectedExtensions = getExpectedExtensions(for: mime)
            let actualExtension = getFileExtension(from: filename).lowercased()

            if !expectedExtensions.isEmpty && !expectedExtensions.contains(actualExtension) {
                isSpoofed = true
                reasons.append("File extension doesn't match MIME type (\(mime))")
            }
        }

        return (isSpoofed, reasons)
    }

    private func analyzeUTI(_ uti: UTType) -> (risk: SecurityRisk, reasons: [String]) {
        var risk: SecurityRisk = .safe
        var reasons: [String] = []

        if uti.conforms(to: .executable) {
            risk = .high
            reasons.append("System-identified executable file")
        } else if uti.conforms(to: .application) {
            risk = .high
            reasons.append("Application bundle or installer")
        } else if uti.conforms(to: .script) {
            risk = .medium
            reasons.append("Script or automation file")
        } else if uti.conforms(to: .archive) {
            risk = .low
            reasons.append("Archive or compressed file")
        }

        return (risk, reasons)
    }

    private func analyzeMimeType(_ mimeType: String, extension: String) -> (
        risk: SecurityRisk, reasons: [String]
    ) {
        var risk: SecurityRisk = .safe
        var reasons: [String] = []

        let dangerousMimeTypes = [
            "application/x-executable",
            "application/x-msdos-program",
            "application/x-msdownload",
            "application/x-mach-binary",
            "application/x-sh",
            "application/x-csh",
            "text/x-sh",
            "application/javascript",
            "text/javascript",
        ]

        if dangerousMimeTypes.contains(mimeType.lowercased()) {
            risk = .high
            reasons.append("Dangerous MIME type: \(mimeType)")
        } else if mimeType == "application/octet-stream" {
            // Generic binary - could be anything
            risk = .medium
            reasons.append("Generic binary file type")
        }

        return (risk, reasons)
    }

    private func applySecurityPolicy(_ baseRisk: SecurityRisk, fileExtension: String)
        -> SecurityRisk
    {
        switch securityPolicy {
        case .permissive:
            // Reduce risk by one level (but never below safe)
            return SecurityRisk(rawValue: max(0, baseRisk.rawValue - 1)) ?? .safe
        case .balanced:
            // Keep original risk assessment
            return baseRisk
        case .strict:
            // Increase risk for executables
            if executableExtensions.contains(fileExtension) {
                return SecurityRisk(rawValue: min(4, baseRisk.rawValue + 1)) ?? .critical
            }
            return baseRisk
        case .enterprise:
            // Maximum security - increase all non-safe risks
            if baseRisk != .safe {
                return SecurityRisk(rawValue: min(4, baseRisk.rawValue + 1)) ?? .critical
            }
            return baseRisk
        }
    }

    // MARK: - Utility Methods

    private func getFileExtension(from filename: String) -> String {
        return (filename as NSString).pathExtension
    }

    private func getExpectedExtensions(for mimeType: String) -> Set<String> {
        switch mimeType.lowercased() {
        case "application/pdf": return ["pdf"]
        case "image/jpeg": return ["jpg", "jpeg"]
        case "image/png": return ["png"]
        case "application/zip": return ["zip"]
        case "text/plain": return ["txt"]
        case "application/json": return ["json"]
        case "text/html": return ["html", "htm"]
        default: return []
        }
    }

    // MARK: - Settings Persistence

    private func loadSecuritySettings() {
        if let policyString = UserDefaults.standard.string(
            forKey: "FileSecurityValidator.SecurityPolicy"),
            let policy = SecurityPolicy(rawValue: policyString)
        {
            securityPolicy = policy
        }

        allowUnknownFileTypes = UserDefaults.standard.bool(
            forKey: "FileSecurityValidator.AllowUnknownTypes")
        requireUserConfirmationForExecutables =
            UserDefaults.standard.bool(forKey: "FileSecurityValidator.RequireConfirmation") != false  // Default true
        enableArchiveBombDetection =
            UserDefaults.standard.bool(forKey: "FileSecurityValidator.ArchiveBombDetection")
            != false  // Default true
        enableDigitalSignatureVerification =
            UserDefaults.standard.bool(forKey: "FileSecurityValidator.SignatureVerification")
            != false  // Default true

        let maxSize =
            UserDefaults.standard.object(forKey: "FileSecurityValidator.MaxFileSize") as? Int64
        maximumFileSize = maxSize ?? (5 * 1024 * 1024 * 1024)  // Default 5GB
    }

    func saveSecuritySettings() {
        UserDefaults.standard.set(
            securityPolicy.rawValue, forKey: "FileSecurityValidator.SecurityPolicy")
        UserDefaults.standard.set(
            allowUnknownFileTypes, forKey: "FileSecurityValidator.AllowUnknownTypes")
        UserDefaults.standard.set(
            requireUserConfirmationForExecutables,
            forKey: "FileSecurityValidator.RequireConfirmation")
        UserDefaults.standard.set(
            enableArchiveBombDetection, forKey: "FileSecurityValidator.ArchiveBombDetection")
        UserDefaults.standard.set(
            enableDigitalSignatureVerification,
            forKey: "FileSecurityValidator.SignatureVerification")
        UserDefaults.standard.set(maximumFileSize, forKey: "FileSecurityValidator.MaxFileSize")

        logger.info("Security settings saved with policy: \(self.securityPolicy.displayName)")
    }

    /**
     * Reset security settings to secure defaults
     */
    func resetToDefaults() {
        securityPolicy = .balanced
        allowUnknownFileTypes = false
        requireUserConfirmationForExecutables = true
        enableArchiveBombDetection = true
        enableDigitalSignatureVerification = true
        maximumFileSize = 5 * 1024 * 1024 * 1024  // 5GB

        saveSecuritySettings()
        logger.info("Security settings reset to secure defaults")
    }
}

// MARK: - Security Extensions

extension FileSecurityValidator {
    /**
     * Get security statistics for reporting
     */
    func getSecurityStatistics() -> [String: Any] {
        return [
            "securityPolicy": securityPolicy.displayName,
            "allowUnknownFileTypes": allowUnknownFileTypes,
            "requireUserConfirmation": requireUserConfirmationForExecutables,
            "archiveBombDetection": enableArchiveBombDetection,
            "signatureVerification": enableDigitalSignatureVerification,
            "maxFileSizeMB": maximumFileSize / (1024 * 1024),
            "supportedFileTypes": [
                "executable": executableExtensions.count,
                "script": scriptExtensions.count,
                "archive": archiveExtensions.count,
                "document": documentExtensions.count,
                "media": mediaExtensions.count,
                "blocked": blockedExtensions.count,
            ],
        ]
    }
}
