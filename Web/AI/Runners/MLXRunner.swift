import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// Box moved to separate file for reuse

/// Role enum compatible with MLX implementation
enum MLXRole: String, CaseIterable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    
    // Compatibility with existing LLM.swift Role enum
    static var bot: MLXRole { .assistant }
}

/// MLX-based LLM runner using Apple's MLX framework for optimal Apple Silicon performance
/// Features persistent model caching and unified memory architecture benefits
@MainActor
final class MLXRunner: ObservableObject {
    static let shared = MLXRunner()
    
    // OPTIMIZATION: Persistent model context caching to avoid reloading models between app launches
    @Published var isLoading = false
    @Published var loadProgress: Float = 0.0
    
    private var modelContainer: ModelContainer?
    private var currentModelConfiguration: ModelConfiguration?
    private var loadContinuation: [CheckedContinuation<Void, Error>] = []
    
    // ENHANCED: Persistent model metadata to check if we can reuse cached model
    private let modelCacheDirectory: URL
    private let modelMetadataFile: URL
    
    // OPTIMIZATION: Conversation state management for multi-turn chat
    // Thread-safe with proper synchronization
    private let queue = DispatchQueue(label: "com.web.mlxrunner", qos: .userInitiated)
    private var _conversationHistory: [(role: MLXRole, content: String)] = []
    private var _conversationTokenCount: Int = 0
    private let maxConversationTokens: Int = 2400 // Enhanced: Increased for larger context windows
    
    private var conversationHistory: [(role: MLXRole, content: String)] {
        get { queue.sync { _conversationHistory } }
        set { queue.sync { _conversationHistory = newValue } }
    }
    
    private var conversationTokenCount: Int {
        get { queue.sync { _conversationTokenCount } }
        set { queue.sync { _conversationTokenCount = newValue } }
    }

    // Fallback model configurations for Hugging Face downloads
    private static let fallbackModelConfigurations: [String: ModelConfiguration] = [
        LocalModelDefaults.repositoryID: LLMRegistry.gemma3_1B_qat_4bit,
        "gemma-3-2b": LLMRegistry.gemma3_1B_qat_4bit, // Migrate the old nonexistent ID.
        "gemma-3-1b": ModelConfiguration(
            id: "mlx-community/gemma-3-1b-it-4bit"
        )
    ]

    private init() {
        // Set up persistent model cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        modelCacheDirectory = cacheDir.appendingPathComponent("MLXCache", isDirectory: true)
        modelMetadataFile = modelCacheDirectory.appendingPathComponent("mlx_model_metadata.json")
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: modelCacheDirectory, withIntermediateDirectories: true)
        
        // Configure MLX GPU cache for optimal performance
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024) // 20MB cache limit
        
        NSLog("📁 MLX cache directory: \(modelCacheDirectory.path)")
    }

    /// Ensures MLX model is loaded with persistent caching between app launches
    func ensureLoaded(modelKey: String = LocalModelDefaults.repositoryID) async throws {
        // Try to create model configuration from path or fallback to Hugging Face
        let modelConfig: ModelConfiguration
        
        if modelKey.hasPrefix("/") {
            // Direct path to local model
            modelConfig = ModelConfiguration(directory: URL(fileURLWithPath: modelKey))
        } else if let fallbackConfig = Self.fallbackModelConfigurations[modelKey] {
            // Use fallback Hugging Face model
            modelConfig = fallbackConfig
        } else {
            throw MLXError.invalidModel("Model configuration not found: \(modelKey)")
        }
        
        // If already loaded with same model, return immediately
        if modelContainer != nil && currentModelConfiguration?.id == modelConfig.id {
            NSLog("♻️ MLX model already loaded in memory, reusing existing instance...")
            return
        }
        
        if isLoading {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadContinuation.append(continuation)
            }
            return
        }
        
        isLoading = true
        loadProgress = 0.0
        defer { 
            isLoading = false
            for cont in loadContinuation { cont.resume() }
            loadContinuation.removeAll()
        }

        // Check if we can reuse a previously loaded model
        if let cachedMetadata = loadModelMetadata(),
           cachedMetadata.modelId == String(describing: modelConfig.id),
           cachedMetadata.isValid() {
            NSLog("💾 Found valid cached MLX model metadata, attempting quick reload...")
            
            // Try to reinitialize the model quickly
            do {
                loadProgress = 0.5
                let context = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
                    Task { @MainActor in
                        self.loadProgress = Float(progress.fractionCompleted)
                    }
                }
                
                self.modelContainer = context
                self.currentModelConfiguration = modelConfig
                loadProgress = 1.0
                
                NSLog("🚀 MLX model reloaded from cache: \(modelConfig.id)")
                return
            } catch {
                NSLog("⚠️ Cached MLX model reload failed, falling back to full load: \(error)")
            }
        }

        NSLog("🚀 Loading MLX model from Hugging Face: \(modelConfig.id)")
        
        do {
            // Load model with progress tracking
            let context = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
                Task { @MainActor in
                    self.loadProgress = Float(progress.fractionCompleted)
                }
            }
            
            self.modelContainer = context
            self.currentModelConfiguration = modelConfig
            self.loadProgress = 1.0
            
            // Save model metadata for next app launch
            saveModelMetadata(for: modelConfig)
            
            NSLog("✅ MLX model loaded successfully: \(modelConfig.id)")
        } catch {
            NSLog("❌ Failed to load MLX model: \(error)")
            throw MLXError.loadingFailed("Failed to load MLX model: \(error.localizedDescription)")
        }
    }

    /// Generate a complete response with raw prompt (bypasses conversation preprocessing)
    nonisolated func generateWithPrompt(prompt: String, modelKey: String = LocalModelDefaults.repositoryID) async throws -> String {
        try await ensureLoaded(modelKey: modelKey)
        
        guard await modelContainer != nil else { 
            throw MLXError.modelNotLoaded("MLX model not properly initialized")
        }
        
        NSLog("🤖 Generating response with RAW prompt using MLX...")
        
        return try await withThrowingTaskGroup(of: String?.self) { group in
            // Main generation task using raw prompt
            group.addTask {
                return await self.performGeneration(prompt: prompt)
            }
            
            // Timeout task (30 seconds for non-streaming)
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                return nil
            }
            
            // Return the first completed result
            guard let result = try await group.next() else {
                throw MLXError.generationFailed("No result from generation task")
            }
            
            group.cancelAll()
            
            return result ?? "Response generation timed out after 30 seconds. Please try again or use streaming mode."
        }
    }
    
    /// Internal method to perform MLX generation
    private func performGeneration(prompt: String) async -> String? {
        guard let container = await modelContainer else { return nil }
        
        do {
            let result = try await container.perform { modelContext in
                let input = try await modelContext.processor.prepare(input: .init(prompt: prompt))
                let parameters = GenerateParameters(
                    maxTokens: 512,
                    temperature: 0.7,
                    topP: 0.9
                )
                
                var fullResponse = ""
                
                let _ = try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: modelContext
                ) { tokens in
                    // Convert tokens to text for final response
                    let text = modelContext.tokenizer.decode(tokens: tokens)
                    fullResponse += text
                    return .more
                }
                
                return fullResponse
            }
            
            NSLog("✅ MLX RAW prompt response generated: \(result.count) characters")
            return result
        } catch {
            NSLog("❌ MLX generation failed: \(error)")
            return nil
        }
    }

    /// Generate a complete response for the given prompt with conversation history
    nonisolated func generate(prompt: String, maxTokens: Int = 512, temperature: Float = 0.7, modelKey: String = LocalModelDefaults.repositoryID) async throws -> String {
        try await ensureLoaded(modelKey: modelKey)
        
        guard await modelContainer != nil else { 
            throw MLXError.modelNotLoaded("MLX model not properly initialized")
        }
        
        NSLog("🤖 Generating response with MLX (with conversation context)...")
        
        // Build conversation context
        let conversationPrompt = await buildConversationPrompt(userPrompt: prompt)
        
        return try await withThrowingTaskGroup(of: String?.self) { group in
            // Main generation task
            group.addTask {
                return await self.performGeneration(prompt: conversationPrompt)
            }
            
            // Timeout task (30 seconds for non-streaming)
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                return nil
            }
            
            // Return the first completed result
            guard let result = try await group.next() else {
                throw MLXError.generationFailed("No result from generation task")
            }
            
            group.cancelAll()
            
            let response = result ?? "Response generation timed out after 30 seconds. Please try again or use streaming mode."
            
            // Update conversation history
            await addToConversationHistory(userPrompt: prompt, response: response)
            
            NSLog("✅ MLX response generated: \(response.count) characters")
            return response
        }
    }

    /// Generate a streaming response with raw prompt
    nonisolated func generateStreamWithPrompt(prompt: String, modelKey: String = LocalModelDefaults.repositoryID) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await ensureLoaded(modelKey: modelKey)
                    
                    guard await modelContainer != nil else {
                        continuation.finish(throwing: MLXError.modelNotLoaded("MLX model not properly initialized"))
                        return
                    }
                    
                    NSLog("🌊 Starting MLX streaming with RAW prompt...")
                    
                    await performStreamingGeneration(
                        prompt: prompt,
                        continuation: continuation
                    )
                    
                } catch {
                    NSLog("❌ MLX RAW prompt streaming failed: \(error)")
                    
                    let errorMessage: String
                    if error.localizedDescription.contains("memory") {
                        errorMessage = "AI response failed due to memory constraints. Try a shorter query or restart the app."
                    } else if error.localizedDescription.contains("timeout") {
                        errorMessage = "AI response timed out. Please try a shorter query."
                    } else {
                        errorMessage = "AI response failed: \(error.localizedDescription)"
                    }
                    
                    continuation.finish(throwing: MLXError.streamingFailed(errorMessage))
                }
            }
        }
    }

    /// Generate a streaming response with conversation context
    nonisolated func generateStream(prompt: String, maxTokens: Int = 512, temperature: Float = 0.7, modelKey: String = LocalModelDefaults.repositoryID) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await ensureLoaded(modelKey: modelKey)
                    
                    guard await modelContainer != nil else {
                        continuation.finish(throwing: MLXError.modelNotLoaded("MLX model not properly initialized"))
                        return
                    }
                    
                    NSLog("🌊 Starting MLX streaming response...")
                    
                    // Build conversation context
                    let conversationPrompt = await buildConversationPrompt(userPrompt: prompt)
                    
                    await performStreamingGeneration(
                        prompt: conversationPrompt,
                        continuation: continuation
                    )
                    
                } catch {
                    NSLog("❌ MLX streaming failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Internal method to perform streaming generation with MLX
    private func performStreamingGeneration(
        prompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        guard let container = modelContainer else {
            continuation.finish(throwing: MLXError.modelNotLoaded("Model context not available"))
            return
        }
        
        do {
            try await container.perform { modelContext in
                let input = try await modelContext.processor.prepare(input: .init(prompt: prompt))
                let parameters = GenerateParameters(
                    maxTokens: 512,
                    temperature: 0.7,
                    topP: 0.9
                )
                
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: modelContext.tokenizer)
                var fullResponse = ""
                
                let _ = try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: modelContext
                ) { tokens in
                    if let token = tokens.last {
                        detokenizer.append(token: token)
                        if let text = detokenizer.next() {
                            fullResponse += text
                            continuation.yield(text)
                        }
                    }
                    return .more
                }
                
                // Update conversation history after streaming completes
                Task {
                    await self.addToConversationHistory(userPrompt: prompt, response: fullResponse)
                }
            }
            
            continuation.finish()
            NSLog("✅ MLX streaming response completed")
            
        } catch {
            NSLog("❌ MLX streaming generation failed: \(error)")
            continuation.finish(throwing: MLXError.streamingFailed("Streaming generation failed: \(error.localizedDescription)"))
        }
    }
    
    /// Build conversation prompt with history for better context
    private func buildConversationPrompt(userPrompt: String) async -> String {
        let history = conversationHistory
        
        var conversationContext = ""
        
        // Add conversation history
        for entry in history {
            switch entry.role {
            case .user:
                conversationContext += "User: \(entry.content)\n"
            case .assistant, .system:
                conversationContext += "Assistant: \(entry.content)\n"
            }
        }
        
        // Add current prompt
        conversationContext += "User: \(userPrompt)\nAssistant:"
        
        return conversationContext
    }
    
    /// Helper method to safely update conversation history
    private func addToConversationHistory(userPrompt: String, response: String) async {
        let userChat: (role: MLXRole, content: String) = (.user, userPrompt)
        let assistantChat: (role: MLXRole, content: String) = (.assistant, response)
        
        // Enhanced: More accurate token estimation for larger contexts
        let estimatedTokens = Int(Double(userPrompt.count + response.count) / 3.5)
        
        queue.sync {
            if _conversationTokenCount + estimatedTokens > maxConversationTokens {
                NSLog("🔄 Resetting conversation context due to token limit")
                _conversationHistory.removeAll()
                _conversationTokenCount = 0
            }
            
            _conversationHistory.append(userChat)
            _conversationHistory.append(assistantChat)
            _conversationTokenCount += estimatedTokens
        }
    }
    
    /// Clear loaded model to free memory (but keep metadata cache for next launch)
    func clearModel() async {
        self.modelContainer = nil
        self.currentModelConfiguration = nil
        self.conversationHistory.removeAll()
        self.conversationTokenCount = 0
        NSLog("🗑️ MLX model cleared from memory (metadata cache preserved)")
    }
    
    /// Reset conversation history (useful for new chat sessions)
    func resetConversation() async {
        self.conversationHistory.removeAll()
        self.conversationTokenCount = 0
        NSLog("🔄 Conversation history reset")
    }
    
    // MARK: - Persistent Model Caching
    
    /// Save model metadata to persist between app launches
    private func saveModelMetadata(for modelConfig: ModelConfiguration) {
        do {
            let metadata = MLXModelMetadata(
                modelId: String(describing: modelConfig.id),
                cacheTimestamp: Date()
            )
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            
            try data.write(to: modelMetadataFile)
            NSLog("💾 MLX model metadata saved: \(modelConfig.id)")
        } catch {
            NSLog("⚠️ Failed to save MLX model metadata: \(error)")
        }
    }
    
    /// Load model metadata from previous app launches
    private func loadModelMetadata() -> MLXModelMetadata? {
        guard FileManager.default.fileExists(atPath: modelMetadataFile.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: modelMetadataFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(MLXModelMetadata.self, from: data)
            NSLog("💾 MLX model metadata loaded from cache")
            return metadata
        } catch {
            NSLog("⚠️ Failed to load MLX model metadata: \(error)")
            return nil
        }
    }
}

// MARK: - Model Metadata for Persistent Caching

/// Metadata about a loaded MLX model to enable smart caching between app launches
struct MLXModelMetadata: Codable {
    let modelId: String
    let cacheTimestamp: Date
    
    /// Check if this cached metadata is still valid
    func isValid() -> Bool {
        // Cache is valid for 7 days
        let cacheAge = Date().timeIntervalSince(cacheTimestamp)
        let cacheValid = cacheAge < (7 * 24 * 60 * 60) // 7 days in seconds
        
        return cacheValid
    }
}

// MARK: - Errors

enum MLXError: LocalizedError {
    case invalidModel(String)
    case modelNotLoaded(String)
    case loadingFailed(String)
    case generationFailed(String)
    case streamingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidModel(let message):
            return "Invalid Model: \(message)"
        case .modelNotLoaded(let message):
            return "Model Not Loaded: \(message)"
        case .loadingFailed(let message):
            return "Loading Failed: \(message)"
        case .generationFailed(let message):
            return "Generation Failed: \(message)"
        case .streamingFailed(let message):
            return "Streaming Failed: \(message)"
        }
    }
}