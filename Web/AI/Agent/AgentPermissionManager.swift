import Foundation

/// Automation is withheld until approval is bound to the exact action and page state.
public final class AgentPermissionManager {
    public static let browserAutomationEnabled = false
    public struct Decision {
        public let allowed: Bool
        public let reason: String?
        public init(allowed: Bool, reason: String? = nil) {
            self.allowed = allowed
            self.reason = reason
        }
    }
    public static let shared = AgentPermissionManager()
    private init() {}

    public func evaluate(intent: PageActionType, urlHost: String?) -> Decision {
        switch intent {
        case .findElements, .waitFor, .scroll, .extract, .askUser:
            return Decision(allowed: true)
        case .navigate, .switchTab, .select, .click, .typeText:
            return Decision(allowed: false, reason: "Page automation is unavailable in this release.")
        }
    }
}
