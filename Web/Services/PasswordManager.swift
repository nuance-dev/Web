import Security
import CryptoKit
import LocalAuthentication
import WebKit
import Foundation

class PasswordManager: NSObject, ObservableObject {
    static let shared = PasswordManager()
    
    @Published var savedPasswords: [SavedPassword] = []
    @Published var isAutofillEnabled: Bool = true
    @Published var requireBiometricAuth: Bool = true
    @Published var passwordGeneratorSettings = PasswordGeneratorSettings()
    
    private let serviceName = "com.web.browser.passwords"
    private var encryptionKey: SymmetricKey?
    
    struct SavedPassword: Identifiable, Codable {
        let id: UUID
        let website: String
        let username: String
        let encryptedPassword: Data
        let dateCreated: Date
        let lastUsed: Date
        let lastModified: Date
        let strength: PasswordStrength
        let notes: String?
        
        enum PasswordStrength: String, Codable, CaseIterable {
            case weak = "Weak"
            case medium = "Medium"
            case strong = "Strong"
            case veryStrong = "Very Strong"
            
            var color: NSColor {
                switch self {
                case .weak: return .systemRed
                case .medium: return .systemOrange
                case .strong: return .systemYellow
                case .veryStrong: return .systemGreen
                }
            }
        }
    }
    
    struct PasswordGeneratorSettings: Codable {
        var length: Int = 16
        var includeUppercase: Bool = true
        var includeLowercase: Bool = true
        var includeNumbers: Bool = true
        var includeSymbols: Bool = true
        var excludeSimilar: Bool = true
        var excludeAmbiguous: Bool = true
    }
    
    override init() {
        // Don't initialize encryption key during app startup to avoid keychain access
        super.init()
        loadSavedPasswords()
        loadSettings()
    }
    
    // MARK: - Encryption Key Management
    private enum KeyStorageError: Error {
        case unavailable(OSStatus)
        case invalidKey
    }

    private func getOrCreateEncryptionKey() throws -> SymmetricKey {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(serviceName).encryptionKey",
            kSecAttrAccount as String: "masterKey"
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw KeyStorageError.invalidKey }
            return SymmetricKey(data: data)
        }
        // A locked or denied keychain must never replace the existing encryption key.
        guard status == errSecItemNotFound else { throw KeyStorageError.unavailable(status) }
        let key = SymmetricKey(size: .bits256)
        var add = identity
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            var existing: AnyObject?
            let readStatus = SecItemCopyMatching(query as CFDictionary, &existing)
            guard readStatus == errSecSuccess, let data = existing as? Data, data.count == 32 else {
                throw KeyStorageError.unavailable(readStatus)
            }
            return SymmetricKey(data: data)
        }
        guard addStatus == errSecSuccess else { throw KeyStorageError.unavailable(addStatus) }
        return key
    }

    // MARK: - Password Storage and Retrieval
    func savePassword(website: String, username: String, password: String, notes: String? = nil) async -> Bool {
        guard await authenticateUser() else { return false }
        
        do {
            let encryptedPassword = try encryptPassword(password)
            let strength = analyzePasswordStrength(password)
            
            let savedPassword = SavedPassword(
                id: UUID(),
                website: website,
                username: username,
                encryptedPassword: encryptedPassword,
                dateCreated: Date(),
                lastUsed: Date(),
                lastModified: Date(),
                strength: strength,
                notes: notes
            )
            
            let account = "\(website):\(username)"
            let passwordData = try JSONEncoder().encode(savedPassword)
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecValueData as String: passwordData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account
            ]
            // Update in place so a failed write cannot delete the previous credential.
            var status = SecItemUpdate(identity as CFDictionary,
                [kSecValueData as String: passwordData] as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query as CFDictionary, nil) }
            
            if status == errSecSuccess {
                await MainActor.run {
                    savedPasswords.removeAll { $0.website == website && $0.username == username }
                    savedPasswords.append(savedPassword)
                    savedPasswords.sort { $0.lastUsed > $1.lastUsed }
                    savePasswordMetadata()
                }
                return true
            }
        } catch {
            print("Failed to save password: \(error)")
        }
        
        return false
    }
    
    func loadPassword(for website: String, username: String) async -> String? {
        guard await authenticateUser() else { return nil }
        
        let account = "\(website):\(username)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let savedPassword = try? JSONDecoder().decode(SavedPassword.self, from: data) {
            
            do {
                let decryptedPassword = try decryptPassword(savedPassword.encryptedPassword)
                await updateLastUsed(for: savedPassword)
                return decryptedPassword
            } catch {
                print("Failed to decrypt password: \(error)")
            }
        }
        
        return nil
    }
    
    func deletePassword(for website: String, username: String) async -> Bool {
        guard await authenticateUser() else { return false }
        
        let account = "\(website):\(username)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status == errSecSuccess {
            await MainActor.run {
                savedPasswords.removeAll { $0.website == website && $0.username == username }
                savePasswordMetadata()
            }
            return true
        }
        
        return false
    }
    
    // MARK: - Password Generation
    func generateSecurePassword(settings: PasswordGeneratorSettings? = nil) -> String {
        let config = settings ?? passwordGeneratorSettings
        
        var characters = ""
        
        if config.includeLowercase {
            characters += config.excludeSimilar ? "abcdefghijkmnopqrstuvwxyz" : "abcdefghijklmnopqrstuvwxyz"
        }
        
        if config.includeUppercase {
            characters += config.excludeSimilar ? "ABCDEFGHJKLMNPQRSTUVWXYZ" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        }
        
        if config.includeNumbers {
            characters += config.excludeSimilar ? "23456789" : "0123456789"
        }
        
        if config.includeSymbols {
            let symbols = config.excludeAmbiguous ? "!@#$%^&*-_=+[]{}|;:,.<>?" : "!@#$%^&*()-_=+[]{}\\|;:'\",.<>?/~`"
            characters += symbols
        }
        
        guard !characters.isEmpty else { return "" }
        
        var password = ""
        let charactersArray = Array(characters)
        
        if config.includeLowercase {
            let lowercase = config.excludeSimilar ? "abcdefghijkmnopqrstuvwxyz" : "abcdefghijklmnopqrstuvwxyz"
            password += String(lowercase.randomElement()!)
        }
        
        if config.includeUppercase {
            let uppercase = config.excludeSimilar ? "ABCDEFGHJKLMNPQRSTUVWXYZ" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            password += String(uppercase.randomElement()!)
        }
        
        if config.includeNumbers {
            let numbers = config.excludeSimilar ? "23456789" : "0123456789"
            password += String(numbers.randomElement()!)
        }
        
        if config.includeSymbols {
            let symbols = config.excludeAmbiguous ? "!@#$%^&*-_=+[]{}|;:,.<>?" : "!@#$%^&*()-_=+[]{}\\|;:'\",.<>?/~`"
            password += String(symbols.randomElement()!)
        }
        
        for _ in password.count..<config.length {
            password += String(charactersArray.randomElement()!)
        }
        
        return String(password.shuffled())
    }
    
    func analyzePasswordStrength(_ password: String) -> SavedPassword.PasswordStrength {
        var score = 0
        
        if password.count >= 8 { score += 1 }
        if password.count >= 12 { score += 1 }
        if password.count >= 16 { score += 1 }
        
        if password.contains(where: { $0.isLowercase }) { score += 1 }
        if password.contains(where: { $0.isUppercase }) { score += 1 }
        if password.contains(where: { $0.isNumber }) { score += 1 }
        if password.contains(where: { "!@#$%^&*()-_=+[]{}\\|;:'\",.<>?/~`".contains($0) }) { score += 1 }
        
        if password.count >= 20 { score += 1 }
        if !hasCommonPatterns(password) { score += 1 }
        
        switch score {
        case 0...2: return .weak
        case 3...4: return .medium
        case 5...6: return .strong
        default: return .veryStrong
        }
    }
    
    private func hasCommonPatterns(_ password: String) -> Bool {
        let commonPatterns = [
            "123456", "password", "qwerty", "abc123", "letmein",
            "admin", "welcome", "monkey", "dragon", "master"
        ]
        
        let lowercasePassword = password.lowercased()
        return commonPatterns.contains { lowercasePassword.contains($0) }
    }
    
    // MARK: - Autofill Support (CSP-Protected)
    func configureAutofill(for webView: WKWebView) {
        guard isAutofillEnabled else { return }
        
        let autofillScript = generateAutofillScript()
        
        // Keep credential messaging outside the webpage's JavaScript namespace.
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: autofillScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.removeScriptMessageHandler(forName: "autofillHandler", contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: "autofillHandler")
    }

    private func generateAutofillScript() -> String {
        return """
        (function() {
            'use strict';
            
            if (window.location.protocol !== 'https:') return;
            let formObserver;
            let lastFormCheck = 0;
            const FORM_CHECK_INTERVAL = 10000; // Increased from 3s to 10s to prevent Google CPU issues
            
            function findLoginForms() {
                const forms = document.querySelectorAll('form');
                const loginForms = [];
                
                forms.forEach(form => {
                    const emailInput = form.querySelector('input[type="email"], input[name*="email"], input[name*="username"], input[autocomplete*="username"]');
                    const passwordInput = form.querySelector('input[type="password"]');
                    
                    if (emailInput && passwordInput) {
                        loginForms.push({
                            form: form,
                            emailInput: emailInput,
                            passwordInput: passwordInput,
                            website: window.location.hostname
                        });
                    }
                });
                
                return loginForms;
            }
            
            function addAutofillButtons(loginForm) {
                if (loginForm.emailInput.hasAttribute('data-autofill-added')) return;
                
                loginForm.emailInput.setAttribute('data-autofill-added', 'true');
                
                const button = document.createElement('button');
                button.type = 'button';
                button.innerHTML = '🔑';
                button.style.cssText = `
                    position: absolute;
                    right: 8px;
                    top: 50%;
                    transform: translateY(-50%);
                    background: none;
                    border: none;
                    font-size: 16px;
                    cursor: pointer;
                    z-index: 1000;
                    opacity: 0.7;
                    transition: opacity 0.2s;
                `;
                
                button.addEventListener('mouseenter', () => button.style.opacity = '1');
                button.addEventListener('mouseleave', () => button.style.opacity = '0.7');
                
                button.addEventListener('click', (e) => {
                    if (!e.isTrusted) return;
                    e.preventDefault();
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.autofillHandler) {
                        window.webkit.messageHandlers.autofillHandler.postMessage({
                            type: 'requestCredentials',
                            website: loginForm.website,
                            username: loginForm.emailInput.value
                        });
                    }
                });
                
                const inputStyle = window.getComputedStyle(loginForm.emailInput);
                if (inputStyle.position === 'static') {
                    loginForm.emailInput.style.position = 'relative';
                }
                
                const container = loginForm.emailInput.parentElement;
                container.style.position = 'relative';
                container.appendChild(button);
            }
            
            // Password capture on submit is deliberately absent. Page scripts must
            // never trigger native credential writes or biometric prompts.

            function checkForForms() {
                const now = Date.now();
                if (now - lastFormCheck < FORM_CHECK_INTERVAL) return;
                lastFormCheck = now;
                
                // Skip checking if page is hidden to save CPU (critical for Google performance)
                if (document.hidden) return;
                
                // Skip on Google search pages to prevent CPU spikes - Google search doesn't need autofill
                if (window.location.hostname.includes('google.com') || window.location.hostname.includes('google.')) {
                    return;
                }
                
                const loginForms = findLoginForms();
                
                loginForms.forEach(loginForm => {
                    addAutofillButtons(loginForm);
                });
                
            }
            
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', checkForForms);
            } else {
                checkForForms();
            }
            
            // Use a single shared timer to reduce CPU load across multiple tabs
            window.passwordFormTimer = window.passwordFormTimer || setInterval(checkForForms, FORM_CHECK_INTERVAL);
            
            // Cleanup timer on page unload
            window.addEventListener('beforeunload', () => {
                if (window.passwordFormTimer) {
                    clearInterval(window.passwordFormTimer);
                    window.passwordFormTimer = null;
                }
            });
            
            formObserver = new MutationObserver(function(mutations) {
                // Throttle mutation observer to prevent excessive CPU usage
                if (document.hidden) return;
                
                // Skip Google search pages to prevent CPU spikes during search interactions
                if (window.location.hostname.includes('google.com') || window.location.hostname.includes('google.')) {
                    return;
                }
                
                let shouldCheck = false;
                mutations.forEach(function(mutation) {
                    if (mutation.addedNodes.length > 0) {
                        for (let node of mutation.addedNodes) {
                            if (node.nodeType === Node.ELEMENT_NODE) {
                                if (node.tagName === 'FORM' || node.querySelector && node.querySelector('form')) {
                                    shouldCheck = true;
                                    break;
                                }
                            }
                        }
                    }
                });
                
                if (shouldCheck) {
                    // Debounce the check to prevent rapid successive calls
                    if (window.formCheckTimeout) clearTimeout(window.formCheckTimeout);
                    window.formCheckTimeout = setTimeout(checkForForms, 500);
                }
            });
            
            formObserver.observe(document.body, { childList: true, subtree: true });
            
        })();
        """
    }
    
    // MARK: - Authentication
    private func authenticateUser() async -> Bool {
        guard requireBiometricAuth else { return true }
        
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Authenticate to access saved passwords") { success, error in
                continuation.resume(returning: success)
            }
        }
    }
    
    // MARK: - Encryption/Decryption
    private func encryptPassword(_ password: String) throws -> Data {
        // Lazy initialization of encryption key when first needed
        if encryptionKey == nil {
            encryptionKey = try getOrCreateEncryptionKey()
        }
        
        let passwordData = Data(password.utf8)
        let sealedBox = try AES.GCM.seal(passwordData, using: encryptionKey!)
        return sealedBox.combined!
    }
    
    private func decryptPassword(_ encryptedData: Data) throws -> String {
        // Lazy initialization of encryption key when first needed
        if encryptionKey == nil {
            encryptionKey = try getOrCreateEncryptionKey()
        }
        
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey!)
        return String(data: decryptedData, encoding: .utf8) ?? ""
    }
    
    // MARK: - Data Management
    private var metadataIdentity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(serviceName).metadata",
         kSecAttrAccount as String: "index"]
    }

    private func loadSavedPasswords() {
        var query = metadataIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let metadata = try? JSONDecoder().decode([SavedPassword].self, from: data) {
            savedPasswords = metadata.sorted { $0.lastUsed > $1.lastUsed }
        } else if status == errSecItemNotFound,
                  let data = UserDefaults.standard.data(forKey: "passwordMetadata"),
                  let metadata = try? JSONDecoder().decode([SavedPassword].self, from: data) {
            savedPasswords = metadata.sorted { $0.lastUsed > $1.lastUsed }
            savePasswordMetadata()
        }
    }

    private func savePasswordMetadata() {
        guard let data = try? JSONEncoder().encode(savedPasswords) else { return }
        var status = SecItemUpdate(metadataIdentity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = metadataIdentity
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: "passwordMetadata")
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "passwordManagerSettings"),
           let settings = try? JSONDecoder().decode(PasswordManagerSettings.self, from: data) {
            isAutofillEnabled = settings.isAutofillEnabled
            requireBiometricAuth = settings.requireBiometricAuth
            passwordGeneratorSettings = settings.generatorSettings
        }
    }
    
    private func saveSettings() {
        let settings = PasswordManagerSettings(
            isAutofillEnabled: isAutofillEnabled,
            requireBiometricAuth: requireBiometricAuth,
            generatorSettings: passwordGeneratorSettings
        )
        
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "passwordManagerSettings")
        }
    }
    
    private func updateLastUsed(for password: SavedPassword) async {
        await MainActor.run {
            if let index = savedPasswords.firstIndex(where: { $0.id == password.id }) {
                savedPasswords[index] = SavedPassword(
                    id: password.id,
                    website: password.website,
                    username: password.username,
                    encryptedPassword: password.encryptedPassword,
                    dateCreated: password.dateCreated,
                    lastUsed: Date(),
                    lastModified: password.lastModified,
                    strength: password.strength,
                    notes: password.notes
                )
                
                savedPasswords.sort { $0.lastUsed > $1.lastUsed }
                savePasswordMetadata()
            }
        }
    }
    
    struct PasswordManagerSettings: Codable {
        let isAutofillEnabled: Bool
        let requireBiometricAuth: Bool
        let generatorSettings: PasswordGeneratorSettings
    }
}

// MARK: - Script Message Handler (CSP-Protected)
extension PasswordManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isAutofillEnabled, message.name == "autofillHandler",
              let webView = message.webView,
              webView.configuration.websiteDataStore.isPersistent,
              let pageURL = webView.url,
              BrowserSecurityPolicy.Origin(url: pageURL)?.scheme == "https",
              BrowserSecurityPolicy.allowsBridgeMessage(
                isMainFrame: message.frameInfo.isMainFrame,
                scheme: message.frameInfo.securityOrigin.protocol,
                host: message.frameInfo.securityOrigin.host,
                port: message.frameInfo.securityOrigin.port,
                topLevelURL: pageURL),
              case .valid(let body) = CSPManager.shared.validateMessageInput(message, expectedHandler: "autofillHandler"),
              body["type"] as? String == "requestCredentials" else { return }

        let matchingPasswords = savedPasswords.filter {
            BrowserSecurityPolicy.credentialMatches(website: $0.website, pageURL: pageURL)
        }
        guard !matchingPasswords.isEmpty else { return }
        DispatchQueue.main.async {
            // Ignore queued messages if navigation changed the target document.
            guard webView.url == pageURL else { return }
            NotificationCenter.default.post(name: .showAutofillSuggestions,
                object: AutofillSuggestion(passwords: matchingPasswords, webView: webView))
        }
    }

    struct AutofillSuggestion {
        let passwords: [SavedPassword]
        let webView: WKWebView?
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let showAutofillSuggestions = Notification.Name("showAutofillSuggestions")
}