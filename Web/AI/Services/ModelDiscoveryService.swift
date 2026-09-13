import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Service for discovering and managing locally available MLX models
/// Supports both automatic detection and user-added models
@MainActor
class ModelDiscoveryService: ObservableObject {

    static let shared = ModelDiscoveryService()

    // MARK: - Published Properties

    @Published var discoveredModels: [DiscoveredModel] = []
    @Published var isScanning: Bool = false
    @Published var lastScanDate: Date?

    // MARK: - Types

    struct DiscoveredModel: Identifiable, Codable {
        let id: String
        let name: String
        let path: String
        let source: ModelSource
        let sizeGB: Double
        let modelType: ModelType
        let isValid: Bool
        let lastValidated: Date
        let metadata: ModelMetadata?

        enum ModelSource: String, Codable, CaseIterable {
            case huggingFaceCache = "huggingface_cache"
            case userAdded = "user_added"
            case mlxCache = "mlx_cache"
            case systemDetected = "system_detected"

            var displayName: String {
                switch self {
                case .huggingFaceCache: return "Hugging Face Cache"
                case .userAdded: return "User Added"
                case .mlxCache: return "MLX Cache"
                case .systemDetected: return "System Detected"
                }
            }
        }

        enum ModelType: String, Codable, CaseIterable {
            case gemma = "gemma"
            case llama = "llama"
            case mistral = "mistral"
            case phi = "phi"
            case unknown = "unknown"

            var displayName: String {
                switch self {
                case .gemma: return "Gemma"
                case .llama: return "Llama"
                case .mistral: return "Mistral"
                case .phi: return "Phi"
                case .unknown: return "Unknown"
                }
            }
        }

        struct ModelMetadata: Codable {
            let contextWindow: Int?
            let quantization: String?
            let parameterCount: String?
            let architecture: String?
            let license: String?
        }
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let discoveredModelsKey = "discoveredModels"

    // Common model search paths
    private var searchPaths: [URL] {
        var paths: [URL] = []

        // Hugging Face cache directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        paths.append(homeDir.appendingPathComponent(".cache/huggingface/hub"))

        // MLX cache directory
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        {
            paths.append(cacheDir.appendingPathComponent("MLXCache"))
        }

        // User-specified directories (from settings)
        if let userPaths = userDefaults.array(forKey: "userModelPaths") as? [String] {
            paths.append(contentsOf: userPaths.compactMap { URL(fileURLWithPath: $0) })
        }

        // Common model directories
        if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first
        {
            paths.append(documentsDir.appendingPathComponent("AI Models"))
            paths.append(documentsDir.appendingPathComponent("MLX Models"))
        }

        return paths
    }

    // MARK: - Initialization

    private init() {
        loadDiscoveredModels()

        // Perform initial scan if no models found or last scan was over 24 hours ago
        if discoveredModels.isEmpty || shouldPerformAutomaticScan() {
            Task {
                await scanForModels()
            }
        }
    }

    // MARK: - Public Interface

    /// Scan all search paths for available models
    func scanForModels() async {
        isScanning = true
        defer { isScanning = false }

        if AppLog.isVerboseEnabled { AppLog.debug("Starting model discovery scan…") }

        var foundModels: [DiscoveredModel] = []

        for searchPath in searchPaths {
            await scanDirectory(searchPath, foundModels: &foundModels)
        }

        // Remove duplicates and sort by name
        let uniqueModels = Array(Set(foundModels.map { $0.id }))
            .compactMap { id in foundModels.first { $0.id == id } }
            .sorted { $0.name < $1.name }

        discoveredModels = uniqueModels
        lastScanDate = Date()

        saveDiscoveredModels()

        if AppLog.isVerboseEnabled {
            AppLog.debug("Model discovery completed: \(discoveredModels.count) models")
        }
    }

    /// Add a user-specified model directory
    func addUserModelPath(_ path: String) async {
        var userPaths = userDefaults.array(forKey: "userModelPaths") as? [String] ?? []

        if !userPaths.contains(path) {
            userPaths.append(path)
            userDefaults.set(userPaths, forKey: "userModelPaths")

            NSLog("📁 Added user model path: \(path)")

            // Rescan to pick up models from new path
            await scanForModels()
        }
    }

    /// Remove a user-specified model directory
    func removeUserModelPath(_ path: String) async {
        var userPaths = userDefaults.array(forKey: "userModelPaths") as? [String] ?? []
        userPaths.removeAll { $0 == path }
        userDefaults.set(userPaths, forKey: "userModelPaths")

        NSLog("🗑️ Removed user model path: \(path)")

        // Rescan to update model list
        await scanForModels()
    }

    /// Get user-added model paths
    func getUserModelPaths() -> [String] {
        return userDefaults.array(forKey: "userModelPaths") as? [String] ?? []
    }

    /// Validate a specific model
    func validateModel(_ model: DiscoveredModel) async -> Bool {
        do {
            // Try to create a model configuration and test loading
            let config = ModelConfiguration(directory: URL(fileURLWithPath: model.path))
            let _ = try await LLMModelFactory.shared.loadContainer(configuration: config) { _ in }

            NSLog("✅ Model validation successful: \(model.name)")
            return true
        } catch {
            NSLog("❌ Model validation failed: \(model.name) - \(error)")
            return false
        }
    }

    /// Convert discovered model to MLX configuration
    func createModelConfiguration(from model: DiscoveredModel) -> ModelConfiguration {
        return ModelConfiguration(directory: URL(fileURLWithPath: model.path))
    }

    /// Get models suitable for the current hardware
    func getCompatibleModels() -> [DiscoveredModel] {
        let totalMemoryGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

        return discoveredModels.filter { model in
            // Filter based on model size and available memory
            let memoryRequirement = model.sizeGB * 1.5  // Add 50% overhead
            return memoryRequirement <= Double(totalMemoryGB) * 0.8  // Use max 80% of RAM
        }
    }

    // MARK: - Private Methods

    private func scanDirectory(_ directory: URL, foundModels: inout [DiscoveredModel]) async {
        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            for item in contents {
                if await isModelDirectory(item) {
                    if let model = await createDiscoveredModel(from: item) {
                        foundModels.append(model)
                    }
                }

                // Recursively scan subdirectories
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    await scanDirectory(item, foundModels: &foundModels)
                }
            }
        } catch {
            NSLog("⚠️ Error scanning directory \(directory.path): \(error)")
        }
    }

    private func isModelDirectory(_ url: URL) async -> Bool {
        let modelFiles = ["config.json", "tokenizer.json", "model.safetensors"]

        // Check for common MLX model files
        for file in modelFiles {
            let filePath = url.appendingPathComponent(file)
            if fileManager.fileExists(atPath: filePath.path) {
                return true
            }
        }

        // Check for .mlx files
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
            return contents.contains {
                $0.pathExtension == "mlx" || $0.pathExtension == "safetensors"
            }
        } catch {
            return false
        }
    }

    private func createDiscoveredModel(from url: URL) async -> DiscoveredModel? {
        do {
            let modelName = extractModelName(from: url)
            let modelType = detectModelType(from: modelName)
            let sizeGB = await calculateDirectorySize(url)
            let source = determineModelSource(from: url)

            // Try to read metadata
            let metadata = await readModelMetadata(from: url)

            return DiscoveredModel(
                id: url.path,
                name: modelName,
                path: url.path,
                source: source,
                sizeGB: sizeGB,
                modelType: modelType,
                isValid: true,  // Will be validated later if needed
                lastValidated: Date(),
                metadata: metadata
            )
        } catch {
            NSLog("⚠️ Error creating model from \(url.path): \(error)")
            return nil
        }
    }

    private func extractModelName(from url: URL) -> String {
        let pathComponents = url.pathComponents

        // For Hugging Face cache: extract from path like "models--mlx-community--gemma-3-1b-it-qat-4bit"
        if let modelComponent = pathComponents.first(where: { $0.hasPrefix("models--") }) {
            return
                modelComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
        }

        // Otherwise use directory name
        return url.lastPathComponent
    }

    private func detectModelType(from name: String) -> DiscoveredModel.ModelType {
        let lowercaseName = name.lowercased()

        if lowercaseName.contains("gemma") {
            return .gemma
        } else if lowercaseName.contains("llama") {
            return .llama
        } else if lowercaseName.contains("mistral") {
            return .mistral
        } else if lowercaseName.contains("phi") {
            return .phi
        } else {
            return .unknown
        }
    }

    private func determineModelSource(from url: URL) -> DiscoveredModel.ModelSource {
        let path = url.path

        if path.contains("huggingface") {
            return .huggingFaceCache
        } else if path.contains("MLXCache") {
            return .mlxCache
        } else if getUserModelPaths().contains(where: { path.hasPrefix($0) }) {
            return .userAdded
        } else {
            return .systemDetected
        }
    }

    private func calculateDirectorySize(_ url: URL) async -> Double {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey])
        {
            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                } catch {
                    // Continue on error
                }
            }
        }

        return Double(totalSize) / (1024 * 1024 * 1024)  // Convert to GB
    }

    private func readModelMetadata(from url: URL) async -> DiscoveredModel.ModelMetadata? {
        let configPath = url.appendingPathComponent("config.json")

        guard fileManager.fileExists(atPath: configPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: configPath)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            return DiscoveredModel.ModelMetadata(
                contextWindow: json?["max_position_embeddings"] as? Int,
                quantization: json?["quantization"] as? String,
                parameterCount: json?["num_parameters"] as? String,
                architecture: json?["architectures"] as? String,
                license: json?["license"] as? String
            )
        } catch {
            NSLog("⚠️ Error reading model metadata from \(configPath.path): \(error)")
            return nil
        }
    }

    private func shouldPerformAutomaticScan() -> Bool {
        guard let lastScan = lastScanDate else { return true }
        return Date().timeIntervalSince(lastScan) > 24 * 60 * 60  // 24 hours
    }

    private func saveDiscoveredModels() {
        do {
            let data = try JSONEncoder().encode(discoveredModels)
            userDefaults.set(data, forKey: discoveredModelsKey)
        } catch {
            NSLog("⚠️ Error saving discovered models: \(error)")
        }
    }

    private func loadDiscoveredModels() {
        guard let data = userDefaults.data(forKey: discoveredModelsKey) else { return }

        do {
            discoveredModels = try JSONDecoder().decode([DiscoveredModel].self, from: data)
            if AppLog.isVerboseEnabled {
                AppLog.debug("Loaded previously discovered models: \(discoveredModels.count)")
            }
        } catch {
            NSLog("⚠️ Error loading discovered models: \(error)")
            discoveredModels = []
        }
    }
}
