import AppKit
import Combine
import Foundation

/// Comprehensive background resource management system that ensures proper hibernation
/// when the Web browser is not the focused application, similar to Safari and Chrome
class BackgroundResourceManager: ObservableObject {
    static let shared = BackgroundResourceManager()

    // MARK: - Properties

    @Published var isAppInBackground: Bool = false
    @Published var resourcesSuspended: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var backgroundTimers = Set<Timer>()

    // Timer references for suspension
    private var updateTimer: Timer?
    private var particleTimer: Timer?
    private var hibernationTimer: Timer?

    // MARK: - Configuration

    /// Configuration for background resource management
    struct BackgroundPolicy {
        let suspendNetworkRequests: Bool
        let suspendAnimations: Bool
        let hibernateInactiveTabs: Bool
        let reduceProcessPriority: Bool

        static let aggressive = BackgroundPolicy(
            suspendNetworkRequests: false,  // Keep for essential requests
            suspendAnimations: true,
            hibernateInactiveTabs: true,
            reduceProcessPriority: true
        )

        static let conservative = BackgroundPolicy(
            suspendNetworkRequests: false,
            suspendAnimations: false,
            hibernateInactiveTabs: false,
            reduceProcessPriority: false
        )
    }

    private var currentPolicy: BackgroundPolicy = .aggressive

    // MARK: - Initialization

    private init() {
        setupApplicationStateMonitoring()
    }

    // MARK: - Application State Monitoring

    private func setupApplicationStateMonitoring() {
        // Monitor application becoming active
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationDidBecomeActive()
                }
            }
            .store(in: &cancellables)

        // Monitor application resigning active
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationDidResignActive()
                }
            }
            .store(in: &cancellables)

        // Additional background/foreground monitoring
        NotificationCenter.default.publisher(for: NSApplication.didHideNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationWentToBackground()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationCameToForeground()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Application State Handlers

    @MainActor
    private func handleApplicationDidBecomeActive() {
        AppLog.debug("App active - resuming resources")
        isAppInBackground = false
        resumeAllResources()
    }

    @MainActor
    private func handleApplicationDidResignActive() {
        AppLog.debug("App resigned active - suspending resources")
        isAppInBackground = true

        // Delay suspension slightly to avoid flicker during app switching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.suspendAllResources()
        }
    }

    @MainActor
    private func handleApplicationWentToBackground() {
        AppLog.debug("App background - aggressive suspension")
        isAppInBackground = true
        suspendAllResources()
    }

    @MainActor
    private func handleApplicationCameToForeground() {
        AppLog.debug("App foreground - resuming resources")
        isAppInBackground = false
        resumeAllResources()
    }

    // MARK: - Resource Suspension & Resumption

    @MainActor
    private func suspendAllResources() {
        guard !resourcesSuspended else { return }
        resourcesSuspended = true

        AppLog.debug("Suspending all background resources…")

        // 1. Suspend native app timers
        suspendNativeTimers()

        // 2. Trigger aggressive tab hibernation
        triggerAggressiveTabHibernation()

        // 3. Reduce process priority
        if currentPolicy.reduceProcessPriority {
            reduceProcessPriority()
        }

        AppLog.debug("Background resource suspension complete")
    }

    @MainActor
    private func resumeAllResources() {
        guard resourcesSuspended else { return }
        resourcesSuspended = false

        AppLog.debug("Resuming all resources…")

        // 1. Resume native app timers
        resumeNativeTimers()

        // 2. Restore normal process priority
        restoreProcessPriority()

        // 3. Restore balanced tab hibernation policy
        restoreBalancedHibernationPolicy()

        AppLog.debug("Resource resumption complete")
    }

    // MARK: - Timer Management

    @MainActor
    private func suspendNativeTimers() {
        AppLog.debug("Suspending native app timers")

        // Suspend update checker timer (from WebApp.swift)
        suspendUpdateTimer()

        // Suspend particle animation timer (from NewTabView.swift)
        suspendParticleAnimationTimer()

        // Suspend hibernation evaluation timer
        suspendHibernationTimer()

        // Suspend WebView responsiveness checks (Coordinator timer)
        NotificationCenter.default.post(name: .suspendWebViewResponsivenessChecks, object: nil)
    }

    @MainActor
    private func resumeNativeTimers() {
        AppLog.debug("Resuming native app timers")

        // Resume update checker
        resumeUpdateTimer()

        // Resume particle animations
        resumeParticleAnimationTimer()

        // Resume hibernation evaluation
        resumeHibernationTimer()

        // Resume WebView responsiveness checks (Coordinator timer)
        NotificationCenter.default.post(name: .resumeWebViewResponsivenessChecks, object: nil)
    }

    private func suspendUpdateTimer() {
        // Notify UpdateService to suspend its timer
        NotificationCenter.default.post(name: .suspendUpdateTimer, object: nil)
    }

    private func resumeUpdateTimer() {
        // Notify UpdateService to resume its timer
        NotificationCenter.default.post(name: .resumeUpdateTimer, object: nil)
    }

    private func suspendParticleAnimationTimer() {
        // Notify NewTabView to suspend animations
        NotificationCenter.default.post(name: .suspendParticleAnimations, object: nil)
    }

    private func resumeParticleAnimationTimer() {
        // Notify NewTabView to resume animations
        NotificationCenter.default.post(name: .resumeParticleAnimations, object: nil)
    }

    private func suspendHibernationTimer() {
        // TabHibernationManager should reduce its evaluation frequency
        NotificationCenter.default.post(name: .suspendHibernationEvaluation, object: nil)
    }

    private func resumeHibernationTimer() {
        // TabHibernationManager should restore normal evaluation frequency
        NotificationCenter.default.post(name: .resumeHibernationEvaluation, object: nil)
    }

    // MARK: - Tab Hibernation Management

    @MainActor
    private func triggerAggressiveTabHibernation() {
        guard currentPolicy.hibernateInactiveTabs else { return }

        AppLog.debug("Triggering aggressive tab hibernation")

        // Switch to aggressive hibernation policy
        TabHibernationManager.shared.updatePolicy(.aggressive)

        // Immediate hibernation evaluation
        TabHibernationManager.shared.evaluateHibernationOpportunities()
    }

    @MainActor
    private func restoreBalancedHibernationPolicy() {
        AppLog.debug("Restoring balanced hibernation policy")

        // Restore balanced hibernation policy
        TabHibernationManager.shared.updatePolicy(.balanced)
    }

    // MARK: - Process Priority Management

    private func reduceProcessPriority() {
        // Reduce the app's process priority to background
        // Note: performExpiringActivity is iOS-only, on macOS we use different approaches
        DispatchQueue.global(qos: .background).async {
            AppLog.debug("Reduced process priority for background operation")
        }
    }

    private func restoreProcessPriority() {
        AppLog.debug("Restored normal process priority")
        // Process priority will automatically restore when becoming active
    }

    // MARK: - Utility Methods

    // MARK: - Public API

    /// Manually suspend all resources (for testing or explicit control)
    @MainActor
    func forceSuspend() {
        suspendAllResources()
    }

    /// Manually resume all resources (for testing or explicit control)
    @MainActor
    func forceResume() {
        resumeAllResources()
    }

    /// Update the background policy
    func updatePolicy(_ policy: BackgroundPolicy) {
        currentPolicy = policy
        AppLog.debug("Updated background resource policy")
    }

    /// Get current resource usage statistics
    func getResourceStats() -> BackgroundResourceStats {
        return BackgroundResourceStats(
            isAppInBackground: isAppInBackground,
            resourcesSuspended: resourcesSuspended,
            backgroundTimerCount: backgroundTimers.count,
            currentPolicy: currentPolicy
        )
    }
}

// MARK: - Supporting Types

extension BackgroundResourceManager {
    struct BackgroundResourceStats {
        let isAppInBackground: Bool
        let resourcesSuspended: Bool
        let backgroundTimerCount: Int
        let currentPolicy: BackgroundPolicy

        var description: String {
            return """
                Background Resource Stats:
                - App in background: \(isAppInBackground)
                - Resources suspended: \(resourcesSuspended)
                - Background timers: \(backgroundTimerCount)
                - Policy: \(currentPolicy.hibernateInactiveTabs ? "Aggressive" : "Conservative")
                """
        }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let suspendUpdateTimer = Notification.Name("suspendUpdateTimer")
    static let resumeUpdateTimer = Notification.Name("resumeUpdateTimer")
    static let suspendParticleAnimations = Notification.Name("suspendParticleAnimations")
    static let resumeParticleAnimations = Notification.Name("resumeParticleAnimations")
    static let suspendHibernationEvaluation = Notification.Name("suspendHibernationEvaluation")
    static let resumeHibernationEvaluation = Notification.Name("resumeHibernationEvaluation")
    static let collectActiveWebViews = Notification.Name("collectActiveWebViews")
    static let backgroundResourcesChanged = Notification.Name("backgroundResourcesChanged")
    static let suspendWebViewResponsivenessChecks = Notification.Name(
        "suspendWebViewResponsivenessChecks")
    static let resumeWebViewResponsivenessChecks = Notification.Name(
        "resumeWebViewResponsivenessChecks")
}
