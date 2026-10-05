import Foundation
import FoundationModels
import HermesKit
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// An open-weight model from Hugging Face's mlx-community, run on this device's GPU with
/// MLX, exposed to the harness as a Foundation Models `LanguageModel`. Free: the weights
/// download once, then everything runs locally.
///
/// Built on Apple's MLXFoundationModels adapter (ml-explore/mlx-swift-lm), which
/// requires the iOS/macOS 27 SDK.
public struct MLXLocalModel: LocalModelProvider {
    public let modelID: String
    public let contextSize: Int
    private let model: MLXLanguageModel

    public struct Preset: Identifiable, Sendable, Hashable {
        public let id: String
        public let note: String
    }

    /// Models known to work well as a tool-calling agent, smallest first.
    public static let recommended: [Preset] = [
        Preset(id: "mlx-community/Qwen3-4B-4bit", note: "~2.3 GB · iPhone 18 Pro, any Apple-silicon Mac"),
        Preset(id: "mlx-community/Qwen3-8B-4bit", note: "~4.7 GB · Mac with 16 GB"),
        Preset(id: "mlx-community/Qwen3-30B-A3B-4bit", note: "~17 GB · Mac with 32 GB+, fast (3B active)"),
        Preset(id: "mlx-community/Qwen3.6-27B-4bit", note: "~15 GB · Mac with 32 GB+, strongest"),
    ]

    public init(modelID: String, contextSize: Int = 16_384, reasoning: Bool = false) {
        self.modelID = modelID
        self.contextSize = contextSize
        // Registry entries carry model-specific stop tokens; unknown ids get a plain config.
        let configuration = LLMRegistry.shared.configuration(id: modelID)
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
        if reasoning { capabilities.append(.reasoning) }
        model = #huggingFaceLanguageModel(configuration: configuration, capabilities: capabilities)
    }

    public var displayName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    // `FoundationModels.` prefix: MLXLLM also declares a type named LanguageModel.
    public func languageModel() -> any FoundationModels.LanguageModel {
        model
    }

    public func unavailableReason() async -> String? {
        switch await model.availability {
        case .available:
            return nil
        case .downloading:
            return "\(displayName) is downloading."
        case .unavailable(.deviceNotCapable):
            return "This device can't run MLX models."
        case .unavailable(.modelNotDownloaded):
            return "\(displayName) isn't downloaded yet. Tap Download in Settings."
        case .unavailable(.downloadFailed):
            return "Downloading \(displayName) failed. Try again in Settings."
        }
    }

    public func preload() async throws {
        try await model.preload()
    }
}
