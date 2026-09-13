import Foundation
import OSLog
import WebKit

/// WebKit Security Validator for hardened runtime entitlement justification
///
/// This service validates that WebKit configuration uses minimal necessary permissions
/// and provides runtime verification that JIT entitlements are actually required.
///
/// Security Validation Features:
/// - WebKit configuration security audit
/// - JIT requirement verification
/// - JavaScript execution monitoring
/// - Security policy enforcement
class WebKitSecurityValidator {
    static let shared = WebKitSecurityValidator()

    private let logger = Logger(subsystem: "com.web.browser", category: "WebKitSecurity")

    private init() {}

    // MARK: - WebKit Security Validation

    /// Validates WebKit configuration for security compliance
    /// - Parameter configuration: WKWebViewConfiguration to validate
    /// - Returns: Security validation result with recommendations
    func validateWebKitConfiguration(_ configuration: WKWebViewConfiguration)
        -> WebKitSecurityValidation
    {
        if AppLog.isVerboseEnabled {
            AppLog.debug("Validating WebKit configuration for security compliance")
        }

        var issues: [SecurityIssue] = []
        var recommendations: [String] = []

        // Validate JavaScript execution policy
        validateJavaScriptPolicy(configuration, issues: &issues, recommendations: &recommendations)

        // Validate process pool configuration
        validateProcessPool(configuration, issues: &issues, recommendations: &recommendations)

        // Validate data store configuration
        validateDataStore(configuration, issues: &issues, recommendations: &recommendations)

        // Validate media playback policies
        validateMediaPolicies(configuration, issues: &issues, recommendations: &recommendations)

        // Validate user content controller
        validateUserContentController(
            configuration, issues: &issues, recommendations: &recommendations)

        let overallSecurity = determineSecurityLevel(issues: issues)

        if AppLog.isVerboseEnabled {
            AppLog.debug("WebKit security validation complete: \(overallSecurity.rawValue)")
        }

        return WebKitSecurityValidation(
            securityLevel: overallSecurity,
            issues: issues,
            recommendations: recommendations,
            jitRequired: isJITRequired(),
            complianceStatus: determineComplianceStatus(issues: issues)
        )
    }

    /// WKWebView executes JavaScript outside the app process. This does not
    /// establish whether an independent in-process runtime such as MLX needs JIT.
    func isJITRequired() -> Bool { false }

    /// An in-process JavaScript toggle cannot test a code-signing entitlement.
    func testWebKitWithoutJIT(completion: @escaping (JITTestResult) -> Void) {
        completion(JITTestResult(basicHTMLWorking: false, javascriptWorking: false,
            error: "No entitlement test was performed.",
            recommendation: "Test a separately signed build without allow-jit, including local model inference."))
    }

    // MARK: - Specific Validation Methods

    private func validateJavaScriptPolicy(
        _ config: WKWebViewConfiguration,
        issues: inout [SecurityIssue],
        recommendations: inout [String]
    ) {
        if config.defaultWebpagePreferences.allowsContentJavaScript {
            recommendations.append("Web content JavaScript is enabled in WebKit's content process.")
        }
    }

    private func validateProcessPool(
        _ config: WKWebViewConfiguration,
        issues: inout [SecurityIssue],
        recommendations: inout [String]
    ) {
        // Check if using shared process pool (good for performance, security neutral)
        if config.processPool === WebKitManager.shared.processPool {
            recommendations.append("Using shared process pool - good for memory efficiency")
        }
    }

    private func validateDataStore(
        _ config: WKWebViewConfiguration,
        issues: inout [SecurityIssue],
        recommendations: inout [String]
    ) {
        if config.websiteDataStore.isPersistent {
            recommendations.append("Using persistent data store - normal for regular browsing")
        } else {
            recommendations.append("Using non-persistent data store - good for incognito mode")
        }
    }

    private func validateMediaPolicies(
        _ config: WKWebViewConfiguration,
        issues: inout [SecurityIssue],
        recommendations: inout [String]
    ) {
        let mediaPolicy = config.mediaTypesRequiringUserActionForPlayback

        if mediaPolicy.isEmpty {
            issues.append(
                SecurityIssue(
                    severity: .low,
                    description: "All media types can autoplay - consider restricting for security",
                    component: "Media Policy"
                ))
        } else {
            recommendations.append(
                "Media autoplay restrictions configured - good security practice")
        }
    }

    private func validateUserContentController(
        _ config: WKWebViewConfiguration,
        issues: inout [SecurityIssue],
        recommendations: inout [String]
    ) {
        let userScripts = config.userContentController.userScripts

        if !userScripts.isEmpty {
            issues.append(
                SecurityIssue(
                    severity: .medium,
                    description: "User scripts present - ensure CSP validation is implemented",
                    component: "User Content Controller"
                ))
            recommendations.append("Consider implementing CSP validation for all injected scripts")
        }
    }

    // MARK: - Security Assessment

    private func determineSecurityLevel(issues: [SecurityIssue]) -> SecurityLevel {
        let criticalCount = issues.filter { $0.severity == .critical }.count
        let highCount = issues.filter { $0.severity == .high }.count
        let mediumCount = issues.filter { $0.severity == .medium }.count

        if criticalCount > 0 {
            return .insecure
        } else if highCount > 0 {
            return .vulnerable
        } else if mediumCount > 2 {
            return .acceptable
        } else {
            return .secure
        }
    }

    private func determineComplianceStatus(issues: [SecurityIssue]) -> ComplianceStatus {
        let criticalIssues = issues.filter { $0.severity == .critical || $0.severity == .high }

        if criticalIssues.isEmpty {
            return .compliant
        } else if criticalIssues.count <= 2 {
            return .needsImprovement
        } else {
            return .nonCompliant
        }
    }

    /// Configuration observations are not an entitlement or App Store compliance audit.
    func generateEntitlementJustification() -> String {
        """
        WKWebView uses WebKit's separate content process for page JavaScript.
        Its presence alone does not justify allow-jit in the host application.
        The app retains this entitlement pending a signed build test of local MLX inference.
        Configuration inspection cannot establish sandbox integrity or App Store compliance.
        """
    }

}

// MARK: - Supporting Types

struct WebKitSecurityValidation {
    let securityLevel: SecurityLevel
    let issues: [SecurityIssue]
    let recommendations: [String]
    let jitRequired: Bool
    let complianceStatus: ComplianceStatus
}

struct SecurityIssue {
    let severity: SecuritySeverity
    let description: String
    let component: String

    enum SecuritySeverity {
        case low, medium, high, critical
    }
}

enum SecurityLevel: String {
    case secure = "Secure"
    case acceptable = "Acceptable"
    case vulnerable = "Vulnerable"
    case insecure = "Insecure"
}

enum ComplianceStatus {
    case compliant
    case needsImprovement
    case nonCompliant
}

struct JITTestResult {
    let basicHTMLWorking: Bool
    let javascriptWorking: Bool
    let error: String?
    let recommendation: String
}
