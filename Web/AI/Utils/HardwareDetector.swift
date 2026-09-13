import Foundation
import System

/// Hardware detection and optimization system for AI inference
/// Automatically detects Apple Silicon vs Intel Mac configuration
class HardwareDetector {
    
    // MARK: - Hardware Types
    
    enum ProcessorType: Equatable {
        case appleSilicon(generation: AppleSiliconGeneration)
        case intel(cores: Int, architecture: String)
        case unknown
    }
    
    enum AppleSiliconGeneration: Int, CaseIterable, Comparable {
        case m1 = 1
        case m2 = 2
        case m3 = 3
        case m4 = 4
        case unknown = 0
        
        static func < (lhs: AppleSiliconGeneration, rhs: AppleSiliconGeneration) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
        
        var performanceMultiplier: Double {
            switch self {
            case .m1: return 1.0
            case .m2: return 1.2
            case .m3: return 1.5
            case .m4: return 1.8
            case .unknown: return 0.8
            }
        }
        
        var description: String {
            switch self {
            case .m1: return "Apple M1"
            case .m2: return "Apple M2"
            case .m3: return "Apple M3"
            case .m4: return "Apple M4"
            case .unknown: return "Unknown Apple Silicon"
            }
        }
    }
    
    // MARK: - Static Properties
    
    static let shared = HardwareDetector()
    
    private let processorInfo: ProcessorType
    private let physicalMemory: UInt64
    private let logicalCores: Int
    private let performanceCores: Int
    private let efficiencyCores: Int
    
    // MARK: - Public Interface
    
    /// Whether the current system is Apple Silicon
    static var isAppleSilicon: Bool {
        switch shared.processorInfo {
        case .appleSilicon:
            return true
        default:
            return false
        }
    }
    
    /// Whether the current system is Intel-based Mac
    static var isIntelMac: Bool {
        switch shared.processorInfo {
        case .intel:
            return true
        default:
            return false
        }
    }
    
    /// Get the detected processor information
    static var processorType: ProcessorType {
        return shared.processorInfo
    }
    
    /// Get total physical memory in GB
    static var totalMemoryGB: Int {
        return Int(shared.physicalMemory / (1024 * 1024 * 1024))
    }
    
    /// Get number of performance cores for Apple Silicon optimization
    static var performanceCores: Int {
        return shared.performanceCores
    }
    
    /// Get number of efficiency cores
    static var efficiencyCores: Int {
        return shared.efficiencyCores
    }
    
    /// Get recommended memory limit for AI processing
    static var recommendedMemoryLimit: Int {
        let totalGB = totalMemoryGB
        
        // Reserve memory for system and browser operations
        switch shared.processorInfo {
        case .appleSilicon(_):
            // Apple Silicon unified memory - can use more aggressively
            if totalGB >= 32 {
                return min(8, totalGB / 3) // Up to 8GB for AI
            } else if totalGB >= 16 {
                return min(4, totalGB / 4) // Up to 4GB for AI
            } else {
                return min(2, totalGB / 6) // Up to 2GB for AI
            }
        case .intel:
            // Intel Macs - more conservative due to discrete memory
            return min(2, totalGB / 8)
        case .unknown:
            return min(1, totalGB / 10)
        }
    }
    
    /// Expected AI inference performance in tokens per second
    static var expectedTokensPerSecond: Int {
        switch shared.processorInfo {
        case .appleSilicon(let generation):
            let basePerformance = 80 // M1 baseline
            return Int(Double(basePerformance) * generation.performanceMultiplier)
        case .intel(let cores, _):
            // Intel fallback with llama.cpp
            return min(40, cores * 5)
        case .unknown:
            return 20
        }
    }
    
    /// Get optimal AI configuration for the detected hardware
    static func getOptimalAIConfiguration() -> AIConfiguration {
        switch shared.processorInfo {
        case .appleSilicon(_):
            return AIConfiguration(
                framework: .mlx,
                modelVariant: .gemma3_1B, // Compatible downloadable model
                quantization: .int4,
                maxContextTokens: 32768, // Model context; requests use a smaller bounded source
                maxMemoryGB: recommendedMemoryLimit,
                expectedTokensPerSecond: expectedTokensPerSecond
            )
        case .intel(_, _):
            return AIConfiguration(
                framework: .llamaCpp,
                modelVariant: .gemma3_1B, // Local inference remains unavailable on Intel
                quantization: .int4,
                maxContextTokens: 32768,
                maxMemoryGB: recommendedMemoryLimit,
                expectedTokensPerSecond: expectedTokensPerSecond
            )
        case .unknown:
            return AIConfiguration(
                framework: .llamaCpp,
                modelVariant: .gemma3_1B,
                quantization: .int4,
                maxContextTokens: 16384, // Reduced for safety
                maxMemoryGB: 1,
                expectedTokensPerSecond: 10
            )
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Detect processor type
        self.processorInfo = Self.detectProcessorType()
        
        // Get memory information
        self.physicalMemory = Self.getPhysicalMemory()
        
        // Get CPU core information
        let coreInfo = Self.getCoreInformation()
        self.logicalCores = coreInfo.logical
        self.performanceCores = coreInfo.performance
        self.efficiencyCores = coreInfo.efficiency
        
        // Log hardware detection results
        self.logHardwareInfo()
    }
    
    // MARK: - Detection Methods
    
    private static func detectProcessorType() -> ProcessorType {
        var size = 0
        
        // Get CPU brand string
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return .unknown }
        
        let brandString = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { brandString.deallocate() }
        
        guard sysctlbyname("machdep.cpu.brand_string", brandString, &size, nil, 0) == 0 else {
            return .unknown
        }
        
        let brand = String(cString: brandString).lowercased()
        
        if brand.contains("apple") {
            // Detect Apple Silicon generation
            if brand.contains("m4") {
                return .appleSilicon(generation: .m4)
            } else if brand.contains("m3") {
                return .appleSilicon(generation: .m3)
            } else if brand.contains("m2") {
                return .appleSilicon(generation: .m2)
            } else if brand.contains("m1") {
                return .appleSilicon(generation: .m1)
            } else {
                return .appleSilicon(generation: .unknown)
            }
        } else if brand.contains("intel") {
            let cores = getCoreCount()
            return .intel(cores: cores, architecture: brand)
        }
        
        return .unknown
    }
    
    private static func getPhysicalMemory() -> UInt64 {
        var size = MemoryLayout<UInt64>.size
        var physicalMemory: UInt64 = 0
        
        let result = sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0)
        guard result == 0 else { return 0 }
        
        return physicalMemory
    }
    
    private static func getCoreInformation() -> (logical: Int, performance: Int, efficiency: Int) {
        let logical = getCoreCount()
        
        // Detect processor type directly without using shared instance
        let processorType = detectProcessorType()
        
        // Apple Silicon core detection
        if case .appleSilicon = processorType {
            let performance = getIntSysctl("hw.perflevel0.logicalcpu") ?? (logical / 2)
            let efficiency = getIntSysctl("hw.perflevel1.logicalcpu") ?? (logical - performance)
            return (logical, performance, efficiency)
        } else {
            // Intel Macs - all cores are performance cores
            return (logical, logical, 0)
        }
    }
    
    private static func getCoreCount() -> Int {
        return getIntSysctl("hw.logicalcpu") ?? 4
    }
    
    private static func getIntSysctl(_ name: String) -> Int? {
        var size = MemoryLayout<Int>.size
        var value: Int = 0
        
        let result = sysctlbyname(name, &value, &size, nil, 0)
        return result == 0 ? value : nil
    }
    
    // MARK: - Logging
    
    private func calculateRecommendedMemoryLimit() -> Int {
        let totalGB = Int(physicalMemory / (1024 * 1024 * 1024))
        
        // Reserve memory for system and browser operations
        switch processorInfo {
        case .appleSilicon(_):
            // Apple Silicon unified memory - can use more aggressively
            if totalGB >= 32 {
                return min(8, totalGB / 3) // Up to 8GB for AI
            } else if totalGB >= 16 {
                return min(4, totalGB / 4) // Up to 4GB for AI
            } else {
                return min(2, totalGB / 6) // Up to 2GB for AI
            }
        case .intel:
            // Intel Macs - more conservative due to discrete memory
            return min(2, totalGB / 8)
        case .unknown:
            return min(1, totalGB / 10)
        }
    }
    
    private func calculateExpectedTokensPerSecond() -> Int {
        switch processorInfo {
        case .appleSilicon(let generation):
            let basePerformance = 80 // M1 baseline
            return Int(Double(basePerformance) * generation.performanceMultiplier)
        case .intel(let cores, _):
            // Intel fallback with llama.cpp
            return min(40, cores * 5)
        case .unknown:
            return 20
        }
    }
    
    private func logHardwareInfo() {
        NSLog("🖥️ Hardware Detection Results:")
        NSLog("   Processor: \(processorInfo)")
        NSLog("   Memory: \(Int(physicalMemory / (1024 * 1024 * 1024))) GB")
        NSLog("   Cores: \(logicalCores) logical (\(performanceCores) performance, \(efficiencyCores) efficiency)")
        NSLog("   AI Memory Limit: \(calculateRecommendedMemoryLimit()) GB")
        NSLog("   Expected Performance: \(calculateExpectedTokensPerSecond()) tokens/second")
    }
}

// MARK: - AI Configuration

struct AIConfiguration {
    enum Framework {
        case mlx
        case llamaCpp
    }
    
    enum ModelVariant {
        case gemma3_1B    // Gemma 3 1B QAT, downloaded on demand
        case custom(String)
    }
    
    enum Quantization {
        case int4
        case int8
        case float16
    }
    
    let framework: Framework
    let modelVariant: ModelVariant
    let quantization: Quantization
    let maxContextTokens: Int
    let maxMemoryGB: Int
    let expectedTokensPerSecond: Int
}

// MARK: - Extensions

extension HardwareDetector.ProcessorType: CustomStringConvertible {
    var description: String {
        switch self {
        case .appleSilicon(let generation):
            return generation.description
        case .intel(let cores, let architecture):
            return "Intel \(architecture) (\(cores) cores)"
        case .unknown:
            return "Unknown Processor"
        }
    }
    
    /// Get performance multiplier for AI optimization
    var performanceMultiplier: Double {
        switch self {
        case .appleSilicon(let generation):
            return generation.performanceMultiplier
        case .intel:
            return 0.6 // Intel Macs with llama.cpp fallback
        case .unknown:
            return 0.4 // Conservative fallback
        }
    }
}

/// Shared local routing identity. This exact model is in the pinned MLXLLM registry.
enum LocalModelDefaults {
    static let repositoryID = "mlx-community/gemma-3-1b-it-qat-4bit"
    static let displayName = "Gemma 3 1B (4-bit)"
    static let contextWindow = 32_768
    static let downloadSizeGB = 0.733
}
