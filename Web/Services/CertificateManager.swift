import Foundation
import Security
import WebKit
import SwiftUI

/**
 * CertificateManager
 * 
 * Comprehensive TLS certificate validation and security management service.
 * Handles authentication challenges, certificate pinning, user preferences, and security logging.
 * 
 * Security Features:
 * - Strict certificate validation with user consent for exceptions
 * - Certificate pinning for high-value domains
 * - Comprehensive security logging
 * - User-configurable security policies
 * - Defense against MITM and certificate bypass attacks
 */
class CertificateManager: ObservableObject {
    static let shared = CertificateManager()
    
    // MARK: - Certificate Validation Result
    
    enum CertificateValidationResult: Equatable {
        case valid
        case invalid(CertificateError)
        case requiresUserConsent(CertificateError)
        
        static func == (lhs: CertificateValidationResult, rhs: CertificateValidationResult) -> Bool {
            switch (lhs, rhs) {
            case (.valid, .valid):
                return true
            case (.invalid(let lhsError), .invalid(let rhsError)):
                return lhsError.localizedDescription == rhsError.localizedDescription
            case (.requiresUserConsent(let lhsError), .requiresUserConsent(let rhsError)):
                return lhsError.localizedDescription == rhsError.localizedDescription
            default:
                return false
            }
        }
    }
    
    enum CertificateError: LocalizedError {
        case expired
        case selfSigned
        case hostnameMismatch
        case untrustedRoot
        case revoked
        case weakSignature
        case invalidChain
        case pinningFailure
        case unknown(String)
        
        var errorDescription: String? {
            switch self {
            case .expired:
                return "Certificate has expired"
            case .selfSigned:
                return "Self-signed certificate"
            case .hostnameMismatch:
                return "Certificate hostname doesn't match"
            case .untrustedRoot:
                return "Certificate from untrusted authority"
            case .revoked:
                return "Certificate has been revoked"
            case .weakSignature:
                return "Certificate uses weak signature algorithm"
            case .invalidChain:
                return "Certificate chain is invalid"
            case .pinningFailure:
                return "Certificate pinning validation failed"
            case .unknown(let message):
                return message
            }
        }
        
        var securitySeverity: SecuritySeverity {
            switch self {
            case .expired, .selfSigned, .hostnameMismatch:
                return .high
            case .untrustedRoot, .revoked, .pinningFailure:
                return .critical
            case .weakSignature, .invalidChain:
                return .high
            case .unknown:
                return .medium
            }
        }
    }
    
    enum SecuritySeverity {
        case low, medium, high, critical
        
        var color: Color {
            switch self {
            case .low: return .yellow
            case .medium: return .orange
            case .high: return .red
            case .critical: return .purple
            }
        }
    }
    
    // MARK: - Certificate Pinning
    
    struct CertificatePin {
        let domain: String
        let publicKeyHashes: [String] // SHA-256 hashes of public keys
        let includeSubdomains: Bool
        
        // Browsers trust the system certificate store. Stale sample pins break
        // legitimate certificate rotation and are not a maintained pin set.
        static let defaultPins: [CertificatePin] = []
    }
    
    // MARK: - User Preferences
    
    @Published var securityLevel: SecurityLevel = .standard
    @Published var allowSelfSignedCertificates: Bool = false
    @Published var requirePinningForCriticalSites: Bool = true
    @Published var logSecurityEvents: Bool = false
    
    enum SecurityLevel: String, CaseIterable {
        case paranoid = "Paranoid"
        case strict = "Strict"
        case standard = "Standard"
        case relaxed = "Relaxed"
        
        var description: String {
            switch self {
            case .paranoid:
                return "Maximum security - block all certificate issues"
            case .strict:
                return "High security - allow exceptions with strong warnings"
            case .standard:
                return "Balanced security - allow user choice for certificate issues"
            case .relaxed:
                return "Lower security - allow most certificates with warnings"
            }
        }
        
        var color: Color {
            switch self {
            case .paranoid: return .green
            case .strict: return .blue
            case .standard: return .orange
            case .relaxed: return .red
            }
        }
    }
    
    // MARK: - Internal State
    
    private var certificatePins: [CertificatePin] = CertificatePin.defaultPins
    private var userGrantedExceptions: Set<String> = []
    private let securityLogger = CertificateSecurityLogger()
    
    private init() {
        loadUserPreferences()
    }
    
    // MARK: - Main Certificate Validation Method
    
    /**
     * Validates URLAuthenticationChallenge and returns appropriate action
     * This is the main entry point called from WKNavigationDelegate
     */
    func validateChallenge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Handle non-server-trust challenges (e.g., client certificates, HTTP auth)
            return handleNonServerTrustChallenge(challenge)
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            securityLogger.log(.certificateValidationFailed(host: challenge.protectionSpace.host, error: "No server trust available"))
            return (.cancelAuthenticationChallenge, nil)
        }
        
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        
        securityLogger.log(.certificateValidationStarted(host: host, port: port))
        
        // Perform comprehensive certificate validation
        let validationResult = performCertificateValidation(serverTrust: serverTrust, host: host)
        
        switch validationResult {
        case .valid:
            securityLogger.log(.certificateValidationPassed(host: host))
            return (.useCredential, URLCredential(trust: serverTrust))
            
        case .invalid(let error):
            securityLogger.log(.certificateValidationFailed(host: host, error: error.localizedDescription))
            
            // Invalid system trust or a pin mismatch is never bypassed by a
            // persisted host allowlist, including in the legacy relaxed mode.
            return (.cancelAuthenticationChallenge, nil)
            
        case .requiresUserConsent(let error):
            securityLogger.log(.certificateRequiresUserConsent(host: host, error: error.localizedDescription))
            
            // Show security warning to user (this will be handled by notification)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .showCertificateSecurityWarning,
                    object: nil,
                    userInfo: [
                        "challenge": challenge,
                        "error": error,
                        "host": host,
                        "port": port
                    ]
                )
            }
            
            return (.cancelAuthenticationChallenge, nil)
        }
    }
    
    // MARK: - Certificate Validation Logic
    
    private func performCertificateValidation(serverTrust: SecTrust, host: String) -> CertificateValidationResult {
        
        // Bind evaluation explicitly to the challenged hostname.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(serverTrust, policy) == errSecSuccess else {
            return .invalid(.invalidChain)
        }
        let systemValidationResult = evaluateSystemTrust(serverTrust: serverTrust)
        guard systemValidationResult == .valid else { return systemValidationResult }
        
        // 2. Check certificate pinning for applicable domains
        if let pin = findApplicablePin(for: host) {
            let pinningResult = validateCertificatePinning(serverTrust: serverTrust, pin: pin)
            if case .invalid(let error) = pinningResult {
                return .invalid(error)
            }
        }
        
        // 3. Additional security checks
        let additionalChecks = performAdditionalSecurityChecks(serverTrust: serverTrust, host: host)
        if case .invalid(let error) = additionalChecks {
            return .invalid(error)
        }
        
        // 4. Apply security level policies
        return applySecurityLevelPolicy(systemResult: systemValidationResult, host: host)
    }
    
    private func evaluateSystemTrust(serverTrust: SecTrust) -> CertificateValidationResult {
        var error: CFError?
        let result = SecTrustEvaluateWithError(serverTrust, &error)
        
        if !result {
            if let error = error {
                let errorDescription = CFErrorCopyDescription(error)
                let errorString = errorDescription as String? ?? "Unknown error"
                return .invalid(.unknown("Trust evaluation failed: \(errorString)"))
            } else {
                return .invalid(.unknown("Trust evaluation failed with unknown error"))
            }
        }
        
        // If we reach here, the trust evaluation succeeded
        return .valid
    }
    
    private func validateCertificatePinning(serverTrust: SecTrust, pin: CertificatePin) -> CertificateValidationResult {
        guard requirePinningForCriticalSites else { return .valid }
        
        // Use modern SecTrustCopyCertificateChain instead of deprecated functions
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) else { 
            return .invalid(.pinningFailure)
        }
        
        let certificateCount = CFArrayGetCount(certificateChain)
        
        for i in 0..<certificateCount {
            guard let certificate = CFArrayGetValueAtIndex(certificateChain, i) else { continue }
            let secCertificate = Unmanaged<SecCertificate>.fromOpaque(certificate).takeUnretainedValue()
            
            // Extract public key and calculate SHA-256 hash
            guard let publicKeyHash = extractPublicKeyHash(from: secCertificate) else { continue }
            
            if pin.publicKeyHashes.contains(publicKeyHash) {
                securityLogger.log(.certificatePinningPassed(host: pin.domain))
                return .valid
            }
        }
        
        securityLogger.log(.certificatePinningFailed(host: pin.domain))
        return .invalid(.pinningFailure)
    }
    
    private func performAdditionalSecurityChecks(serverTrust: SecTrust, host: String) -> CertificateValidationResult {
        
        // Check for weak signature algorithms
        if let certificateChain = SecTrustCopyCertificateChain(serverTrust),
           CFArrayGetCount(certificateChain) > 0,
           let certificatePtr = CFArrayGetValueAtIndex(certificateChain, 0) {
            let certificate = Unmanaged<SecCertificate>.fromOpaque(certificatePtr).takeUnretainedValue()
            if isUsingWeakSignature(certificate) {
                return .requiresUserConsent(.weakSignature)
            }
        }
        
        // Additional checks can be added here:
        // - Certificate Transparency validation
        // - OCSP checking
        // - Custom blacklist checking
        
        return .valid
    }
    
    private func applySecurityLevelPolicy(systemResult: CertificateValidationResult, host: String) -> CertificateValidationResult {
        switch securityLevel {
        case .paranoid:
            // Block everything except perfectly valid certificates
            return systemResult == .valid ? .valid : .invalid(.unknown("Paranoid security level"))
            
        case .strict:
            // Allow user consent for recoverable issues only
            switch systemResult {
            case .valid:
                return .valid
            case .requiresUserConsent(let error):
                return error.securitySeverity == .critical ? .invalid(error) : .requiresUserConsent(error)
            case .invalid(let error):
                return .invalid(error)
            }
            
        case .standard:
            // Standard behavior - allow user choice for most issues
            return systemResult
            
        case .relaxed:
            // More permissive - allow most certificates with warnings
            switch systemResult {
            case .valid:
                return .valid
            case .invalid(let error):
                return error.securitySeverity == .critical ? .invalid(error) : .requiresUserConsent(error)
            case .requiresUserConsent(let error):
                return .requiresUserConsent(error)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleNonServerTrustChallenge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Handle client certificate authentication, HTTP basic auth, etc.
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest:
            // Let WebKit handle HTTP authentication
            return (.performDefaultHandling, nil)
            
        case NSURLAuthenticationMethodClientCertificate:
            // Handle client certificate authentication if needed
            securityLogger.log(.clientCertificateRequested(host: challenge.protectionSpace.host))
            return (.performDefaultHandling, nil)
            
        default:
            return (.performDefaultHandling, nil)
        }
    }
    
    private func findApplicablePin(for host: String) -> CertificatePin? {
        for pin in certificatePins {
            if pin.includeSubdomains {
                if host == pin.domain || host.hasSuffix("." + pin.domain) {
                    return pin
                }
            } else {
                if host == pin.domain {
                    return pin
                }
            }
        }
        return nil
    }
    
    private func extractPublicKeyHash(from certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) else { return nil }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(CFDataGetBytePtr(keyData), CC_LONG(CFDataGetLength(keyData)), &hash)
        
        return Data(hash).base64EncodedString()
    }
    
    private func isUsingWeakSignature(_ certificate: SecCertificate) -> Bool {
        // Check for weak signature algorithms (MD5, SHA-1)
        // This is a simplified implementation - production code should do more thorough checking
        let data = SecCertificateCopyData(certificate)
        let certData = CFDataGetBytePtr(data)
        let certLength = CFDataGetLength(data)
        
        // Simple check for MD5 or SHA-1 in the certificate data
        // A proper implementation would parse the ASN.1 structure
        guard let certDataPtr = certData else { return false }
        let certString = String(data: Data(bytes: certDataPtr, count: certLength), encoding: .ascii) ?? ""
        return certString.contains("md5") || certString.contains("sha1")
    }
    
    // MARK: - User Exception Management
    
    func grantException(for host: String, port: Int) {
        let exceptionKey = "\(host):\(port)"
        userGrantedExceptions.insert(exceptionKey)
        saveUserPreferences()
        securityLogger.log(.userGrantedException(host: host))
    }
    
    func revokeException(for host: String, port: Int) {
        let exceptionKey = "\(host):\(port)"
        userGrantedExceptions.remove(exceptionKey)
        saveUserPreferences()
        securityLogger.log(.userRevokedException(host: host))
    }
    
    func hasException(for host: String, port: Int) -> Bool {
        let exceptionKey = "\(host):\(port)"
        return userGrantedExceptions.contains(exceptionKey)
    }
    
    // MARK: - Persistence
    
    private func loadUserPreferences() {
        let defaults = UserDefaults.standard
        
        if let levelString = defaults.string(forKey: "SecurityLevel"),
           let level = SecurityLevel(rawValue: levelString) {
            securityLevel = level
        }
        
        allowSelfSignedCertificates = defaults.bool(forKey: "AllowSelfSignedCertificates")
        requirePinningForCriticalSites = defaults.bool(forKey: "RequirePinningForCriticalSites")
        logSecurityEvents = defaults.bool(forKey: "LogSecurityEvents")
        
        // Old host-only exceptions authorized every future certificate for that
        // host. They are not safe to migrate into a trust decision.
        defaults.removeObject(forKey: "UserGrantedExceptions")
        userGrantedExceptions.removeAll()
        
        if let pinsData = defaults.data(forKey: "CustomCertificatePins"),
           let pins = try? JSONDecoder().decode([CertificatePin].self, from: pinsData) {
            certificatePins = pins
        }
    }
    
    private func saveUserPreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(securityLevel.rawValue, forKey: "SecurityLevel")
        defaults.set(allowSelfSignedCertificates, forKey: "AllowSelfSignedCertificates")
        defaults.set(requirePinningForCriticalSites, forKey: "RequirePinningForCriticalSites")
        defaults.set(logSecurityEvents, forKey: "LogSecurityEvents")
        
        defaults.removeObject(forKey: "UserGrantedExceptions")
        
        if let pinsData = try? JSONEncoder().encode(certificatePins) {
            defaults.set(pinsData, forKey: "CustomCertificatePins")
        }
    }
}

// MARK: - Certificate Pinning Extensions

extension CertificateManager.CertificatePin: Codable {
    enum CodingKeys: String, CodingKey {
        case domain, publicKeyHashes, includeSubdomains
    }
}

// MARK: - Security Logging

private class CertificateSecurityLogger {
    
    func log(_ event: SecurityEvent) {
        guard CertificateManager.shared.logSecurityEvents else { return }
        
        // Hostnames and detailed trust errors can reveal private browsing.
        // Keep the console event free of browsing destinations.
        NSLog("TLS certificate validation event")
        
        // In production, this should also log to a secure audit file
        // or send to a security monitoring system
    }
}

enum SecurityEvent {
    case certificateValidationStarted(host: String, port: Int)
    case certificateValidationPassed(host: String)
    case certificateValidationFailed(host: String, error: String)
    case certificateRequiresUserConsent(host: String, error: String)
    case certificateExceptionUsed(host: String)
    case certificatePinningPassed(host: String)
    case certificatePinningFailed(host: String)
    case userGrantedException(host: String)
    case userRevokedException(host: String)
    case clientCertificateRequested(host: String)
    
    var logMessage: String {
        switch self {
        case .certificateValidationStarted(let host, let port):
            return "Certificate validation started for \(host):\(port)"
        case .certificateValidationPassed(let host):
            return "Certificate validation passed for \(host)"
        case .certificateValidationFailed(let host, let error):
            return "Certificate validation failed for \(host): \(error)"
        case .certificateRequiresUserConsent(let host, let error):
            return "Certificate requires user consent for \(host): \(error)"
        case .certificateExceptionUsed(let host):
            return "User certificate exception used for \(host)"
        case .certificatePinningPassed(let host):
            return "Certificate pinning validation passed for \(host)"
        case .certificatePinningFailed(let host):
            return "Certificate pinning validation FAILED for \(host)"
        case .userGrantedException(let host):
            return "User granted certificate exception for \(host)"
        case .userRevokedException(let host):
            return "User revoked certificate exception for \(host)"
        case .clientCertificateRequested(let host):
            return "Client certificate requested by \(host)"
        }
    }
}


// MARK: - Notification Extensions

extension Notification.Name {
    static let showCertificateSecurityWarning = Notification.Name("showCertificateSecurityWarning")
    static let certificateSecurityWarningDismissed = Notification.Name("certificateSecurityWarningDismissed")
    static let userGrantedCertificateException = Notification.Name("userGrantedCertificateException")
}

// MARK: - CommonCrypto Import

import CommonCrypto