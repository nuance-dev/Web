import Foundation

protocol CompatibleAPITransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func lines(for request: URLRequest) async throws -> CompatibleAPIStream
}

struct CompatibleAPIStream: Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let response: URLResponse
    // Explicit disposal also covers a rejected response that was never iterated.
    var cancel: @Sendable () -> Void = {}
}

/// Shares the cookieless, redirect-rejecting session with the named API providers.
struct CompatibleURLSessionTransport: CompatibleAPITransport {
    static let maximumResponseBytes = 1_048_576

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await AIProviderNetwork.session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else { throw Self.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    func lines(for request: URLRequest) async throws -> CompatibleAPIStream {
        let (bytes, response) = try await AIProviderNetwork.session.bytes(for: request)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let task = Task {
            do {
                var line = Data()
                var count = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= Self.maximumResponseBytes, line.count < 65_536 else { throw Self.tooLarge }
                    if byte == 10 {
                        guard let value = String(data: line, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                        switch continuation.yield(value.trimmingCharacters(in: .newlines)) {
                        case .enqueued: break
                        case .dropped: throw Self.tooLarge
                        case .terminated: throw CancellationError()
                        @unknown default: throw CancellationError()
                        }
                        line.removeAll(keepingCapacity: true)
                    } else { line.append(byte) }
                }
                try Task.checkCancellation()
                if !line.isEmpty {
                    guard let value = String(data: line, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                    switch continuation.yield(value) {
                    case .enqueued: break
                    case .dropped: throw Self.tooLarge
                    case .terminated: throw CancellationError()
                    @unknown default: throw CancellationError()
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return CompatibleAPIStream(lines: stream, response: response, cancel: { task.cancel() })
    }

    static var tooLarge: AIProviderError { .providerSpecificError("The API response exceeded the size limit.") }
}

/// A separately configured text API. It never reads the named OpenAI provider's key.
@MainActor
final class CompatibleAPIProvider: ExternalAPIProvider {
    let configuration: CompatibleAPIConfiguration
    override var providerId: String { configuration.providerID }
    override var displayName: String { "Custom API" }
    // The connection stores its model explicitly; no second global preference is needed.
    override var selectedModel: AIModel? {
        get { configuredModel }
        set { configuredModel = newValue }
    }
    private var configuredModel: AIModel?
    private let keys: any CompatibleAPIKeyStorage
    private let transport: any CompatibleAPITransport
    private let defaults: UserDefaults
    private var revoked = false
    private var streams: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: Task<(Data, URLResponse), Error>] = [:]

    init(configuration: CompatibleAPIConfiguration,
         keys: any CompatibleAPIKeyStorage = SecureKeyStorage.shared,
         transport: any CompatibleAPITransport = CompatibleURLSessionTransport(),
         defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.keys = keys
        self.transport = transport
        self.defaults = defaults
        super.init(apiProviderType: nil)
        configureModel()
    }

    private func configureModel() {
        let model = AIModel(id: configuration.modelID, name: configuration.modelID,
                            description: "Configured API model", contextWindow: 0,
                            costPerToken: nil, pricing: nil,
                            capabilities: [.textGeneration, .conversation, .summarization],
                            provider: providerId, isAvailable: true)
        availableModels = [model]
        selectedModel = model
    }

    override func initialize() async throws {
        try Task.checkCancellation()
        guard !revoked else { throw Self.configurationChanged }
        apiKey = configuration.usesAPIKey ? try keys.compatibleAPIKey(for: configuration) : nil
        try await validateConfiguration()
        configureModel()
        isInitialized = true
    }

    override func validateConfiguration() async throws {
        guard !revoked else { throw Self.configurationChanged }
        if configuration.usesAPIKey {
            guard let apiKey else { throw AIProviderError.missingAPIKey(displayName) }
            try Self.validateKey(apiKey)
        }
        // No model-list requirement or paid completion just to select a server.
    }

    nonisolated static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 8_192,
              key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
            throw AIProviderError.invalidConfiguration("Enter a key without spaces or line breaks.")
        }
    }

    override func isReady() async -> Bool { isInitialized && !revoked }
    override func loadAvailableModels() async { configureModel() }
    override func cleanup() async {
        streams.values.forEach { $0.cancel() }
        requests.values.forEach { $0.cancel() }
        isInitialized = false
        apiKey = nil
    }
    func revoke() {
        revoked = true
        streams.values.forEach { $0.cancel() }
        requests.values.forEach { $0.cancel() }
        isInitialized = false
        apiKey = nil
    }
    private static var configurationChanged: AIProviderError {
        .invalidConfiguration("The API configuration changed. Choose a provider again.")
    }

    func request(query: String, context: String?, history: [ConversationMessage], model: AIModel?, streaming: Bool) throws -> URLRequest {
        try Task.checkCancellation()
        guard isInitialized, !revoked else { throw Self.configurationChanged }
        if let model, model.id != configuration.modelID || model.provider != providerId {
            throw AIProviderError.modelNotAvailable("Choose the configured API model.")
        }
        let source = AIContextPolicy.canSharePage(providerID: providerId, isPrivate: false, defaults: defaults) ? context : nil
        var request = URLRequest(url: configuration.completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if configuration.usesAPIKey {
            guard let apiKey else { throw AIProviderError.missingAPIKey(displayName) }
            try Self.validateKey(apiKey)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.modelID,
            "messages": AIContextPolicy.messages(query: query, context: source, history: history),
            "stream": streaming,
            "max_tokens": 4096
        ])
        guard (request.httpBody?.count ?? 0) <= 1_048_576 else {
            throw AIProviderError.invalidConfiguration("The request is too large. Shorten the conversation.")
        }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              http.url == configuration.completionsURL else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw AIProviderError.authenticationFailed }
            if http.statusCode == 429 { throw AIProviderError.rateLimitExceeded }
            throw AIProviderError.providerSpecificError("Custom API returned HTTP \(http.statusCode). Check the endpoint and model ID.")
        }
    }

    override func generateResponse(query: String, context: String?, conversationHistory: [ConversationMessage], model: AIModel?) async throws -> AIResponse {
        try preflightCircuitBreaker()
        let start = Date()
        let request = try request(query: query, context: context, history: conversationHistory, model: model, streaming: false)
        let id = UUID()
        let task = Task { try await transport.data(for: request) }
        requests[id] = task
        defer { requests.removeValue(forKey: id) }
        let (data, response) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !revoked, isInitialized else { throw Self.configurationChanged }
        try validate(response)
        guard data.count <= CompatibleURLSessionTransport.maximumResponseBytes,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.providerSpecificError("The API returned no text.")
        }
        let duration = Date().timeIntervalSince(start)
        let contextUsed = context != nil && AIContextPolicy.canSharePage(providerID: providerId, isPrivate: false, defaults: defaults)
        let metadata = ResponseMetadata(modelVersion: configuration.modelID, inferenceMethod: .fallback,
                                        contextUsed: contextUsed, processingSteps: [], memoryUsage: 0, energyImpact: .low)
        updateUsageStats(tokenCount: 0, responseTime: duration)
        return AIResponse(text: text, processingTime: duration, tokenCount: 0, metadata: metadata)
    }

    override func generateStreamingResponse(query: String, context: String?, conversationHistory: [ConversationMessage], model: AIModel?) async throws -> AsyncThrowingStream<String, Error> {
        try preflightCircuitBreaker()
        let request = try request(query: query, context: context, history: conversationHistory, model: model, streaming: true)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let id = UUID()
            let task = Task { @MainActor in
                defer { streams.removeValue(forKey: id) }
                do {
                    let connection = try await transport.lines(for: request)
                    defer { connection.cancel() }
                    try Task.checkCancellation()
                    try validate(connection.response)
                    var receivedText = false
                    var count = 0
                    for try await line in connection.lines {
                        try Task.checkCancellation()
                        guard !revoked, isInitialized else { throw Self.configurationChanged }
                        count += line.utf8.count
                        guard count <= CompatibleURLSessionTransport.maximumResponseBytes else { throw CompatibleURLSessionTransport.tooLarge }
                        guard line.hasPrefix("data:") else { continue }
                        let value = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if value == "[DONE]" { break }
                        guard let data = value.data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if event["error"] != nil { throw AIProviderError.providerSpecificError("The API interrupted the response.") }
                        guard let choices = event["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String, !text.isEmpty else { continue }
                        receivedText = true
                        switch continuation.yield(text) {
                        case .enqueued: break
                        case .dropped: throw CompatibleURLSessionTransport.tooLarge
                        case .terminated: throw CancellationError()
                        @unknown default: throw CancellationError()
                        }
                    }
                    try Task.checkCancellation()
                    guard receivedText else { throw AIProviderError.providerSpecificError("The API returned no text.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            streams[id] = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    override func generateRawResponse(prompt: String, model: AIModel?) async throws -> String {
        try await generateResponse(query: prompt, context: nil, conversationHistory: [], model: model).text
    }

    override func summarizeConversation(_ messages: [ConversationMessage], model: AIModel?) async throws -> String {
        let source = messages.suffix(10).map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        return try await generateRawResponse(prompt: "Summarize this quoted conversation.\n" + AIContextPolicy.sourceMessage(source), model: model)
    }
}
