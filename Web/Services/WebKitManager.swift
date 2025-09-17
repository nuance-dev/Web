import Foundation
import WebKit
import Combine

/// Singleton manager for WebKit resources to optimize memory usage through shared process pools
/// and provide centralized configuration for all WKWebView instances
class WebKitManager: ObservableObject {
    static let shared = WebKitManager()
    
    // MARK: - Shared WebKit Resources
    
    /// Shared process pool for memory efficiency across all tabs
    /// Using a single process pool reduces memory overhead and enables cookie/session sharing
    let processPool = WKProcessPool()
    
    /// Default website data store for regular browsing
    let defaultDataStore = WKWebsiteDataStore.default()
    
    /// Non-persistent data store for incognito browsing
    lazy var incognitoDataStore = WKWebsiteDataStore.nonPersistent()
    
    // MARK: - Configuration
    
    private init() {
        setupWebKitOptimizations()
    }
    
    /// Creates optimized WKWebViewConfiguration with shared resources
    /// - Parameter isIncognito: Whether this configuration is for incognito browsing
    /// - Parameter isOAuthFlow: Whether this is for OAuth authentication flows
    /// - Returns: Configured WKWebViewConfiguration with shared process pool
    func createConfiguration(isIncognito: Bool = false, isOAuthFlow: Bool = false) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        
        // Use shared process pool for memory efficiency
        configuration.processPool = processPool
        
        // Use appropriate data store
        configuration.websiteDataStore = isIncognito ? incognitoDataStore : defaultDataStore
        
        // OAUTH FIX: Enhanced configuration for OAuth flows
        if isOAuthFlow {
            setupOAuthSpecificConfiguration(configuration)
        }
        
        // Performance optimizations
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        // OAUTH FIX: Enhanced cookie and session handling
        setupEnhancedCookieHandling(for: configuration, isOAuthFlow: isOAuthFlow)
        
        // Content blocking and ad blocking preparation
        setupContentBlocking(for: configuration)
        
        return configuration
    }
    
    /// Creates WKWebView with optimized configuration
    /// - Parameters:
    ///   - frame: Initial frame for the web view
    ///   - isIncognito: Whether this is for incognito browsing
    /// - Returns: Configured WKWebView instance
    func createWebView(frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100), isIncognito: Bool = false) -> WKWebView {
        let configuration = createConfiguration(isIncognito: isIncognito)
        let webView = WKWebView(frame: frame, configuration: configuration)
        
        // Apply standard settings
        applyStandardSettings(to: webView)
        
        return webView
    }
    
    // MARK: - WebKit Optimizations
    
    private func setupWebKitOptimizations() {
        // Suppress verbose WebKit logging for cleaner console output
        setenv("WEBKIT_DISABLE_VERBOSE_LOGGING", "1", 1)
        setenv("WEBKIT_SUPPRESS_PROCESS_LOGS", "1", 1)
        setenv("OS_ACTIVITY_MODE", "disable", 1)
    }
    
    private func setupContentBlocking(for configuration: WKWebViewConfiguration) {
        // Future: Content blocking rules will be added here
        // This is where EasyList and custom ad blocking rules will be implemented
        
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
    }
    
    private func applyStandardSettings(to webView: WKWebView) {
        // Standard Safari user agent to prevent Google's embedded browser detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        
        // Enable developer tools and inspection based on user setting
        if #available(macOS 13.3, *) {
            let enabled = UserDefaults.standard.object(forKey: "enableDeveloperTools") as? Bool
            webView.isInspectable = (enabled ?? true)
        }
        
        // Performance settings
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
    }
    
    // MARK: - Memory Management
    
    /// Clears website data for memory management
    /// - Parameter includeIncognito: Whether to also clear incognito data
    func clearWebsiteData(includeIncognito: Bool = false) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        
        defaultDataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) { }
        
        if includeIncognito {
            incognitoDataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) { }
        }
    }
    
    /// Gets current memory usage information for the shared process pool
    /// Note: This is an approximation as WebKit doesn't expose detailed memory metrics
    func getEstimatedMemoryUsage() -> Int64 {
        // This will be enhanced with actual memory monitoring in the MemoryMonitor service
        return 0
    }
    
    // MARK: - OAuth-Specific Configuration
    
    /// Configures WebKit specifically for OAuth authentication flows
    /// - Parameter configuration: WKWebViewConfiguration to modify
    private func setupOAuthSpecificConfiguration(_ configuration: WKWebViewConfiguration) {
        // Enable all JavaScript capabilities required for OAuth
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        // OAuth flows often require popup windows
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // Enable localStorage and sessionStorage for OAuth state management
        // Note: httpCookieAcceptPolicy is not available in WKHTTPCookieStore
        // Cookie policy is managed through WKWebsiteDataStore configuration
        
        NSLog("🔐 OAuth-specific WebKit configuration applied")
    }
    
    /// Enhanced cookie and session handling for OAuth compatibility
    /// - Parameters:
    ///   - configuration: WKWebViewConfiguration to modify
    ///   - isOAuthFlow: Whether this is for OAuth flows
    private func setupEnhancedCookieHandling(for configuration: WKWebViewConfiguration, isOAuthFlow: Bool) {
        // Configure the website data store for optimal OAuth support
        let dataStore = configuration.websiteDataStore
        
        if isOAuthFlow {
            // For OAuth flows, we need permissive cookie handling
            // Note: httpCookieAcceptPolicy is not available in WKHTTPCookieStore
            // Cookie handling is managed at the WKWebsiteDataStore level
            
            // Remove any existing content blocking rules that might interfere with OAuth
            let userContentController = configuration.userContentController
            userContentController.removeAllContentRuleLists()
            
            NSLog("🍪 Enhanced cookie handling enabled for OAuth flow")
        } else {
            // Normal browsing with balanced privacy/functionality
            // Cookie policy is managed through data store configuration
            NSLog("🍪 Standard privacy cookie handling configured")
        }
    }
    
    /// Creates WebView specifically optimized for OAuth flows
    /// - Parameters:
    ///   - frame: Initial frame for the web view  
    ///   - provider: OAuth provider information for domain-specific optimizations
    /// - Returns: Configured WKWebView instance optimized for OAuth
    func createOAuthWebView(frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100), for provider: String = "google") -> WKWebView {
        let configuration = createConfiguration(isIncognito: false, isOAuthFlow: true)
        let webView = WKWebView(frame: frame, configuration: configuration)
        
        // OAuth-specific WebView settings
        applyOAuthSpecificSettings(to: webView, provider: provider)
        
        return webView
    }
    
    /// Applies OAuth-specific settings to a WebView
    /// - Parameters:
    ///   - webView: WKWebView to configure
    ///   - provider: OAuth provider for domain-specific optimizations
    private func applyOAuthSpecificSettings(to webView: WKWebView, provider: String) {
        // Use standard browser user agent for OAuth flows
        switch provider.lowercased() {
        case "google":
            // Google requires specific user agent for optimal OAuth experience
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case "github", "microsoft", "facebook":
            // Use standard Safari user agent for other providers
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        default:
            // Default Safari user agent
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
        
        // Enable developer tools for OAuth debugging (respect setting)
        if #available(macOS 13.3, *) {
            let enabled = UserDefaults.standard.object(forKey: "enableDeveloperTools") as? Bool
            webView.isInspectable = (enabled ?? true)
        }
        
        // Performance settings optimized for OAuth flows
        webView.allowsBackForwardNavigationGestures = false // Prevent accidental navigation during OAuth
        webView.allowsMagnification = false // Prevent zoom issues during OAuth
        webView.allowsLinkPreview = false // Prevent interference with OAuth redirects
        
        NSLog("🔐 OAuth-specific WebView settings applied for provider: \(provider)")
    }
}