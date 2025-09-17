import SwiftUI
import AppKit

struct URLBar: View {
    let tabID: UUID
    let themeColor: NSColor?
    let mixedContentStatus: MixedContentManager.MixedContentStatus?
    let onSubmit: (String) -> Void
    @FocusState private var isURLBarFocused: Bool
    @State private var hovering: Bool = false
    @State private var editingText: String = ""
    @State private var suggestions: [AutofillSuggestion] = []
    
    // Use centralized URL synchronizer for state management
    @ObservedObject private var urlSynchronizer = URLSynchronizer.shared
    
    // Convert NSColor to SwiftUI Color
    private var swiftUIThemeColor: Color {
        if let nsColor = themeColor {
            return Color(nsColor)
        }
        return .clear
    }
    
    // Show full URL when focused or hovering, cleaned version otherwise
    private var displayText: String {
        if isURLBarFocused {
            return editingText.isEmpty ? urlSynchronizer.currentURL : editingText
        } else if hovering {
            return urlSynchronizer.currentURL
        } else {
            return urlSynchronizer.displayURL
        }
    }
    
    // Editable binding for input field
    private var editableText: Binding<String> {
        Binding(
            get: { self.displayText },
            set: { newValue in
                self.editingText = newValue
                if self.isURLBarFocused {
                    self.updateSuggestions(for: newValue)
                }
            }
        )
    }
    
    private func syncWithURLSynchronizer() {
        // Always initialize editing text with full URL when focus is gained
        if isURLBarFocused {
            editingText = urlSynchronizer.currentURL
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Security indicator with enhanced design
            SecurityIndicator(
                urlString: urlSynchronizer.currentURL,
                mixedContentStatus: mixedContentStatus
            )
            
            // Main input field with simplified state management
            TextField("Search or enter website", text: editableText)
                .textFieldStyle(.plain)
                .font(.webBody)
                .foregroundColor(.textPrimary)
                .focused($isURLBarFocused)
                .textSelection(.enabled)
                .onSubmit {
                    navigateToURL()
                }
                .onChange(of: isURLBarFocused) { _, focused in
                    if focused {
                        syncWithURLSynchronizer()
                    } else {
                        // Clear suggestions and editing text when focus is lost
                        suggestions = []
                        editingText = ""
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.hovering = hovering
                    }
                }
            
            // Quick actions with improved spacing
            HStack(spacing: 6) {
                HistoryButton()
                DownloadsButton()
                BookmarkButton()
                AIToggleButton()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4) // Further reduced for even more minimal height
        .background(urlBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            syncWithURLSynchronizer()
        }
        // Removed complex focus coordinator - using native SwiftUI focus
        .onReceive(NotificationCenter.default.publisher(for: .focusURLBarRequested)) { _ in
            isURLBarFocused = true
        }
        .overlay(alignment: .topLeading) {
            // Suggestion list overlay – does not affect layout height
            if isURLBarFocused && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(5)) { suggestion in
                        suggestionRow(suggestion)
                        if suggestion.id != suggestions.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                        .shadow(radius: 8)
                )
                .offset(y: 34) // show below URLBar
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(1000)
            }
        }
    }
    
    private var urlBarBackground: some View {
        ZStack {
            // Fully transparent background for clean input
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
                .allowsHitTesting(false)
            
            // Subtle theme color integration
            if themeColor != nil && swiftUIThemeColor != .clear {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        EllipticalGradient(
                            colors: [
                                swiftUIThemeColor.opacity(0.04),
                                swiftUIThemeColor.opacity(0.02),
                                Color.clear
                            ],
                            center: .center,
                            startRadiusFraction: 0.3,
                            endRadiusFraction: 1.0
                        )
                    )
                    .animation(.easeInOut(duration: 0.4), value: themeColor)
                    .allowsHitTesting(false)
            }
            
            // Seamless focus enhancement
            if isURLBarFocused {
                // Subtle inner ambient glow
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        EllipticalGradient(
                            colors: [
                                focusGlowColor.opacity(0.06),
                                focusGlowColor.opacity(0.03),
                                focusGlowColor.opacity(0.01),
                                Color.clear
                            ],
                            center: .center,
                            startRadiusFraction: 0.3,
                            endRadiusFraction: 1.2
                        )
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: themeColor)
                    .allowsHitTesting(false)
                
                // Minimal surface elevation
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.02),
                                Color.clear,
                                Color.black.opacity(0.01)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .transition(.opacity)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isURLBarFocused)
                    .allowsHitTesting(false)
            }
            
            // Ultra-subtle border (only when not focused)
            if !isURLBarFocused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        hovering ? Color.borderGlass.opacity(0.3) : Color.borderGlass.opacity(0.15),
                        lineWidth: 0.5
                    )
                    .animation(.easeInOut(duration: 0.2), value: hovering)
                    .allowsHitTesting(false)
            }
        }
    }
    
    // Seamless focus styling
    
    private var focusGlowColor: Color {
        return themeColor != nil ? swiftUIThemeColor : Color.accentBeam
    }
    
    private func navigateToURL() {
        let inputText = editingText.isEmpty ? urlSynchronizer.currentURL : editingText
        let finalURL: String
        
        // Determine if input is URL or search query
        if isValidURL(inputText) {
            finalURL = inputText.hasPrefix("http") ? inputText : "https://\(inputText)"
        } else {
            // Search Google
            let searchQuery = inputText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            finalURL = "https://www.google.com/search?q=\(searchQuery)"
        }
        
        // Update URLSynchronizer with user input
        urlSynchronizer.updateFromUserInput(urlString: finalURL, tabID: tabID)
        
        onSubmit(finalURL)
        isURLBarFocused = false
        editingText = ""
    }
    
    private func isValidURL(_ string: String) -> Bool {
        // Check if it already has a scheme
        if string.hasPrefix("http://") || string.hasPrefix("https://") {
            return URL(string: string) != nil
        }
        
        // Check if it looks like a domain (contains . and no spaces)
        if string.contains(".") && !string.contains(" ") {
            // Make sure it's not just a decimal number
            if !string.allSatisfy({ $0.isNumber || $0 == "." }) {
                return true
            }
        }
        
        return false
    }
    
    private func suggestionRow(_ suggestion: AutofillSuggestion) -> some View {
        Button(action: {
            isURLBarFocused = false
            editingText = suggestion.url
            navigateToURL(from: suggestion)
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: suggestion.sourceType))
                    .foregroundColor(.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .foregroundColor(.textPrimary)
                    Text(suggestion.url)
                        .font(.caption2)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func updateSuggestions(for query: String) {
        guard isURLBarFocused && !query.isEmpty else {
            suggestions = []
            return
        }
        Task {
            let results = await AutofillService.shared.getSuggestions(for: query)
            await MainActor.run {
                suggestions = results
            }
        }
    }

    private func icon(for type: SuggestionSourceType) -> String {
        switch type {
        case .history, .mostVisited:
            return "clock.arrow.circlepath"
        case .bookmark:
            return "bookmark"
        case .searchSuggestion:
            return "magnifyingglass"
        }
    }

    private func navigateToURL(from suggestion: AutofillSuggestion) {
        // Update URLSynchronizer with suggestion
        urlSynchronizer.updateFromUserInput(urlString: suggestion.url, tabID: tabID)
        onSubmit(suggestion.url)
        isURLBarFocused = false
        editingText = ""
    }
    
}

// Security indicator component
struct SecurityIndicator: View {
    let urlString: String
    let mixedContentStatus: MixedContentManager.MixedContentStatus?
    @State private var certificateStatus: CertificateStatus = .unknown
    @State private var showingSecurityDetails = false
    
    enum CertificateStatus {
        case secure
        case insecure
        case warning
        case error
        case mixedContent
        case mixedContentBlocked
        case unknown
        
        var icon: String {
            switch self {
            case .secure:
                return "lock.fill"
            case .insecure:
                return "lock.open.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .error:
                return "xmark.shield.fill"
            case .mixedContent:
                return "exclamationmark.shield.fill"
            case .mixedContentBlocked:
                return "shield.slash.fill"
            case .unknown:
                return "magnifyingglass"
            }
        }
        
        var color: Color {
            switch self {
            case .secure:
                return .green.opacity(0.8)
            case .insecure:
                return .red.opacity(0.8)
            case .warning:
                return .orange.opacity(0.8)
            case .error:
                return .red
            case .mixedContent:
                return .orange.opacity(0.9)
            case .mixedContentBlocked:
                return .blue.opacity(0.8)
            case .unknown:
                return .textSecondary
            }
        }
        
        var tooltip: String {
            switch self {
            case .secure:
                return "Connection is secure - all content loaded over HTTPS"
            case .insecure:
                return "Connection is not secure"
            case .warning:
                return "Certificate has issues"
            case .error:
                return "Certificate validation failed"
            case .mixedContent:
                return "Mixed content detected - some resources loaded over HTTP"
            case .mixedContentBlocked:
                return "Mixed content blocked for security"
            case .unknown:
                return "Search or enter website"
            }
        }
        
        var hasSecurityIssue: Bool {
            switch self {
            case .secure, .unknown:
                return false
            case .insecure, .warning, .error, .mixedContent, .mixedContentBlocked:
                return true
            }
        }
    }
    
    private var hasURL: Bool {
        !urlString.isEmpty && (urlString.contains(".") || urlString.hasPrefix("http"))
    }
    
    var body: some View {
        Button(action: { showingSecurityDetails.toggle() }) {
            Image(systemName: certificateStatus.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(certificateStatus.color)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(certificateStatus.tooltip)
        .animation(.easeInOut(duration: 0.2), value: certificateStatus)
        .onChange(of: urlString) { _, newURL in
            updateCertificateStatus(for: newURL)
        }
        .onChange(of: mixedContentStatus) { _, _ in
            updateCertificateStatus(for: urlString)
        }
        .onAppear {
            updateCertificateStatus(for: urlString)
        }
        .popover(isPresented: $showingSecurityDetails) {
            SecurityDetailsPopover(
                urlString: urlString,
                certificateStatus: certificateStatus,
                mixedContentStatus: mixedContentStatus
            )
        }
    }
    
    private func updateCertificateStatus(for url: String) {
        guard hasURL else {
            certificateStatus = .unknown
            return
        }
        
        // SECURITY: Check mixed content status first for HTTPS pages
        if url.hasPrefix("https://"), let mixedStatus = mixedContentStatus {
            if mixedStatus.mixedContentDetected {
                // Determine if mixed content is being blocked or allowed
                let policy = MixedContentManager.shared.mixedContentPolicy
                switch policy {
                case .block:
                    certificateStatus = .mixedContentBlocked
                case .warn, .allow:
                    certificateStatus = .mixedContent
                }
                return
            }
        }
        
        // Basic URL scheme checking
        if url.hasPrefix("https://") {
            // For HTTPS URLs, we start with secure but will update based on actual validation
            certificateStatus = .secure
            
            // Check if there are any certificate exceptions for this host
            if let urlObj = URL(string: url), let host = urlObj.host {
                let port = urlObj.port ?? 443
                
                if CertificateManager.shared.hasException(for: host, port: port) {
                    certificateStatus = .warning
                }
                
                // Mixed content status takes precedence over certificate issues
                // for better user understanding of the security context
            }
        } else if url.hasPrefix("http://") {
            certificateStatus = .insecure
        } else {
            certificateStatus = .unknown
        }
    }
}

// MARK: - Security Details Popover

struct SecurityDetailsPopover: View {
    let urlString: String
    let certificateStatus: SecurityIndicator.CertificateStatus
    let mixedContentStatus: MixedContentManager.MixedContentStatus?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: certificateStatus.icon)
                    .foregroundColor(certificateStatus.color)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Security")
                        .font(.headline)
                    Text(certificateStatus.tooltip)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
            
            // URL Information
            VStack(alignment: .leading, spacing: 8) {
                Label("Website", systemImage: "globe")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let url = URL(string: urlString), let host = url.host {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        if url.port != nil && url.port != 80 && url.port != 443 {
                            Text("Port: \(url.port!)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(urlString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            
            // Security Status Details
            VStack(alignment: .leading, spacing: 8) {
                Label("Security Status", systemImage: "shield")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(securityStatusDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
            // Certificate Exception Info (if applicable)
            if let url = URL(string: urlString),
               let host = url.host,
               CertificateManager.shared.hasException(for: host, port: url.port ?? 443) {
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Certificate Exception", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    
                    Text("You have granted a security exception for this website. This may pose security risks.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    
                    Button("Revoke Exception") {
                        CertificateManager.shared.revokeException(for: host, port: url.port ?? 443)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
            
            // Mixed Content Information (if applicable)
            if let mixedStatus = mixedContentStatus,
               mixedStatus.mixedContentDetected {
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Mixed Content Detected", systemImage: "exclamationmark.shield")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    
                    Text("This HTTPS page contains HTTP resources, which compromises the security of the connection.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    
                    // Show current policy
                    let policy = MixedContentManager.shared.mixedContentPolicy
                    HStack {
                        Text("Policy:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(policy.rawValue)
                            .font(.caption)
                            .foregroundColor(policy.securityLevel.color)
                    }
                    
                    // Show violation count if available
                    if mixedStatus.violationCount > 0 {
                        Text("\(mixedStatus.violationCount) mixed content \(mixedStatus.violationCount == 1 ? "resource" : "resources") detected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Mixed Content Settings...") {
                        NotificationCenter.default.post(name: .showSettingsRequested, object: "mixedContent")
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.blue)
                }
            }
            
            // Security Settings Link
            Divider()
            
            Button("Security Settings...") {
                NotificationCenter.default.post(name: .showSettingsRequested, object: "security")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
        }
        .padding(16)
        .frame(width: 300)
    }
    
    private var securityStatusDescription: String {
        switch certificateStatus {
        case .secure:
            return "Your connection to this site is encrypted and authenticated."
        case .insecure:
            return "Your connection to this site is not encrypted. Information you send can be intercepted."
        case .warning:
            return "This site's certificate has issues, but you've chosen to trust it."
        case .error:
            return "This site's certificate could not be validated. Avoid entering sensitive information."
        case .unknown:
            return "No security information available."
        case .mixedContent:
            return "This HTTPS site contains HTTP resources, which may compromise your security."
        case .mixedContentBlocked:
            return "HTTP resources on this HTTPS page have been blocked for your security."
        }
    }
}


// Bookmark button component
struct BookmarkButton: View {
    @ObservedObject private var urlSynchronizer = URLSynchronizer.shared
    @ObservedObject private var bookmarkService = BookmarkService.shared
    @State private var hovering: Bool = false
    
    private var hasURL: Bool {
        !urlSynchronizer.currentURL.isEmpty
    }
    
    private var currentURLString: String {
        urlSynchronizer.currentURL
    }
    
    private var currentTitleString: String {
        let title = URLSynchronizer.shared.pageTitle
        return title.isEmpty ? currentURLString : title
    }
    
    private var isBookmarked: Bool {
        guard !currentURLString.isEmpty else { return false }
        return bookmarkService.isBookmarked(url: currentURLString)
    }
    
    var body: some View {
        Button(action: toggleBookmark) {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isBookmarked ? Color.accentBeam : (hasURL ? .textSecondary : .textSecondary.opacity(0.5)))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!hasURL)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
    }
    
    private func toggleBookmark() {
        guard hasURL else { return }
        KeyboardShortcutHandler.shared.toggleBookmark(
            url: currentURLString,
            title: currentTitleString
        )
    }
}

// History button component
struct HistoryButton: View {
    @State private var hovering: Bool = false
    
    var body: some View {
        Button(action: showHistory) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
    }
    
    private func showHistory() {
        KeyboardShortcutHandler.shared.showHistoryPanel.toggle()
    }
}

// Downloads button component
struct DownloadsButton: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var hovering: Bool = false
    
    var body: some View {
        Button(action: showDownloads) {
            ZStack {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textSecondary)
                    .frame(width: 20, height: 20)
                
                // Active download indicator
                if downloadManager.totalActiveDownloads > 0 {
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
    }
    
    private func showDownloads() {
        KeyboardShortcutHandler.shared.showDownloadsPanel.toggle()
    }
}


// Custom button style for URL bar actions
struct URLBarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.bgSurface)
                    .opacity(configuration.isPressed ? 0.8 : 0.0)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// AI Toggle button component
struct AIToggleButton: View {
    @State private var hovering: Bool = false
    @State private var isAISidebarExpanded: Bool = false
    
    var body: some View {
        Button(action: toggleAISidebar) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isAISidebarExpanded ? .accentColor : (hovering ? .textPrimary : .textSecondary))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aISidebarStateChanged)) { notification in
            if let expanded = notification.object as? Bool {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAISidebarExpanded = expanded
                }
            }
        }
    }
    
    private func toggleAISidebar() {
        NotificationCenter.default.post(name: .toggleAISidebar, object: nil)
    }
}

#Preview {
    URLBar(tabID: UUID(), themeColor: nil, mixedContentStatus: nil, onSubmit: { _ in })
}