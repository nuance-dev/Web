import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Main-actor ownership protects loader state. ModelContainer isolates inference work.
@MainActor
final class SimplifiedMLXRunner: ObservableObject {
    static let shared = SimplifiedMLXRunner()
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: Float = 0

    private var modelContainer: ModelContainer?
    private var currentModelID: String?
    private var pendingLoad: (id: UUID, modelID: String, task: Task<Void, Error>)?

    private init() {}

    /// Every caller for the same model awaits one load, including across browser windows.
    func ensureLoaded(modelId: String = LocalModelDefaults.repositoryID) async throws {
        if let pending = pendingLoad {
            do { try await pending.task.value }
            catch {
                if pendingLoad?.id == pending.id { pendingLoad = nil }
                if pending.modelID == modelId { throw error }
            }
            if pendingLoad?.id == pending.id { pendingLoad = nil }
        }
        try Task.checkCancellation()
        if modelContainer != nil && currentModelID == modelId { return }
        // A different waiter may have started the next load while this caller resumed.
        if pendingLoad != nil { try await ensureLoaded(modelId: modelId); return }

        let configuration = Self.configuration(for: modelId)
        let id = UUID()
        let task = Task { @MainActor in
            isLoading = true
            loadProgress = 0
            defer { isLoading = false }
            let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { progress in
                Task { @MainActor in self.loadProgress = Float(progress.fractionCompleted) }
            }
            try Task.checkCancellation()
            modelContainer = container
            currentModelID = modelId
            loadProgress = 1
        }
        pendingLoad = (id, modelId, task)
        defer { if pendingLoad?.id == id { pendingLoad = nil } }
        try await task.value
        try Task.checkCancellation()
    }

    nonisolated static func configuration(for modelID: String) -> ModelConfiguration {
        switch modelID {
        case LocalModelDefaults.repositoryID: return LLMRegistry.gemma3_1B_qat_4bit
        case "llama3_2_1B_4bit": return LLMRegistry.llama3_2_1B_4bit
        case "llama3_2_3B_4bit": return LLMRegistry.llama3_2_3B_4bit
        case "gemma3_2B_4bit": return ModelConfiguration(id: "mlx-community/gemma-2-2b-it-4bit")
        case "gemma3_9B_4bit": return ModelConfiguration(id: "mlx-community/gemma-2-9b-it-4bit")
        default:
            return modelID.hasPrefix("/")
                ? ModelConfiguration(directory: URL(fileURLWithPath: modelID))
                : ModelConfiguration(id: modelID)
        }
    }

    func generateWithPrompt(prompt: String, modelId: String = LocalModelDefaults.repositoryID) async throws -> String {
        try await ensureLoaded(modelId: modelId)
        guard let container = modelContainer else { throw SimplifiedMLXError.modelNotLoaded }
        return try await container.perform { context in
            try Task.checkCancellation()
            // The runtime applies the model's chat template exactly once.
            let input = try await context.processor.prepare(input: .init(prompt: prompt))
            try Task.checkCancellation()
            let result: GenerateResult = try MLXLMCommon.generate(input: input,
                parameters: GenerateParameters(maxTokens: 512, temperature: 0, topP: 1),
                context: context) { (_: [Int]) -> GenerateDisposition in
                Task.isCancelled ? .stop : .more
            }
            try Task.checkCancellation()
            guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SimplifiedMLXError.generationFailed("The model returned no text. Try again.")
            }
            return result.output
        }
    }

    func generateStreamWithPrompt(prompt: String, modelId: String = LocalModelDefaults.repositoryID) -> AsyncThrowingStream<String, Error> {
        LocalAIStream.make { continuation in
            try await self.ensureLoaded(modelId: modelId)
            guard let container = self.modelContainer else { throw SimplifiedMLXError.modelNotLoaded }
            try await container.perform { context in
                try Task.checkCancellation()
                let input = try await context.processor.prepare(input: .init(prompt: prompt))
                try Task.checkCancellation()
                var emittedLength = 0
                let result: GenerateResult = try MLXLMCommon.generate(input: input,
                    parameters: GenerateParameters(maxTokens: 512, temperature: 0, topP: 1),
                    context: context) { (tokens: [Int]) -> GenerateDisposition in
                    guard !Task.isCancelled else { return .stop }
                    let text = context.tokenizer.decode(tokens: tokens)
                    // Wait for a complete Unicode character before emitting its bytes.
                    if !text.hasSuffix("\u{FFFD}"), text.count > emittedLength {
                        continuation.yield(String(text.dropFirst(emittedLength)))
                        emittedLength = text.count
                    }
                    return .more
                }
                try Task.checkCancellation()
                if result.output.count > emittedLength {
                    continuation.yield(String(result.output.dropFirst(emittedLength)))
                }
                guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SimplifiedMLXError.generationFailed("The model returned no text. Try again.")
                }
            }
        }
    }

    /// Each generate call creates its own KV cache; weights need no reload between conversations.
    func resetConversation() async {}

    func clearModel() async {
        if let pending = pendingLoad {
            pending.task.cancel()
            try? await pending.task.value
            if pendingLoad?.id == pending.id { pendingLoad = nil }
        }
        modelContainer = nil
        currentModelID = nil
    }
}

/// Each stream owns its producer. Terminating any wrapper cancels the next layer.
@MainActor
enum LocalAIStream {
    static func make(_ produce: @escaping @MainActor (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    try await produce(continuation)
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
}

enum SimplifiedMLXError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "MLX model not loaded"
        case .generationFailed(let message): message
        }
    }
}
