import Foundation

/// Text-only Chat Completions adapter. Model tools are deliberately not exposed.
@MainActor
final class OpenAIProvider: ExternalAPIProvider {
    override var providerId: String { "openai" }
    override var displayName: String { "OpenAI" }
    private let baseURL = "https://api.openai.com/v1"

    init() { super.init(apiProviderType: .openai) }

    override func loadAvailableModels() async {
        availableModels = AIModelCatalog.openAI
        restoreSelectedModel()
    }

    override func validateConfiguration() async throws {
        guard let apiKey else { throw AIProviderError.missingAPIKey(displayName) }
        try await validateModelsEndpoint(URL(string: baseURL + "/models")!,
                                         headers: ["Authorization": "Bearer \(apiKey)"])
    }

    /// Shared request construction is tested without network access or credentials.
    static func payload(modelID: String, query: String, context: String?,
                        history: [ConversationMessage], streaming: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": AIContextPolicy.messages(query: query, context: context, history: history),
            "max_completion_tokens": 4096,
            "store": false,
            "reasoning_effort": "low"
        ]
        if streaming {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        // GPT-6 does not support sampling parameters or reasoning_effort=none.
        return body
    }

    private func request(body: [String: Any]) throws -> URLRequest {
        try preflightCircuitBreaker()
        try Task.checkCancellation()
        guard let apiKey else { throw AIProviderError.missingAPIKey(displayName) }
        var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            recordRequestFailure(httpStatus: http.statusCode)
            switch http.statusCode {
            case 401, 403: throw AIProviderError.authenticationFailed
            case 429: throw AIProviderError.rateLimitExceeded
            case 400, 404:
                throw AIProviderError.providerSpecificError("This model is unavailable for your account or request. Choose another model in AI settings.")
            default: throw AIProviderError.providerSpecificError("OpenAI unavailable (HTTP \(http.statusCode)). Try again.")
            }
        }
        recordRequestSuccess()
    }

    @discardableResult
    private func recordUsage(_ usage: [String: Any]?, modelID: String, start: Date,
                             contextIncluded: Bool, fallbackOutput: Int = 0) -> Int {
        let input = usage?["prompt_tokens"] as? Int ?? 0
        let output = usage?["completion_tokens"] as? Int ?? fallbackOutput
        let count = usage?["total_tokens"] as? Int ?? (input + output)
        // Unknown or interrupted usage is not advertised as a complete cost estimate.
        let cost = usage == nil ? nil : estimateCostUSD(forModelId: modelID, promptTokens: input, completionTokens: output)
        let latency = Date().timeIntervalSince(start)
        updateUsageStats(tokenCount: count, responseTime: latency, cost: cost)
        AIUsageStore.shared.append(providerId: providerId, modelId: modelID,
                                   promptTokens: input, completionTokens: output,
                                   estimatedCostUSD: cost, success: true,
                                   latencyMs: Int(latency * 1000), contextIncluded: contextIncluded)
        return count
    }

    override func generateResponse(query: String, context: String?,
                                   conversationHistory: [ConversationMessage], model: AIModel?) async throws -> AIResponse {
        let start = Date()
        let modelID = model?.id ?? selectedModel?.id ?? AIModelCatalog.openAI[0].id
        let source = isContextSharingEnabled() ? context : nil
        let body = Self.payload(modelID: modelID, query: query, context: source,
                                history: conversationHistory, streaming: false)
        let (data, response) = try await AIProviderNetwork.session.data(for: request(body: body))
        try validate(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw AIProviderError.providerSpecificError("The model returned no text. Try a shorter question.")
        }
        let count = recordUsage(json["usage"] as? [String: Any], modelID: modelID,
                                start: start, contextIncluded: source != nil)
        let elapsed = Date().timeIntervalSince(start)
        let metadata = ResponseMetadata(modelVersion: modelID, inferenceMethod: .fallback,
                                        contextUsed: source != nil, processingSteps: [], memoryUsage: 0,
                                        energyImpact: elapsed > 5 ? .moderate : .low)
        return AIResponse(text: text, processingTime: elapsed, tokenCount: count, metadata: metadata)
    }

    override func generateStreamingResponse(query: String, context: String?,
                                            conversationHistory: [ConversationMessage], model: AIModel?) async throws -> AsyncThrowingStream<String, Error> {
        let modelID = model?.id ?? selectedModel?.id ?? AIModelCatalog.openAI[0].id
        let source = isContextSharingEnabled() ? context : nil
        let body = Self.payload(modelID: modelID, query: query, context: source,
                                history: conversationHistory, streaming: true)
        let request = try request(body: body)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let start = Date()
                var usage: [String: Any]?
                var receivedText = false
                do {
                    let (bytes, response) = try await AIProviderNetwork.session.bytes(for: request)
                    try validate(response)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if value == "[DONE]" { break }
                        guard let data = value.data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if event["error"] != nil { throw AIProviderError.providerSpecificError("OpenAI interrupted the response. Try again.") }
                        if let finalUsage = event["usage"] as? [String: Any] { usage = finalUsage }
                        if let choices = event["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty {
                            receivedText = true
                            continuation.yield(text)
                        }
                    }
                    guard receivedText else { throw AIProviderError.providerSpecificError("The model returned no text. Try a shorter question.") }
                    recordUsage(usage, modelID: modelID, start: start, contextIncluded: source != nil)
                    continuation.finish()
                } catch {
                    updateUsageStats(tokenCount: 0, responseTime: Date().timeIntervalSince(start), error: true)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    override func generateRawResponse(prompt: String, model: AIModel?) async throws -> String {
        try await generateResponse(query: prompt, context: nil, conversationHistory: [], model: model).text
    }

    override func summarizeConversation(_ messages: [ConversationMessage], model: AIModel?) async throws -> String {
        let text = messages.suffix(20).map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        return try await generateRawResponse(prompt: "Summarize this quoted conversation in two sentences.\n" + AIContextPolicy.sourceMessage(text), model: model)
    }
}
