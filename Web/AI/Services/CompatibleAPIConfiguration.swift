import CryptoKit
import Darwin
import Foundation

/// An explicit API base URL, not a browser address or a completion URL.
struct CompatibleAPIConfiguration: Equatable, Sendable {
    let baseURL: URL
    let modelID: String
    let usesAPIKey: Bool
    let isLoopback: Bool

    init(endpoint: String, modelID: String, usesAPIKey: Bool = true) throws {
        guard endpoint.utf8.count <= 2_048,
              endpoint.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),
              !endpoint.contains("\\"), !endpoint.contains("%"),
              var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw Self.invalidEndpoint
        }
        guard let authority = endpoint.components(separatedBy: "://").dropFirst().first?.split(separator: "/", omittingEmptySubsequences: false).first,
              !authority.hasSuffix(":") else { throw Self.invalidEndpoint }
        var host = rawHost.lowercased()
        let address = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv6 = in6_addr()
        let isIPv6 = address.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = octets.count == 4 && octets.allSatisfy {
            guard let value = Int($0), (0...255).contains(value) else { return false }
            return String(value) == $0
        }
        let isDNS = host.count <= 253 && octets.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        // Numeric shorthand, octal and hexadecimal addresses are not hostnames.
        let looksNumeric = octets.allSatisfy { label in
            label.allSatisfy(\.isNumber) ||
            (label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit))
        }
        guard isIPv6 || isIPv4 || (isDNS && !looksNumeric) else { throw Self.invalidEndpoint }
        if isIPv6 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { throw Self.invalidEndpoint }
            host = "[\(String(cString: buffer))]"
        }
        let loopback = host == "localhost" || (isIPv4 && octets.first == "127") || host == "[::1]"
        guard scheme == "https" || loopback, usesAPIKey || loopback else { throw Self.invalidEndpoint }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.contains("//"), path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-._~".contains($0)) }),
              !path.hasSuffix("/chat/completions") else { throw Self.invalidEndpoint }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200,
              model.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw AIProviderError.invalidConfiguration("Enter the exact model ID from your API server.")
        }
        components.scheme = scheme
        components.host = host
        components.path = path
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        guard let url = components.url else { throw Self.invalidEndpoint }
        self.baseURL = url
        self.modelID = model
        self.usesAPIKey = usesAPIKey
        self.isLoopback = loopback
    }

    private static var invalidEndpoint: AIProviderError {
        .invalidConfiguration("Use an HTTPS API base URL, or HTTP on localhost or a loopback address. Leave out credentials, queries and /chat/completions.")
    }

    var endpointID: String {
        SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var providerID: String { "compatible_\(endpointID)" }
    var keychainAccount: String { "compatible_api_\(endpointID)" }
    var completionsURL: URL { baseURL.appendingPathComponent("chat/completions") }
    var connectionLabel: String { "\(baseURL.host ?? "API") · \(modelID)" }

    static let defaultsKey = "compatibleAPIConfiguration_v1"
    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let values = defaults.dictionary(forKey: defaultsKey),
              let endpoint = values["endpoint"] as? String,
              let model = values["model"] as? String,
              let usesKey = values["usesAPIKey"] as? Bool else { return nil }
        return try? Self(endpoint: endpoint, modelID: model, usesAPIKey: usesKey)
    }
    func save(defaults: UserDefaults = .standard) {
        defaults.set(["endpoint": baseURL.absoluteString, "model": modelID, "usesAPIKey": usesAPIKey], forKey: Self.defaultsKey)
    }
}

protocol CompatibleAPIKeyStorage {
    func compatibleAPIKey(for configuration: CompatibleAPIConfiguration) throws -> String?
    func storeCompatibleAPIKey(_ key: String?, for configuration: CompatibleAPIConfiguration) throws
}
