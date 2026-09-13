import Foundation

/// AI response model containing generated text and metadata
/// Supports streaming responses and context references
struct AIResponse {
    
    // MARK: - Core Properties
    
    let text: String
    let timestamp: Date
    let processingTime: TimeInterval
    let tokenCount: Int
    let metadata: ResponseMetadata
    
    // MARK: - Initialization
    
    init(
        text: String,
        processingTime: TimeInterval,
        tokenCount: Int,
        metadata: ResponseMetadata? = nil
    ) {
        self.text = text
        self.timestamp = Date()
        self.processingTime = processingTime
        self.tokenCount = tokenCount
        self.metadata = metadata ?? ResponseMetadata()
    }
    
    // MARK: - Convenience Properties
    
    /// Whether this response contains tab references
    var containsTabReferences: Bool {
        return !metadata.referencedTabs.isEmpty
    }
    
    /// Whether this response is based on current context
    var hasContext: Bool {
        return metadata.contextUsed
    }
    
    /// Tokens per second inference speed
    var tokensPerSecond: Double {
        guard processingTime > 0 else { return 0 }
        return Double(tokenCount) / processingTime
    }
    
    /// Response quality score (0-1)
    var qualityScore: Double {
        return metadata.qualityMetrics.overallScore
    }
}

// MARK: - Response Metadata

struct ResponseMetadata {
    let modelVersion: String
    let inferenceMethod: InferenceMethod
    let contextUsed: Bool
    let referencedTabs: [TabReference]
    let referencedHistory: [HistoryReference]
    let qualityMetrics: QualityMetrics
    let processingSteps: [ProcessingStep]
    let memoryUsage: Int // bytes
    let energyImpact: EnergyImpact
    
    init(
        modelVersion: String = LocalModelDefaults.repositoryID,
        inferenceMethod: InferenceMethod = .mlx,
        contextUsed: Bool = false,
        referencedTabs: [TabReference] = [],
        referencedHistory: [HistoryReference] = [],
        qualityMetrics: QualityMetrics = QualityMetrics(),
        processingSteps: [ProcessingStep] = [],
        memoryUsage: Int = 0,
        energyImpact: EnergyImpact = .low
    ) {
        self.modelVersion = modelVersion
        self.inferenceMethod = inferenceMethod
        self.contextUsed = contextUsed
        self.referencedTabs = referencedTabs
        self.referencedHistory = referencedHistory
        self.qualityMetrics = qualityMetrics
        self.processingSteps = processingSteps
        self.memoryUsage = memoryUsage
        self.energyImpact = energyImpact
    }
}

// MARK: - Supporting Types

enum InferenceMethod: String, CaseIterable {
    case mlx = "MLX"
    case llamaCpp = "llama.cpp"
    case fallback = "fallback"
    
    var description: String {
        switch self {
        case .mlx:
            return "Apple MLX Framework"
        case .llamaCpp:
            return "llama.cpp (CPU)"
        case .fallback:
            return "Fallback Implementation"
        }
    }
}

struct TabReference: Identifiable {
    let id: String
    let url: URL
    let title: String
    let relevanceScore: Double // 0-1
    let contentSummary: String
    
    init(id: String, url: URL, title: String, relevanceScore: Double = 0.5, contentSummary: String = "") {
        self.id = id
        self.url = url
        self.title = title
        self.relevanceScore = max(0, min(1, relevanceScore))
        self.contentSummary = contentSummary
    }
}

struct HistoryReference {
    let url: URL
    let title: String
    let visitDate: Date
    let relevanceScore: Double // 0-1
    
    init(url: URL, title: String, visitDate: Date, relevanceScore: Double = 0.5) {
        self.url = url
        self.title = title
        self.visitDate = visitDate
        self.relevanceScore = max(0, min(1, relevanceScore))
    }
}

struct QualityMetrics {
    let overallScore: Double
    let coherence: Double
    let relevance: Double
    let factualAccuracy: Double
    let helpfulness: Double
    let confidence: Double
    
    init(
        overallScore: Double = 0.8,
        coherence: Double = 0.8,
        relevance: Double = 0.8,
        factualAccuracy: Double = 0.8,
        helpfulness: Double = 0.8,
        confidence: Double = 0.8
    ) {
        self.overallScore = max(0, min(1, overallScore))
        self.coherence = max(0, min(1, coherence))
        self.relevance = max(0, min(1, relevance))
        self.factualAccuracy = max(0, min(1, factualAccuracy))
        self.helpfulness = max(0, min(1, helpfulness))
        self.confidence = max(0, min(1, confidence))
    }
}

struct ProcessingStep {
    let name: String
    let duration: TimeInterval
    let description: String
    let timestamp: Date
    
    init(name: String, duration: TimeInterval, description: String = "") {
        self.name = name
        self.duration = duration
        self.description = description
        self.timestamp = Date()
    }
}

enum EnergyImpact: String, CaseIterable {
    case minimal = "minimal"
    case low = "low"
    case moderate = "moderate"
    case high = "high"
    
    var description: String {
        switch self {
        case .minimal:
            return "Minimal impact"
        case .low:
            return "Low energy usage"
        case .moderate:
            return "Moderate energy usage"
        case .high:
            return "High energy usage"
        }
    }
    
    var batteryImpactMinutes: Double {
        switch self {
        case .minimal:
            return 0.5
        case .low:
            return 1.0
        case .moderate:
            return 3.0
        case .high:
            return 8.0
        }
    }
}

// MARK: - Streaming Response

/// Streaming AI response for real-time updates
class StreamingAIResponse: ObservableObject {
    
    @Published var currentText: String = ""
    @Published var isComplete: Bool = false
    @Published var error: Error?
    
    private let startTime: Date
    private var tokenCount: Int = 0
    private var processingSteps: [ProcessingStep] = []
    
    init() {
        self.startTime = Date()
    }
    
    /// Add new text chunk to the streaming response
    func appendChunk(_ chunk: String) {
        currentText += chunk
        tokenCount += estimateTokens(chunk)
    }
    
    /// Mark the streaming response as complete
    func complete(with metadata: ResponseMetadata? = nil) {
        isComplete = true
        
        let _ = metadata ?? ResponseMetadata(
            processingSteps: processingSteps,
            memoryUsage: 0,
            energyImpact: .low
        )
        
        // Could emit final AIResponse here if needed
        NSLog("✅ Streaming response completed: \(tokenCount) tokens in \(Date().timeIntervalSince(startTime))s")
    }
    
    /// Mark the streaming response as failed
    func fail(with error: Error) {
        self.error = error
        isComplete = true
        NSLog("❌ Streaming response failed: \(error)")
    }
    
    /// Add a processing step for debugging
    func addProcessingStep(_ step: ProcessingStep) {
        processingSteps.append(step)
    }
    
    /// Get current response as AIResponse
    func toAIResponse(metadata: ResponseMetadata? = nil) -> AIResponse {
        return AIResponse(
            text: currentText,
            processingTime: Date().timeIntervalSince(startTime),
            tokenCount: tokenCount,
            metadata: metadata
        )
    }
    
    private func estimateTokens(_ text: String) -> Int {
        return TokenEstimator.estimateTokens(for: text)
    }
}

// MARK: - Response Builder

class AIResponseBuilder {
    private var text: String = ""
    private var processingSteps: [ProcessingStep] = []
    private var referencedTabs: [TabReference] = []
    private var referencedHistory: [HistoryReference] = []
    private var contextUsed: Bool = false
    private var memoryUsage: Int = 0
    private let startTime: Date
    
    init() {
        self.startTime = Date()
    }
    
    func setText(_ text: String) -> AIResponseBuilder {
        self.text = text
        return self
    }
    
    func addProcessingStep(_ step: ProcessingStep) -> AIResponseBuilder {
        processingSteps.append(step)
        return self
    }
    
    func addTabReference(_ reference: TabReference) -> AIResponseBuilder {
        referencedTabs.append(reference)
        return self
    }
    
    func addHistoryReference(_ reference: HistoryReference) -> AIResponseBuilder {
        referencedHistory.append(reference)
        return self
    }
    
    func setContextUsed(_ used: Bool) -> AIResponseBuilder {
        contextUsed = used
        return self
    }
    
    func setMemoryUsage(_ usage: Int) -> AIResponseBuilder {
        memoryUsage = usage
        return self
    }
    
    func build() -> AIResponse {
        let processingTime = Date().timeIntervalSince(startTime)
        let tokenCount = TokenEstimator.estimateTokens(for: text)
        
        let metadata = ResponseMetadata(
            contextUsed: contextUsed,
            referencedTabs: referencedTabs,
            referencedHistory: referencedHistory,
            processingSteps: processingSteps,
            memoryUsage: memoryUsage,
            energyImpact: calculateEnergyImpact(processingTime: processingTime, tokenCount: tokenCount)
        )
        
        return AIResponse(
            text: text,
            processingTime: processingTime,
            tokenCount: tokenCount,
            metadata: metadata
        )
    }
    
    private func calculateEnergyImpact(processingTime: TimeInterval, tokenCount: Int) -> EnergyImpact {
        // Simple heuristic for energy impact
        if processingTime < 1.0 && tokenCount < 100 {
            return .minimal
        } else if processingTime < 3.0 && tokenCount < 500 {
            return .low
        } else if processingTime < 10.0 && tokenCount < 1000 {
            return .moderate
        } else {
            return .high
        }
    }
}

// MARK: - Extensions

extension AIResponse: CustomStringConvertible {
    var description: String {
        return """
        AIResponse(
            text: "\(text.prefix(100))...",
            tokenCount: \(tokenCount),
            processingTime: \(String(format: "%.2f", processingTime))s,
            tokensPerSecond: \(String(format: "%.1f", tokensPerSecond)),
            qualityScore: \(String(format: "%.2f", qualityScore))
        )
        """
    }
}

extension ResponseMetadata: CustomStringConvertible {
    var description: String {
        return """
        ResponseMetadata(
            model: \(modelVersion),
            method: \(inferenceMethod.description),
            contextUsed: \(contextUsed),
            tabs: \(referencedTabs.count),
            steps: \(processingSteps.count),
            memory: \(memoryUsage) bytes,
            energy: \(energyImpact.description)
        )
        """
    }
}