import CryptoKit
import Foundation
import SwiftUI
import os.log

/// Local security event diagnostics with encrypted on-disk records.
/// This is not malware protection, remote monitoring, or a compliance guarantee.
@MainActor
class SecurityMonitor: ObservableObject {
    static let shared = SecurityMonitor()

    internal let logger = Logger(subsystem: "com.example.Web", category: "SecurityMonitor")

    // MARK: - Configuration

    @Published var isEnabled: Bool = true
    @Published var enableRealTimeAlerts: Bool = true
    @Published var enableThreatAnalysis: Bool = true
    @Published var logRetentionDays: Int = 30
    @Published var maxLogFileSize: Int64 = 10 * 1024 * 1024  // 10MB

    // MARK: - Security Metrics

    @Published var totalSecurityEvents: Int = 0
    @Published var totalThreatsBlocked: Int = 0
    @Published var totalDownloadsScanned: Int = 0
    @Published var totalQuarantineEvents: Int = 0
    @Published var averageRiskScore: Double = 0.0
    @Published var lastThreatDetected: Date?

    // MARK: - Private Properties

    private let logDirectory: URL
    private lazy var encryptionKey: SymmetricKey = Self.getOrCreateEncryptionKey()
    private var currentLogFile: URL?
    private let logQueue = DispatchQueue(label: "security.monitor.logging", qos: .utility)
    internal let analysisQueue = DispatchQueue(label: "security.monitor.analysis", qos: .background)

    // In-memory event buffer for real-time analysis
    private var eventBuffer: [SecurityEvent] = []
    private let maxBufferSize = 1000

    // Threat pattern detection
    private var threatPatterns: [ThreatPattern] = []
    private var recentThreats: [ThreatDetection] = []

    // MARK: - Security Event Types

    struct SecurityEvent: Codable {
        let id: UUID
        let timestamp: Date
        let eventType: EventType
        let severity: Severity
        let source: String
        let message: String
        let details: [String: String]  // Simplified for Codable compliance
        let userAgent: String?
        let sessionId: String?

        enum EventType: String, Codable, CaseIterable {
            case downloadInitiated = "download_initiated"
            case securityScanStarted = "security_scan_started"
            case securityScanCompleted = "security_scan_completed"
            case threatDetected = "threat_detected"
            case threatBlocked = "threat_blocked"
            case userSecurityDecision = "user_security_decision"
            case quarantineApplied = "quarantine_applied"
            case quarantineRemoved = "quarantine_removed"
            case securityPolicyChanged = "security_policy_changed"
            case suspiciousActivity = "suspicious_activity"
            case securityViolation = "security_violation"

            var displayName: String {
                switch self {
                case .downloadInitiated: return "Download Initiated"
                case .securityScanStarted: return "Security Scan Started"
                case .securityScanCompleted: return "Security Scan Completed"
                case .threatDetected: return "Threat Detected"
                case .threatBlocked: return "Threat Blocked"
                case .userSecurityDecision: return "User Security Decision"
                case .quarantineApplied: return "Quarantine Applied"
                case .quarantineRemoved: return "Quarantine Removed"
                case .securityPolicyChanged: return "Security Policy Changed"
                case .suspiciousActivity: return "Suspicious Activity"
                case .securityViolation: return "Security Violation"
                }
            }
        }

        enum Severity: String, Codable, CaseIterable, Comparable {
            case info = "info"
            case warning = "warning"
            case error = "error"
            case critical = "critical"

            static func < (lhs: Severity, rhs: Severity) -> Bool {
                let order: [Severity] = [.info, .warning, .error, .critical]
                guard let lhsIndex = order.firstIndex(of: lhs),
                    let rhsIndex = order.firstIndex(of: rhs)
                else {
                    return false
                }
                return lhsIndex < rhsIndex
            }

            var color: Color {
                switch self {
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                case .critical: return .purple
                }
            }
        }
    }

    // MARK: - Threat Detection

    struct ThreatPattern {
        let id: UUID
        let name: String
        let description: String
        let conditions: [PatternCondition]
        let timeWindow: TimeInterval
        let threshold: Int
        let severity: SecurityEvent.Severity
        let isEnabled: Bool

        struct PatternCondition {
            let field: String
            let `operator`: ConditionOperator
            let value: String

            enum ConditionOperator: String {
                case equals = "equals"
                case contains = "contains"
                case greaterThan = "greater_than"
                case lessThan = "less_than"
                case regex = "regex"
            }
        }
    }

    struct ThreatDetection {
        let id: UUID
        let pattern: ThreatPattern
        let matchingEvents: [SecurityEvent]
        let detectedAt: Date
        let riskScore: Double
        let isAcknowledged: Bool
    }

    // MARK: - Security Metrics

    struct SecurityMetrics: Codable {
        let totalEvents: Int
        let eventsLast24Hours: Int
        let eventsLast7Days: Int
        let eventsLast30Days: Int
        let threatsByType: [String: Int]
        let threatsBySeverity: [String: Int]
        let averageRiskScore: Double
        let topThreats: [String]
        let securityTrends: [TrendData]

        struct TrendData: Codable {
            let date: Date
            let eventCount: Int
            let threatCount: Int
            let averageRisk: Double
        }
    }

    // MARK: - Initialization

    private init() {
        // Setup log directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        logDirectory = appSupport.appendingPathComponent("Web/SecurityLogs")

        // Create log directory
        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)

        // Load configuration and metrics
        loadConfiguration()
        loadSecurityMetrics()
        loadThreatPatterns()

        // Setup log rotation timer
        setupLogRotation()

        AppLog.debug("SecurityMonitor initialized (encryption key deferred)")
    }

    // MARK: - Public API

    /**
     * Log a security event with comprehensive details
     *
     * Records security events with encryption and integrity protection:
     * - Encrypts sensitive event data
     * - Adds tamper detection
     * - Performs real-time threat analysis
     * - Triggers alerts for critical events
     * - Updates security metrics
     */
    func logSecurityEvent(
        eventType: SecurityEvent.EventType,
        severity: SecurityEvent.Severity,
        source: String,
        message: String,
        details: [String: Any] = [:],
        userAgent: String? = nil
    ) {
        guard isEnabled else { return }

        // Convert details to string dictionary for Codable compliance
        let sensitiveKeys = ["password", "secret", "authorization", "cookie", "user_id", "identifier",
            "jwt_subject", "session_id", "device_", "source_ip", "redirect_uri", "sourceurl"]
        let safeDetails = details.filter { key, _ in
            !sensitiveKeys.contains { key.lowercased().contains($0) }
        }
        let stringDetails = safeDetails.mapValues { value in
            if let stringValue = value as? String {
                return stringValue
            } else if let codableValue = value as? CustomStringConvertible {
                return codableValue.description
            } else {
                return String(describing: value)
            }
        }

        let event = SecurityEvent(
            id: UUID(),
            timestamp: Date(),
            eventType: eventType,
            severity: severity,
            source: source,
            message: message,
            details: stringDetails,
            userAgent: userAgent,
            sessionId: getCurrentSessionId()
        )

        // Log to system logger
        let logMessage = "[\(eventType.displayName)] \(message)"
        switch severity {
        case .info:
            logger.info("\(logMessage)")
        case .warning:
            logger.warning("\(logMessage)")
        case .error:
            logger.error("\(logMessage)")
        case .critical:
            logger.critical("\(logMessage)")
        }

        // Process event asynchronously
        Task { [weak self] in
            await self?.processSecurityEvent(event)
        }
    }

    /**
     * Get security metrics for dashboard and reporting
     */
    func getSecurityMetrics() async -> SecurityMetrics {
        return await withCheckedContinuation { continuation in
            analysisQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(
                        returning: SecurityMetrics(
                            totalEvents: 0,
                            eventsLast24Hours: 0,
                            eventsLast7Days: 0,
                            eventsLast30Days: 0,
                            threatsByType: [:],
                            threatsBySeverity: [:],
                            averageRiskScore: 0.0,
                            topThreats: [],
                            securityTrends: []
                        ))
                    return
                }

                Task { @MainActor in
                    let metrics = self.calculateSecurityMetrics()
                    continuation.resume(returning: metrics)
                }
            }
        }
    }

    /**
     * Get recent security events for monitoring dashboard
     */
    func getRecentEvents(limit: Int = 100) -> [SecurityEvent] {
        return Array(eventBuffer.suffix(limit))
    }

    /**
     * Get active threat detections
     */
    func getActiveThreats() -> [ThreatDetection] {
        let cutoffTime = Date().addingTimeInterval(-24 * 3600)  // Last 24 hours
        return recentThreats.filter { $0.detectedAt > cutoffTime && !$0.isAcknowledged }
    }

    /**
     * Acknowledge a threat detection
     */
    func acknowledgeThreat(threatId: UUID) {
        if let index = recentThreats.firstIndex(where: { $0.id == threatId }) {
            let threat = recentThreats[index]
            recentThreats[index] = ThreatDetection(
                id: threat.id,
                pattern: threat.pattern,
                matchingEvents: threat.matchingEvents,
                detectedAt: threat.detectedAt,
                riskScore: threat.riskScore,
                isAcknowledged: true
            )

            logSecurityEvent(
                eventType: .userSecurityDecision,
                severity: .info,
                source: "SecurityMonitor",
                message: "Threat acknowledgment by user",
                details: ["threatId": threatId.uuidString, "patternName": threat.pattern.name]
            )
        }
    }

    /**
     * Export security logs for analysis or compliance
     */
    func exportSecurityLogs(dateRange: ClosedRange<Date>) async -> Data? {
        return await withCheckedContinuation { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    // Read and decrypt relevant log files
                    let events = try self.readEventsInDateRange(dateRange)

                    // Create export data structure
                    let exportData = SecurityLogExport(
                        exportDate: Date(),
                        dateRange: dateRange,
                        events: events,
                        metadata: [
                            "version": "1.0",
                            "source": "Web Browser Security Monitor",
                            "eventCount": "\(events.count)",
                        ]
                    )

                    // Encode to JSON
                    let jsonData = try JSONEncoder().encode(exportData)
                    continuation.resume(returning: jsonData)

                } catch {
                    self.logger.error(
                        "Failed to export security logs: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Private Implementation

    private func processSecurityEvent(_ event: SecurityEvent) async {
        // Add to buffer (main actor access)
        await MainActor.run {
            eventBuffer.append(event)
            if eventBuffer.count > maxBufferSize {
                eventBuffer.removeFirst()
            }
        }

        // Write to encrypted log file (background operation)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.writeEventToLog(event)
            }

            group.addTask { [weak self] in
                await self?.updateSecurityMetrics(with: event)
            }
        }

        // Perform threat analysis (background operation)
        let shouldAnalyze = await MainActor.run { enableThreatAnalysis }
        if shouldAnalyze {
            await analyzeForThreats(event)
        }

        // Send real-time alerts for critical events
        let shouldAlert = await MainActor.run { enableRealTimeAlerts }
        if shouldAlert && event.severity >= .error {
            sendRealTimeAlert(for: event)
        }

        // Update published properties on main actor
        await MainActor.run { [weak self] in
            self?.totalSecurityEvents += 1

            if event.eventType == .threatDetected || event.eventType == .threatBlocked {
                self?.totalThreatsBlocked += 1
                self?.lastThreatDetected = event.timestamp
            }

            if event.eventType == .securityScanCompleted {
                self?.totalDownloadsScanned += 1
            }

            if event.eventType == .quarantineApplied {
                self?.totalQuarantineEvents += 1
            }
        }
    }

    private func writeEventToLog(_ event: SecurityEvent) {
        do {
            // Ensure current log file exists
            if currentLogFile == nil || shouldRotateLog() {
                createNewLogFile()
            }

            guard let logFile = currentLogFile else {
                logger.error("No current log file available")
                return
            }

            // Serialize and encrypt event
            let eventData = try JSONEncoder().encode(event)
            let encryptedData = try encryptData(eventData)

            // Append to log file
            let fileHandle = try FileHandle(forWritingTo: logFile)
            fileHandle.seekToEndOfFile()

            // Write length prefix and encrypted data
            let lengthData = withUnsafeBytes(of: UInt32(encryptedData.count).bigEndian) { Data($0) }
            fileHandle.write(lengthData)
            fileHandle.write(encryptedData)
            fileHandle.closeFile()

        } catch {
            logger.error("Failed to write security event to log: \(error.localizedDescription)")
        }
    }

    private func analyzeForThreats(_ event: SecurityEvent) async {
        let patterns = await MainActor.run { threatPatterns }

        for pattern in patterns where pattern.isEnabled {
            if matchesPattern(event: event, pattern: pattern) {
                // Check if we have enough matching events in the time window
                let windowStart = Date().addingTimeInterval(-pattern.timeWindow)
                let currentBuffer = await MainActor.run { eventBuffer }
                let matchingEvents = currentBuffer.filter { bufferEvent in
                    bufferEvent.timestamp > windowStart
                        && matchesPattern(event: bufferEvent, pattern: pattern)
                }

                if matchingEvents.count >= pattern.threshold {
                    // Threat pattern detected
                    let riskScore = calculateRiskScore(events: matchingEvents, pattern: pattern)
                    let detection = ThreatDetection(
                        id: UUID(),
                        pattern: pattern,
                        matchingEvents: matchingEvents,
                        detectedAt: Date(),
                        riskScore: riskScore,
                        isAcknowledged: false
                    )

                    await MainActor.run {
                        recentThreats.append(detection)
                    }

                    // Log the threat detection
                    logSecurityEvent(
                        eventType: .threatDetected,
                        severity: pattern.severity,
                        source: "ThreatAnalysis",
                        message: "Threat pattern detected: \(pattern.name)",
                        details: [
                            "patternId": pattern.id.uuidString,
                            "matchingEvents": "\(matchingEvents.count)",
                            "riskScore": String(format: "%.2f", riskScore),
                        ]
                    )
                }
            }
        }
    }

    private func matchesPattern(event: SecurityEvent, pattern: ThreatPattern) -> Bool {
        for condition in pattern.conditions {
            if !evaluateCondition(event: event, condition: condition) {
                return false
            }
        }
        return true
    }

    private func evaluateCondition(event: SecurityEvent, condition: ThreatPattern.PatternCondition)
        -> Bool
    {
        let fieldValue: String

        switch condition.field {
        case "eventType":
            fieldValue = event.eventType.rawValue
        case "severity":
            fieldValue = event.severity.rawValue
        case "source":
            fieldValue = event.source
        case "message":
            fieldValue = event.message
        case "userAgent":
            fieldValue = event.userAgent ?? ""
        default:
            fieldValue = event.details[condition.field] ?? ""
        }

        switch condition.operator {
        case .equals:
            return fieldValue == condition.value
        case .contains:
            return fieldValue.localizedCaseInsensitiveContains(condition.value)
        case .greaterThan:
            return Double(fieldValue) ?? 0 > Double(condition.value) ?? 0
        case .lessThan:
            return Double(fieldValue) ?? 0 < Double(condition.value) ?? 0
        case .regex:
            do {
                let regex = try NSRegularExpression(pattern: condition.value)
                let range = NSRange(location: 0, length: fieldValue.utf16.count)
                return regex.firstMatch(in: fieldValue, options: [], range: range) != nil
            } catch {
                return false
            }
        }
    }

    private func calculateRiskScore(events: [SecurityEvent], pattern: ThreatPattern) -> Double {
        var score = 0.0

        // Base score from pattern severity
        switch pattern.severity {
        case .info: score += 0.25
        case .warning: score += 0.5
        case .error: score += 0.75
        case .critical: score += 1.0
        }

        // Increase score based on event frequency
        let frequency = Double(events.count) / pattern.timeWindow * 3600  // events per hour
        score += min(frequency * 0.1, 1.0)

        // Increase score for recent events
        let recentEvents = events.filter { $0.timestamp > Date().addingTimeInterval(-3600) }
        if !recentEvents.isEmpty {
            score += Double(recentEvents.count) / Double(events.count) * 0.5
        }

        return min(score, 4.0)  // Cap at 4.0
    }

    private func sendRealTimeAlert(for event: SecurityEvent) {
        // Post notification for UI alerts
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .securityAlert,
                object: nil,
                userInfo: [
                    "event": event,
                    "timestamp": Date(),
                ]
            )
        }
    }

    // MARK: - Log Management

    private func createNewLogFile() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "security-\(timestamp).log"
        currentLogFile = logDirectory.appendingPathComponent(filename)

        // Create empty log file
        FileManager.default.createFile(atPath: currentLogFile!.path, contents: nil)
        if AppLog.isVerboseEnabled { AppLog.debug("Created security log file: \(filename)") }
    }

    private func shouldRotateLog() -> Bool {
        guard let logFile = currentLogFile else { return true }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logFile.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            return fileSize >= maxLogFileSize
        } catch {
            return true
        }
    }

    private func setupLogRotation() {
        // Setup timer for daily log rotation and old log cleanup
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performLogMaintenance()
            }
        }
    }

    private func performLogMaintenance() {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                // Rotate current log
                self.createNewLogFile()

                // Clean up old logs
                self.cleanupOldLogs()

                if AppLog.isVerboseEnabled {
                    self.logger.debug("Performed log maintenance - rotation and cleanup")
                }
            }
        }
    }

    private func cleanupOldLogs() {
        do {
            let logFiles = try FileManager.default.contentsOfDirectory(
                at: logDirectory, includingPropertiesForKeys: [.creationDateKey])
            let cutoffDate = Date().addingTimeInterval(-Double(logRetentionDays) * 24 * 3600)

            for file in logFiles {
                let attributes = try file.resourceValues(forKeys: [.creationDateKey])
                if let creationDate = attributes.creationDate, creationDate < cutoffDate {
                    try FileManager.default.removeItem(at: file)
                    if AppLog.isVerboseEnabled {
                        logger.debug("Deleted old log file: \(file.lastPathComponent)")
                    }
                }
            }
        } catch {
            logger.error("Failed to cleanup old logs: \(error.localizedDescription)")
        }
    }

    // MARK: - Encryption

    private func encryptData(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        return sealedBox.combined!
    }

    private func decryptData(_ encryptedData: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: encryptionKey)
    }

    private static func getOrCreateEncryptionKey() -> SymmetricKey {
        let keyData = "SecurityMonitor.EncryptionKey"

        // Try to load existing key from Keychain
        if let existingKey = loadKeyFromKeychain(identifier: keyData) {
            return existingKey
        }

        // Generate new key
        let newKey = SymmetricKey(size: .bits256)
        saveKeyToKeychain(key: newKey, identifier: keyData)
        return newKey
    }

    private static func loadKeyFromKeychain(identifier: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyData = result as? Data else {
            return nil
        }

        return SymmetricKey(data: keyData)
    }

    private static func saveKeyToKeychain(key: SymmetricKey, identifier: String) {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Metrics and Analysis

    private func calculateSecurityMetrics() -> SecurityMetrics {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 3600)

        let eventsLast24Hours = eventBuffer.filter { $0.timestamp > oneDayAgo }.count
        let eventsLast7Days = eventBuffer.filter { $0.timestamp > sevenDaysAgo }.count
        let eventsLast30Days = eventBuffer.filter { $0.timestamp > thirtyDaysAgo }.count

        var threatsByType: [String: Int] = [:]
        var threatsBySeverity: [String: Int] = [:]

        for event in eventBuffer {
            threatsByType[event.eventType.displayName, default: 0] += 1
            threatsBySeverity[event.severity.rawValue, default: 0] += 1
        }

        // Calculate trends (simplified)
        let securityTrends: [SecurityMetrics.TrendData] = []

        return SecurityMetrics(
            totalEvents: eventBuffer.count,
            eventsLast24Hours: eventsLast24Hours,
            eventsLast7Days: eventsLast7Days,
            eventsLast30Days: eventsLast30Days,
            threatsByType: threatsByType,
            threatsBySeverity: threatsBySeverity,
            averageRiskScore: averageRiskScore,
            topThreats: Array(threatsByType.keys.prefix(5)),
            securityTrends: securityTrends
        )
    }

    private func updateSecurityMetrics(with event: SecurityEvent) {
        // Update running averages and counters
        // This is a simplified implementation
        totalSecurityEvents += 1
    }

    private func readEventsInDateRange(_ dateRange: ClosedRange<Date>) throws -> [SecurityEvent] {
        // This would read and decrypt events from log files within the date range
        // For now, return events from buffer that match the range
        return eventBuffer.filter { dateRange.contains($0.timestamp) }
    }

    // MARK: - Utility Methods

    private func getCurrentSessionId() -> String {
        // Generate or retrieve current session ID
        return ProcessInfo.processInfo.globallyUniqueString
    }

    // MARK: - Configuration Management

    private func loadConfiguration() {
        isEnabled = UserDefaults.standard.bool(forKey: "SecurityMonitor.Enabled") != false  // Default true
        enableRealTimeAlerts =
            UserDefaults.standard.bool(forKey: "SecurityMonitor.RealTimeAlerts") != false  // Default true
        enableThreatAnalysis =
            UserDefaults.standard.bool(forKey: "SecurityMonitor.ThreatAnalysis") != false  // Default true
        logRetentionDays = UserDefaults.standard.integer(forKey: "SecurityMonitor.RetentionDays")
        if logRetentionDays == 0 { logRetentionDays = 30 }  // Default 30 days

        let maxSize = UserDefaults.standard.object(forKey: "SecurityMonitor.MaxLogSize") as? Int64
        maxLogFileSize = maxSize ?? (10 * 1024 * 1024)  // Default 10MB
    }

    private func loadSecurityMetrics() {
        totalSecurityEvents = UserDefaults.standard.integer(forKey: "SecurityMonitor.TotalEvents")
        totalThreatsBlocked = UserDefaults.standard.integer(
            forKey: "SecurityMonitor.ThreatsBlocked")
        totalDownloadsScanned = UserDefaults.standard.integer(
            forKey: "SecurityMonitor.DownloadsScanned")
        totalQuarantineEvents = UserDefaults.standard.integer(
            forKey: "SecurityMonitor.QuarantineEvents")
        averageRiskScore = UserDefaults.standard.double(forKey: "SecurityMonitor.AverageRiskScore")

        if let lastThreatDate = UserDefaults.standard.object(forKey: "SecurityMonitor.LastThreat")
            as? Date
        {
            lastThreatDetected = lastThreatDate
        }
    }

    private func loadThreatPatterns() {
        // Load default threat patterns
        threatPatterns = [
            // Rapid download pattern
            ThreatPattern(
                id: UUID(),
                name: "Rapid Downloads",
                description: "Multiple downloads in short time period",
                conditions: [
                    ThreatPattern.PatternCondition(
                        field: "eventType", operator: .equals, value: "download_initiated")
                ],
                timeWindow: 300,  // 5 minutes
                threshold: 10,
                severity: .warning,
                isEnabled: true
            ),

            // High-risk file pattern
            ThreatPattern(
                id: UUID(),
                name: "High-Risk Files",
                description: "Multiple high-risk file downloads",
                conditions: [
                    ThreatPattern.PatternCondition(
                        field: "eventType", operator: .equals, value: "threat_detected"),
                    ThreatPattern.PatternCondition(
                        field: "severity", operator: .equals, value: "critical"),
                ],
                timeWindow: 3600,  // 1 hour
                threshold: 3,
                severity: .critical,
                isEnabled: true
            ),
        ]
    }

    func saveConfiguration() {
        UserDefaults.standard.set(isEnabled, forKey: "SecurityMonitor.Enabled")
        UserDefaults.standard.set(enableRealTimeAlerts, forKey: "SecurityMonitor.RealTimeAlerts")
        UserDefaults.standard.set(enableThreatAnalysis, forKey: "SecurityMonitor.ThreatAnalysis")
        UserDefaults.standard.set(logRetentionDays, forKey: "SecurityMonitor.RetentionDays")
        UserDefaults.standard.set(maxLogFileSize, forKey: "SecurityMonitor.MaxLogSize")

        // Save metrics
        UserDefaults.standard.set(totalSecurityEvents, forKey: "SecurityMonitor.TotalEvents")
        UserDefaults.standard.set(totalThreatsBlocked, forKey: "SecurityMonitor.ThreatsBlocked")
        UserDefaults.standard.set(totalDownloadsScanned, forKey: "SecurityMonitor.DownloadsScanned")
        UserDefaults.standard.set(totalQuarantineEvents, forKey: "SecurityMonitor.QuarantineEvents")
        UserDefaults.standard.set(averageRiskScore, forKey: "SecurityMonitor.AverageRiskScore")

        if let lastThreat = lastThreatDetected {
            UserDefaults.standard.set(lastThreat, forKey: "SecurityMonitor.LastThreat")
        }

        logger.info("Security monitor configuration saved")
    }
}

// MARK: - Supporting Types

struct SecurityLogExport: Codable {
    let exportDate: Date
    let dateRange: ClosedRange<Date>
    let events: [SecurityMonitor.SecurityEvent]
    let metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case exportDate, events, metadata, dateRangeStart, dateRangeEnd
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exportDate, forKey: .exportDate)
        try container.encode(dateRange.lowerBound, forKey: .dateRangeStart)
        try container.encode(dateRange.upperBound, forKey: .dateRangeEnd)
        try container.encode(events, forKey: .events)
        try container.encode(metadata, forKey: .metadata)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exportDate = try container.decode(Date.self, forKey: .exportDate)
        let start = try container.decode(Date.self, forKey: .dateRangeStart)
        let end = try container.decode(Date.self, forKey: .dateRangeEnd)
        dateRange = start...end
        events = try container.decode([SecurityMonitor.SecurityEvent].self, forKey: .events)
        metadata = try container.decode([String: String].self, forKey: .metadata)
    }

    init(
        exportDate: Date, dateRange: ClosedRange<Date>, events: [SecurityMonitor.SecurityEvent],
        metadata: [String: String]
    ) {
        self.exportDate = exportDate
        self.dateRange = dateRange
        self.events = events
        self.metadata = metadata
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let securityAlert = Notification.Name("securityAlert")
}

// MARK: - Extensions

extension SecurityMonitor {
    /**
     * Convenience method for logging download-related security events
     */
    func logDownloadSecurityEvent(
        filename: String,
        sourceURL: URL,
        eventType: SecurityEvent.EventType,
        severity: SecurityEvent.Severity,
        details: [String: Any] = [:]
    ) {
        var eventDetails = details
        // Avoid retaining download names or signed URLs in a second history log.
        eventDetails["transport"] = sourceURL.scheme ?? "unknown"

        logSecurityEvent(
            eventType: eventType,
            severity: severity,
            source: "DownloadManager",
            message: eventType.displayName,
            details: eventDetails
        )
    }
}
