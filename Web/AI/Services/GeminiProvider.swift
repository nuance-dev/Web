import Foundation

/// Google Gemini provider implementing the AIProvider protocol
/// Supports Gemini models with multimodal capabilities
@MainActor
class GeminiProvider: ExternalAPIProvider {

    // MARK: - AIProvider Implementation

    override var providerId: String { "google_gemini" }
    override var displayName: String { "Google Gemini" }

    // MARK: - Gemini Configuration

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    private let userAgent = "Web-Browser/1.0"

    // MARK: - Rate Limiting

    private var lastRequestTime: Date = Date.distantPast
    private let minimumRequestInterval: TimeInterval = 0.1  // 10 requests per second max

    init() {
        super.init(apiProviderType: .gemini)
    }

    // MARK: - Model Management

    override func loadAvailableModels() async {
        availableModels = AIModelCatalog.gemini
        restoreSelectedModel()
    }

    override func validateConfiguration() async throws {
        guard let apiKey else { throw AIProviderError.missingAPIKey(displayName) }
        try await validateModelsEndpoint(URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
                                         headers: ["x-goog-api-key": apiKey])
    }

    // MARK: - Core AI Methods

    override func generateResponse(
        query: String,
        context: String?,
        conversationHistory: [ConversationMessage],
        model: AIModel?
    ) async throws -> AIResponse {
        let startTime = Date()
        let modelId = model?.id ?? selectedModel?.id ?? "gemini-3.8-flash"

        // Apply rate limiting
        await applyRateLimit()

        // Build contents (respect per-provider context sharing preference)
        let effectiveContext = isContextSharingEnabled() ? context : nil
        let contents = buildContents(
            query: query, context: effectiveContext, history: conversationHistory)

        var payload: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 4096,
                "temperature": 0.7,
                "topP": 0.9,
                "topK": 40,
            ],
            "safetySettings": [
                [
                    "category": "HARM_CATEGORY_HARASSMENT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE",
                ],
                [
                    "category": "HARM_CATEGORY_HATE_SPEECH",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE",
                ],
                [
                    "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE",
                ],
                [
                    "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
                    "threshold": "BLOCK_MEDIUM_AND_ABOVE",
                ],
            ],
        ]

        payload["systemInstruction"] = ["parts": [["text": AIContextPolicy.systemInstruction]]]

        do {
            let response = try await makeAPIRequest(
                endpoint: "/models/\(modelId):generateContent",
                payload: payload
            )

            guard let candidates = response["candidates"] as? [[String: Any]],
                let firstCandidate = candidates.first,
                let content = firstCandidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let firstPart = parts.first,
                let text = firstPart["text"] as? String
            else {
                throw AIProviderError.providerSpecificError("Invalid response format from Gemini")
            }

            // Extract usage information
            var tokenCount = 0
            var cost: Double? = nil
            var promptTokens = 0
            var outputTokens = 0

            if let usageMetadata = response["usageMetadata"] as? [String: Any] {
                promptTokens = usageMetadata["promptTokenCount"] as? Int ?? 0
                outputTokens = usageMetadata["candidatesTokenCount"] as? Int ?? 0
                tokenCount = promptTokens + outputTokens
                cost = estimateCostUSD(
                    forModelId: modelId, promptTokens: promptTokens, completionTokens: outputTokens)
            }

            let responseTime = Date().timeIntervalSince(startTime)
            updateUsageStats(
                tokenCount: tokenCount,
                responseTime: responseTime,
                cost: cost,
                error: false
            )
            // Persist usage event
            AIUsageStore.shared.append(
                providerId: providerId,
                modelId: modelId,
                promptTokens: promptTokens,
                completionTokens: outputTokens,
                estimatedCostUSD: cost,
                success: true,
                latencyMs: Int(responseTime * 1000),
                contextIncluded: (effectiveContext != nil)
            )

            // Create metadata for external API response
            let metadata = ResponseMetadata(
                modelVersion: modelId,
                inferenceMethod: .fallback,
                contextUsed: effectiveContext != nil,
                processingSteps: [],
                memoryUsage: 0,
                energyImpact: responseTime > 5.0 ? .moderate : .low
            )

            // Return AIResponse compatible with existing system
            return AIResponse(
                text: text,
                processingTime: responseTime,
                tokenCount: tokenCount,
                metadata: metadata
            )

        } catch {
            let responseTime = Date().timeIntervalSince(startTime)
            updateUsageStats(tokenCount: 0, responseTime: responseTime, error: true)
            throw handleAPIError(error)
        }
    }

    override func generateStreamingResponse(
        query: String,
        context: String?,
        conversationHistory: [ConversationMessage],
        model: AIModel?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let modelId = model?.id ?? selectedModel?.id ?? "gemini-3.8-flash"

        // Apply rate limiting
        await applyRateLimit()

        // Build contents (respect per-provider context sharing preference)
        let effectiveContext = isContextSharingEnabled() ? context : nil
        let contents = buildContents(
            query: query, context: effectiveContext, history: conversationHistory)

        var payload: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 4096,
                "temperature": 0.7,
                "topP": 0.9,
                "topK": 40,
            ],
        ]

        payload["systemInstruction"] = ["parts": [["text": AIContextPolicy.systemInstruction]]]

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let startTime = Date()
                    var charCount = 0
                    let stream = try await makeStreamingAPIRequest(
                        endpoint: "/models/\(modelId):streamGenerateContent",
                        payload: payload
                    )

                    for try await chunk in stream {
                        charCount += chunk.count
                        continuation.yield(chunk)
                    }

                    // Log usage on finish (estimate tokens on streaming)
                    let estTokens = Int((Double(charCount) / 4.0).rounded())
                    let responseTime = Date().timeIntervalSince(startTime)
                    let estCost: Double? = nil // Partial token estimates cannot establish a bill.
                    // Update in-memory stats for settings view
                    updateUsageStats(
                        tokenCount: estTokens,
                        responseTime: responseTime,
                        cost: estCost,
                        error: false
                    )
                    AIUsageStore.shared.append(
                        providerId: providerId,
                        modelId: modelId,
                        promptTokens: 0,
                        completionTokens: estTokens,
                        estimatedCostUSD: estCost,
                        success: true,
                        latencyMs: Int(responseTime * 1000),
                        contextIncluded: (effectiveContext != nil)
                    )

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: handleAPIError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    override func generateRawResponse(
        prompt: String,
        model: AIModel?
    ) async throws -> String {
        let modelId = model?.id ?? selectedModel?.id ?? "gemini-3.8-flash"

        await applyRateLimit()

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.7,
            ],
        ]

        let response = try await makeAPIRequest(
            endpoint: "/models/\(modelId):generateContent",
            payload: payload
        )

        guard let candidates = response["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let firstPart = parts.first,
            let text = firstPart["text"] as? String
        else {
            throw AIProviderError.providerSpecificError("Invalid response format from Gemini")
        }

        return text
    }

    override func summarizeConversation(
        _ messages: [ConversationMessage],
        model: AIModel?
    ) async throws -> String {
        let conversationText = messages.map { "\($0.role.description): \($0.content)" }.joined(
            separator: "\n")

        let summaryPrompt = """
            Summarize the following conversation in 2-3 sentences, focusing on the main topics and outcomes:

            \(conversationText)

            Summary:
            """

        return try await generateRawResponse(prompt: summaryPrompt, model: model)
    }

    // MARK: - API Communication

    private func makeAPIRequest(
        endpoint: String,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        // Circuit breaker
        try preflightCircuitBreaker()

        guard let apiKey = apiKey else {
            throw AIProviderError.missingAPIKey(displayName)
        }

        // Keep API keys in headers, never request URLs.
        guard var urlComponents = URLComponents(string: baseURL + endpoint) else {
            throw AIProviderError.invalidConfiguration("Invalid API endpoint")
        }

        urlComponents.queryItems = endpoint.contains("streamGenerateContent") ? [URLQueryItem(name: "alt", value: "sse")] : nil

        guard let url = urlComponents.url else {
            throw AIProviderError.invalidConfiguration("Failed to construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw AIProviderError.invalidConfiguration("Failed to serialize request")
        }

        var lastError: Error?
        var lastStatus: Int?
        var lastResponse: HTTPURLResponse?
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await AIProviderNetwork.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIProviderError.networkError(URLError(.badServerResponse))
                }
                lastResponse = httpResponse

                switch httpResponse.statusCode {
                case 200...299:
                    recordRequestSuccess()
                    do {
                        guard
                            let json = try JSONSerialization.jsonObject(with: data)
                                as? [String: Any]
                        else {
                            throw AIProviderError.providerSpecificError("Invalid JSON response")
                        }
                        if let error = json["error"] as? [String: Any],
                            let message = error["message"] as? String
                        {
                            throw AIProviderError.providerSpecificError(
                                "Gemini API error: \(message)")
                        }
                        return json
                    } catch {
                        throw AIProviderError.providerSpecificError("Failed to parse response")
                    }
                case 400:
                    recordRequestFailure(httpStatus: 400)
                    throw AIProviderError.invalidConfiguration("Bad request to Gemini API")
                case 401:
                    recordRequestFailure(httpStatus: 401)
                    throw AIProviderError.authenticationFailed
                case 429, 500, 502, 503, 504:
                    lastStatus = httpResponse.statusCode
                    if attempt < maxAttempts {
                        let delay = backoffDelayForAttempt(attempt, response: httpResponse)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else {
                        recordRequestFailure(httpStatus: httpResponse.statusCode)
                        throw AIProviderError.providerSpecificError(
                            "HTTP \(httpResponse.statusCode)")
                    }
                default:
                    recordRequestFailure(httpStatus: httpResponse.statusCode)
                    throw AIProviderError.providerSpecificError("HTTP \(httpResponse.statusCode)")
                }
            } catch {
                recordRequestFailure(httpStatus: lastStatus)
                throw error
            }
        }
        recordRequestFailure(httpStatus: lastStatus)
        throw lastError ?? AIProviderError.providerSpecificError("Unknown error")
    }

    private func makeStreamingAPIRequest(
        endpoint: String,
        payload: [String: Any]
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Circuit breaker
        try preflightCircuitBreaker()

        guard let apiKey = apiKey else {
            throw AIProviderError.missingAPIKey(displayName)
        }

        // Keep API keys in headers, never request URLs.
        guard var urlComponents = URLComponents(string: baseURL + endpoint) else {
            throw AIProviderError.invalidConfiguration("Invalid API endpoint")
        }

        urlComponents.queryItems = endpoint.contains("streamGenerateContent") ? [URLQueryItem(name: "alt", value: "sse")] : nil

        guard let url = urlComponents.url else {
            throw AIProviderError.invalidConfiguration("Failed to construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let (bytes, response) = try await AIProviderNetwork.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                        httpResponse.statusCode == 200
                    else {
                        recordRequestFailure(httpStatus: (response as? HTTPURLResponse)?.statusCode)
                        throw AIProviderError.networkError(URLError(.badServerResponse))
                    }

                    recordRequestSuccess()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if !eventData.isEmpty,
                            let jsonData = eventData.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: jsonData)
                                as? [String: Any],
                            let candidates = json["candidates"] as? [[String: Any]],
                            let firstCandidate = candidates.first,
                            let content = firstCandidate["content"] as? [String: Any],
                            let parts = content["parts"] as? [[String: Any]],
                            let firstPart = parts.first,
                            let text = firstPart["text"] as? String
                        {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: handleAPIError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - Helper Methods

    func buildContents(query: String, context: String?, history: [ConversationMessage]) -> [[String: Any]] {
        AIContextPolicy.messages(query: query, context: context, history: history)
            .filter { $0["role"] != "system" }
            .map { ["role": $0["role"] == "assistant" ? "model" : "user", "parts": [["text": $0["content"]!]]] }
    }

    private func applyRateLimit() async {
        let timeSinceLastRequest = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLastRequest < minimumRequestInterval {
            let delay = minimumRequestInterval - timeSinceLastRequest
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    private func handleAPIError(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            return AIProviderError.networkError(urlError)
        }
        return AIProviderError.providerSpecificError(error.localizedDescription)
    }

    // MARK: - Settings

    override func getConfigurableSettings() -> [AIProviderSetting] {
        return [
            AIProviderSetting(
                id: "model_selection",
                name: "Model",
                description: "Select the Gemini model to use",
                type: .selection(availableModels.map { $0.name }),
                defaultValue: "Gemini 3.8 Flash",
                currentValue: selectedModel?.name ?? "Gemini 3.8 Flash",
                isRequired: true
            ),
            AIProviderSetting(
                id: "temperature",
                name: "Temperature",
                description: "Controls randomness in responses (0.0-2.0)",
                type: .number,
                defaultValue: 0.7,
                currentValue: 0.7,
                isRequired: false
            ),
            AIProviderSetting(
                id: "top_k",
                name: "Top K",
                description: "Limits token selection to top K candidates",
                type: .number,
                defaultValue: 40,
                currentValue: 40,
                isRequired: false
            ),
        ]
    }
}
