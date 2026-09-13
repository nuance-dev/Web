import Foundation
import os.log

/// SecurityMonitor+Authentication: Comprehensive authentication security logging
///
/// This extension adds authentication-specific security event types and logging methods
/// to the existing SecurityMonitor infrastructure. It provides comprehensive audit trails
/// for all JWT/OAuth authentication events, token management, and security violations.
///
/// Security Features:
/// - Authentication-specific event types and classifications
/// - JWT token validation event logging with security context
/// - OAuth flow security monitoring and anomaly detection
/// - Token lifecycle event tracking with detailed metadata
/// - Session management security logging
/// - Biometric authentication event tracking
/// - Integration with existing SecurityMonitor infrastructure
@MainActor
extension SecurityMonitor {
    
    // MARK: - Authentication Event Types
    
    /// Authentication-specific security event types
    enum AuthEventType: String, Codable {
        // Token Management Events
        case tokenStored = "auth_token_stored"
        case tokenRetrieved = "auth_token_retrieved"
        case tokenDeleted = "auth_token_deleted"
        case tokenRefreshed = "auth_token_refreshed"
        case tokenExpired = "auth_token_expired"
        case tokenRevoked = "auth_token_revoked"
        case tokenCleanup = "auth_token_cleanup"
        
        // JWT Validation Events
        case jwtValidationStarted = "jwt_validation_started"
        case jwtValidationSucceeded = "jwt_validation_succeeded"
        case jwtValidationFailed = "jwt_validation_failed"
        case jwtSignatureVerified = "jwt_signature_verified"
        case jwtSignatureInvalid = "jwt_signature_invalid"
        case jwtClaimsValidated = "jwt_claims_validated"
        case jwtClaimsInvalid = "jwt_claims_invalid"
        
        // OAuth Flow Events
        case oauthFlowStarted = "oauth_flow_started"
        case oauthFlowCompleted = "oauth_flow_completed"
        case oauthFlowFailed = "oauth_flow_failed"
        case oauthCallbackReceived = "oauth_callback_received"
        case oauthStateValidated = "oauth_state_validated"
        case oauthStateInvalid = "oauth_state_invalid"
        case oauthPkceGenerated = "oauth_pkce_generated"
        case oauthPkceValidated = "oauth_pkce_validated"
        case oauthTokenExchange = "oauth_token_exchange"
        
        // Authentication State Events
        case authenticationStarted = "authentication_started"
        case authenticationSucceeded = "authentication_succeeded"
        case authenticationFailed = "authentication_failed"
        case authenticationStateChanged = "auth_state_changed"
        case sessionCreated = "auth_session_created"
        case sessionDestroyed = "auth_session_destroyed"
        case sessionExpired = "auth_session_expired"
        case sessionRefreshed = "auth_session_refreshed"
        
        // Biometric Authentication Events
        case biometricAuthRequested = "biometric_auth_requested"
        case biometricAuthSucceeded = "biometric_auth_succeeded"
        case biometricAuthFailed = "biometric_auth_failed"
        case biometricAuthUnavailable = "biometric_auth_unavailable"
        
        // Security Violation Events
        case authReplayAttack = "auth_replay_attack_detected"
        case authBruteForce = "auth_brute_force_detected"
        case authTokenTheft = "auth_token_theft_suspected"
        case authUnauthorizedAccess = "auth_unauthorized_access"
        case authSuspiciousActivity = "auth_suspicious_activity"
        case authSecurityPolicyViolation = "auth_security_policy_violation"
        
        // System Events
        case authSystemInit = "auth_system_initialized"
        case authKeyGeneration = "auth_key_generated"
        case authKeyRotation = "auth_key_rotated"
        case authConfigurationChanged = "auth_configuration_changed"
        
        var displayName: String {
            switch self {
            // Token Management
            case .tokenStored: return "Token Stored"
            case .tokenRetrieved: return "Token Retrieved"
            case .tokenDeleted: return "Token Deleted"
            case .tokenRefreshed: return "Token Refreshed"
            case .tokenExpired: return "Token Expired"
            case .tokenRevoked: return "Token Revoked"
            case .tokenCleanup: return "Token Cleanup"
            
            // JWT Validation
            case .jwtValidationStarted: return "JWT Validation Started"
            case .jwtValidationSucceeded: return "JWT Validation Succeeded"
            case .jwtValidationFailed: return "JWT Validation Failed"
            case .jwtSignatureVerified: return "JWT Signature Verified"
            case .jwtSignatureInvalid: return "JWT Signature Invalid"
            case .jwtClaimsValidated: return "JWT Claims Validated"
            case .jwtClaimsInvalid: return "JWT Claims Invalid"
            
            // OAuth Flow
            case .oauthFlowStarted: return "OAuth Flow Started"
            case .oauthFlowCompleted: return "OAuth Flow Completed"
            case .oauthFlowFailed: return "OAuth Flow Failed"
            case .oauthCallbackReceived: return "OAuth Callback Received"
            case .oauthStateValidated: return "OAuth State Validated"
            case .oauthStateInvalid: return "OAuth State Invalid"
            case .oauthPkceGenerated: return "OAuth PKCE Generated"
            case .oauthPkceValidated: return "OAuth PKCE Validated"
            case .oauthTokenExchange: return "OAuth Token Exchange"
            
            // Authentication State
            case .authenticationStarted: return "Authentication Started"
            case .authenticationSucceeded: return "Authentication Succeeded"
            case .authenticationFailed: return "Authentication Failed"
            case .authenticationStateChanged: return "Authentication State Changed"
            case .sessionCreated: return "Session Created"
            case .sessionDestroyed: return "Session Destroyed"
            case .sessionExpired: return "Session Expired"
            case .sessionRefreshed: return "Session Refreshed"
            
            // Biometric Authentication
            case .biometricAuthRequested: return "Biometric Auth Requested"
            case .biometricAuthSucceeded: return "Biometric Auth Succeeded"
            case .biometricAuthFailed: return "Biometric Auth Failed"
            case .biometricAuthUnavailable: return "Biometric Auth Unavailable"
            
            // Security Violations
            case .authReplayAttack: return "Replay Attack Detected"
            case .authBruteForce: return "Brute Force Attack Detected"
            case .authTokenTheft: return "Token Theft Suspected"
            case .authUnauthorizedAccess: return "Unauthorized Access"
            case .authSuspiciousActivity: return "Suspicious Activity"
            case .authSecurityPolicyViolation: return "Security Policy Violation"
            
            // System Events
            case .authSystemInit: return "Auth System Initialized"
            case .authKeyGeneration: return "Auth Key Generated"
            case .authKeyRotation: return "Auth Key Rotated"
            case .authConfigurationChanged: return "Auth Configuration Changed"
            }
        }
        
        var suggestedSeverity: SecurityEvent.Severity {
            switch self {
            // Info level events
            case .tokenStored, .tokenRetrieved, .tokenRefreshed, .tokenCleanup,
                 .jwtValidationStarted, .jwtValidationSucceeded, .jwtSignatureVerified, .jwtClaimsValidated,
                 .oauthFlowStarted, .oauthFlowCompleted, .oauthCallbackReceived, .oauthStateValidated, .oauthPkceGenerated, .oauthPkceValidated, .oauthTokenExchange,
                 .authenticationStarted, .authenticationSucceeded, .sessionCreated, .sessionRefreshed,
                 .biometricAuthRequested, .biometricAuthSucceeded,
                 .authSystemInit, .authKeyGeneration:
                return .info
                
            // Warning level events
            case .tokenExpired, .sessionExpired, .sessionDestroyed,
                 .biometricAuthUnavailable, .authConfigurationChanged, .authKeyRotation:
                return .warning
                
            // Error level events
            case .tokenDeleted, .tokenRevoked,
                 .jwtValidationFailed, .jwtSignatureInvalid, .jwtClaimsInvalid,
                 .oauthFlowFailed, .oauthStateInvalid,
                 .authenticationFailed, .authenticationStateChanged,
                 .biometricAuthFailed:
                return .error
                
            // Critical level events
            case .authReplayAttack, .authBruteForce, .authTokenTheft, .authUnauthorizedAccess,
                 .authSuspiciousActivity, .authSecurityPolicyViolation:
                return .critical
            }
        }
    }
    
    // MARK: - Authentication Security Logging Methods
    
    /// Logs authentication-specific security events with enhanced context
    func logAuthenticationEvent(
        eventType: AuthEventType,
        severity: SecurityEvent.Severity? = nil,
        userId: String? = nil,
        provider: String? = nil,
        message: String? = nil,
        details: [String: Any] = [:]
    ) {
        let actualSeverity = severity ?? eventType.suggestedSeverity
        let eventMessage = message ?? eventType.displayName
        
        var enhancedDetails = details
        
        // Add authentication-specific context
        if let userId = userId {
            enhancedDetails["user_id"] = userId
        }
        
        if let provider = provider {
            enhancedDetails["auth_provider"] = provider
        }
        
        // Add security context
        enhancedDetails["auth_event_type"] = eventType.rawValue
        enhancedDetails["timestamp"] = ISO8601DateFormatter().string(from: Date())
        enhancedDetails["process_id"] = ProcessInfo.processInfo.processIdentifier
        enhancedDetails["thread_id"] = Thread.current.description.hash
        
        // Add device/app context
        enhancedDetails["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        enhancedDetails["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        
        logSecurityEvent(
            eventType: .suspiciousActivity, // Map to existing SecurityEvent.EventType
            severity: actualSeverity,
            source: "AuthenticationServices",
            message: eventMessage,
            details: enhancedDetails
        )
    }
    
    // MARK: - Token Management Logging
    
    /// Logs token storage events with security metadata
    func logTokenEvent(
        eventType: AuthEventType,
        tokenType: String,
        provider: String,
        identifier: String,
        hasRefreshToken: Bool = false,
        expiresIn: TimeInterval? = nil,
        success: Bool = true,
        error: String? = nil
    ) {
        var details: [String: Any] = [
            "token_type": tokenType,
            "auth_provider": provider,
            "identifier": identifier,
            "has_refresh_token": hasRefreshToken,
            "operation_success": success
        ]
        
        if let expiresIn = expiresIn {
            details["expires_in_seconds"] = expiresIn
            details["expires_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))
        }
        
        if let error = error {
            details["error_message"] = error
        }
        
        let severity: SecurityEvent.Severity = success ? eventType.suggestedSeverity : .error
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: severity,
            userId: identifier,
            provider: provider,
            details: details
        )
    }
    
    // MARK: - JWT Validation Logging
    
    /// Logs JWT validation events with detailed security context
    func logJWTValidationEvent(
        eventType: AuthEventType,
        algorithm: String? = nil,
        issuer: String? = nil,
        subject: String? = nil,
        audience: String? = nil,
        expiresAt: Date? = nil,
        issuedAt: Date? = nil,
        validationResult: Bool = true,
        error: String? = nil
    ) {
        var details: [String: Any] = [
            "validation_result": validationResult
        ]
        
        if let algorithm = algorithm {
            details["jwt_algorithm"] = algorithm
        }
        
        if let issuer = issuer {
            details["jwt_issuer"] = issuer
        }
        
        if let subject = subject {
            details["jwt_subject"] = subject
        }
        
        if let audience = audience {
            details["jwt_audience"] = audience
        }
        
        if let expiresAt = expiresAt {
            details["jwt_expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
            details["jwt_is_expired"] = Date() >= expiresAt
        }
        
        if let issuedAt = issuedAt {
            details["jwt_issued_at"] = ISO8601DateFormatter().string(from: issuedAt)
            details["jwt_age_seconds"] = Date().timeIntervalSince(issuedAt)
        }
        
        if let error = error {
            details["validation_error"] = error
        }
        
        let severity: SecurityEvent.Severity = validationResult ? eventType.suggestedSeverity : .error
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: severity,
            userId: subject,
            details: details
        )
    }
    
    // MARK: - OAuth Flow Logging
    
    /// Logs OAuth flow events with comprehensive security tracking
    func logOAuthEvent(
        eventType: AuthEventType,
        provider: String,
        responseType: String? = nil,
        hasPKCE: Bool = false,
        state: String? = nil,
        redirectUri: String? = nil,
        scope: String? = nil,
        success: Bool = true,
        error: String? = nil
    ) {
        var details: [String: Any] = [
            "oauth_provider": provider,
            "has_pkce": hasPKCE,
            "flow_success": success
        ]
        
        if let responseType = responseType {
            details["response_type"] = responseType
        }
        
        if let state = state {
            // Log only hash of state for security (don't log actual state)
            details["state_hash"] = String(state.hashValue)
        }
        
        if let redirectUri = redirectUri {
            details["redirect_uri"] = redirectUri
        }
        
        if let scope = scope {
            details["oauth_scope"] = scope
        }
        
        if let error = error {
            details["oauth_error"] = error
        }
        
        let severity: SecurityEvent.Severity = success ? eventType.suggestedSeverity : .error
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: severity,
            provider: provider,
            details: details
        )
    }
    
    // MARK: - Session Management Logging
    
    /// Logs authentication session events
    func logSessionEvent(
        eventType: AuthEventType,
        sessionId: String,
        userId: String,
        provider: String,
        deviceFingerprint: String? = nil,
        sessionDuration: TimeInterval? = nil,
        success: Bool = true,
        reason: String? = nil
    ) {
        var details: [String: Any] = [
            "session_id": sessionId,
            "auth_provider": provider,
            "operation_success": success
        ]
        
        if let deviceFingerprint = deviceFingerprint {
            details["device_fingerprint"] = deviceFingerprint
        }
        
        if let sessionDuration = sessionDuration {
            details["session_duration_seconds"] = sessionDuration
            details["session_duration_formatted"] = formatDuration(sessionDuration)
        }
        
        if let reason = reason {
            details["operation_reason"] = reason
        }
        
        let severity: SecurityEvent.Severity = success ? eventType.suggestedSeverity : .error
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: severity,
            userId: userId,
            provider: provider,
            details: details
        )
    }
    
    // MARK: - Biometric Authentication Logging
    
    /// Logs biometric authentication events with privacy protection
    func logBiometricEvent(
        eventType: AuthEventType,
        biometricType: String? = nil,
        success: Bool = true,
        error: String? = nil,
        context: String? = nil
    ) {
        var details: [String: Any] = [
            "biometric_result": success
        ]
        
        if let biometricType = biometricType {
            details["biometric_type"] = biometricType
        }
        
        if let error = error {
            details["biometric_error"] = error
        }
        
        if let context = context {
            details["auth_context"] = context
        }
        
        // Add device biometric capabilities (without personal data)
        details["biometrics_available"] = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        
        let severity: SecurityEvent.Severity = success ? eventType.suggestedSeverity : .warning
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: severity,
            details: details
        )
    }
    
    // MARK: - Security Violation Logging
    
    /// Logs authentication security violations with enhanced threat context
    func logSecurityViolation(
        eventType: AuthEventType,
        threatLevel: SecurityEvent.Severity,
        attackVector: String? = nil,
        sourceIP: String? = nil,
        userAgent: String? = nil,
        details: [String: Any] = [:]
    ) {
        var enhancedDetails = details
        enhancedDetails["threat_level"] = threatLevel.rawValue
        
        if let attackVector = attackVector {
            enhancedDetails["attack_vector"] = attackVector
        }
        
        if let sourceIP = sourceIP {
            enhancedDetails["source_ip"] = sourceIP
        }
        
        if let userAgent = userAgent {
            enhancedDetails["user_agent"] = userAgent
        }
        
        // Add system defense information
        enhancedDetails["defense_active"] = isEnabled
        enhancedDetails["threat_analysis_enabled"] = enableThreatAnalysis
        enhancedDetails["real_time_alerts_enabled"] = enableRealTimeAlerts
        
        logAuthenticationEvent(
            eventType: eventType,
            severity: threatLevel,
            details: enhancedDetails
        )
        
        // Trigger immediate threat analysis for critical violations
        if threatLevel >= .error {
            triggerImmediateThreatAnalysis(eventType: eventType, details: enhancedDetails)
        }
    }
    
    // MARK: - Authentication Metrics
    
    /// Gets authentication-specific security metrics
    func getAuthenticationMetrics() async -> AuthenticationSecurityMetrics {
        let allEvents = getRecentEvents(limit: 1000)
        let authEvents = allEvents.filter { event in
            event.source == "AuthenticationServices" || 
            event.details["auth_event_type"] != nil
        }
        
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        
        let authEventsLast24Hours = authEvents.filter { $0.timestamp > oneDayAgo }
        let authEventsLast7Days = authEvents.filter { $0.timestamp > sevenDaysAgo }
        
        var authEventsByType: [String: Int] = [:]
        var securityViolations: [String: Int] = [:]
        var tokenEvents: [String: Int] = [:]
        
        for event in authEvents {
            if let authEventType = event.details["auth_event_type"] {
                authEventsByType[authEventType, default: 0] += 1
                
                // Categorize security violations
                if authEventType.contains("violation") || authEventType.contains("attack") || authEventType.contains("suspicious") {
                    securityViolations[authEventType, default: 0] += 1
                }
                
                // Categorize token events
                if authEventType.contains("token") {
                    tokenEvents[authEventType, default: 0] += 1
                }
            }
        }
        
        // Calculate authentication success rate
        let authAttempts = authEvents.filter { 
            $0.details["auth_event_type"]?.contains("authentication_started") == true ||
            $0.details["auth_event_type"]?.contains("authentication_succeeded") == true ||
            $0.details["auth_event_type"]?.contains("authentication_failed") == true
        }
        
        let successfulAuths = authEvents.filter { 
            $0.details["auth_event_type"]?.contains("authentication_succeeded") == true 
        }
        
        let authSuccessRate = authAttempts.isEmpty ? 1.0 : Double(successfulAuths.count) / Double(authAttempts.count)
        
        return AuthenticationSecurityMetrics(
            totalAuthEvents: authEvents.count,
            authEventsLast24Hours: authEventsLast24Hours.count,
            authEventsLast7Days: authEventsLast7Days.count,
            authEventsByType: authEventsByType,
            securityViolations: securityViolations,
            tokenEvents: tokenEvents,
            authSuccessRate: authSuccessRate,
            activeTokens: 0, // Would be populated from TokenManager
            activeSessions: 0, // Would be populated from AuthStateManager
            lastSecurityViolation: authEvents.last(where: { $0.severity >= .error })?.timestamp
        )
    }
    
    // MARK: - Private Helper Methods
    
    private func triggerImmediateThreatAnalysis(eventType: AuthEventType, details: [String: Any]) {
        // This would trigger immediate threat analysis for critical auth violations
        analysisQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Log the immediate threat analysis trigger
            self.logger.critical("Immediate threat analysis triggered for authentication event: \(eventType.rawValue)")
            
            // In a production system, this would:
            // 1. Alert security team
            // 2. Potentially block IP addresses
            // 3. Escalate to incident response system
            // 4. Trigger additional monitoring
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration.truncatingRemainder(dividingBy: 3600)) / 60
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Authentication Security Metrics

/// Authentication-specific security metrics
struct AuthenticationSecurityMetrics: Codable {
    let totalAuthEvents: Int
    let authEventsLast24Hours: Int
    let authEventsLast7Days: Int
    let authEventsByType: [String: Int]
    let securityViolations: [String: Int]
    let tokenEvents: [String: Int]
    let authSuccessRate: Double
    let activeTokens: Int
    let activeSessions: Int
    let lastSecurityViolation: Date?
    
    var hasRecentViolations: Bool {
        guard let lastViolation = lastSecurityViolation else { return false }
        return Date().timeIntervalSince(lastViolation) < 3600 // Within last hour
    }
    
    var violationTrend: SecurityTrend {
        let totalViolations = securityViolations.values.reduce(0, +)
        if totalViolations == 0 { return .stable }
        if totalViolations > 5 { return .increasing }
        return .stable
    }
    
    enum SecurityTrend: String, Codable {
        case decreasing = "decreasing"
        case stable = "stable"
        case increasing = "increasing"
    }
}

// MARK: - Import Required for LocalAuthentication

import LocalAuthentication