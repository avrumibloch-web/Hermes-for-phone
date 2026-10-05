import Foundation
import FoundationModels

// Every call into the Foundation Models framework that is specific to the iOS/macOS 27 SDK
// lives in this file, so if an API shape differs in your Xcode build, this is where to fix it.
//
// iOS/macOS 27 facts this relies on (WWDC26 sessions 241, 319, 339):
//   - SystemLanguageModel: on-device, `contextSize` (8,192 on 27), `tokenCount(for:)`
//   - PrivateCloudComputeLanguageModel: 32K context, reasoning via
//     `respond(to:contextOptions: ContextOptions(reasoningLevel:))`, `isAvailable`,
//     `quotaUsage.isLimitReached`. No token cost; per-user daily limit.
//   - any `LanguageModel` conformer (MLX, Core AI) backs a LanguageModelSession the same way

/// A model that runs on this device but isn't Apple's: an open-weight model through MLX
/// or Core AI. Implemented outside HermesKit (see the HermesLocalModels target) so the
/// core doesn't depend on the MLX packages.
public protocol LocalModelProvider: Sendable {
    /// Short name for the UI, e.g. "Qwen3-8B-4bit".
    var displayName: String { get }
    /// Context window the harness should budget for.
    var contextSize: Int { get }
    /// The Foundation Models `LanguageModel` to put in a session.
    func languageModel() -> any LanguageModel
    /// nil when ready to answer; otherwise why not (not downloaded, downloading…).
    func unavailableReason() async -> String?
    /// Downloads (first time) and loads the weights.
    func preload() async throws
}

/// Builds sessions for a tier and answers model questions.
public struct ModelProvider: Sendable {
    public var local: (any LocalModelProvider)?

    public init(local: (any LocalModelProvider)? = nil) {
        self.local = local
    }

    // MARK: Availability

    /// nil when the on-device model is ready; otherwise a user-facing explanation.
    public func onDeviceUnavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again in a few minutes."
        case .unavailable:
            return "The on-device model is unavailable right now."
        }
    }

    public func privateCloudUnavailableReason() -> String? {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            return "Private Cloud Compute isn't available (needs Apple Intelligence, internet, and an approved app)."
        }
        if model.quotaUsage.isLimitReached {
            return "Today's Private Cloud Compute limit is used up."
        }
        return nil
    }

    public func unavailableReason(_ tier: ModelTier) async -> String? {
        switch tier {
        case .onDevice: return onDeviceUnavailableReason()
        case .privateCloud: return privateCloudUnavailableReason()
        case .local:
            guard let local else { return "No local model is set up." }
            return await local.unavailableReason()
        }
    }

    /// The tier the user picked as "smart", if it's ready right now.
    public func readySmartTier(_ setting: SmartModel) async -> ModelTier? {
        let tier: ModelTier
        switch setting {
        case .off: return nil
        case .local: tier = .local
        case .privateCloud: tier = .privateCloud
        }
        return await unavailableReason(tier) == nil ? tier : nil
    }

    // MARK: Sessions

    public func makeSession(tier: ModelTier, tools: [any Tool], instructions: String) -> LanguageModelSession {
        switch tier {
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
        case .privateCloud:
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        case .local:
            guard let local else {
                return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
            }
            return LanguageModelSession(model: local.languageModel(), tools: tools, instructions: instructions)
        }
    }

    /// One response, with the per-tier options: PCC gets light reasoning (that's where its
    /// edge over the on-device model comes from), the others a token cap.
    public func respond(_ session: LanguageModelSession, to prompt: String, tier: ModelTier) async throws -> String {
        switch tier {
        case .privateCloud:
            let response = try await session.respond(
                to: prompt, contextOptions: ContextOptions(reasoningLevel: .light)
            )
            return response.content
        case .onDevice, .local:
            let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: tier == .onDevice ? 800 : 1_500)
            return try await session.respond(to: prompt, options: options).content
        }
    }

    public func contextBudget(for tier: ModelTier) -> ContextBudget {
        switch tier {
        case .onDevice:
            var budget = ContextBudget.onDevice
            budget.contextSize = SystemLanguageModel.default.contextSize
            return budget
        case .privateCloud:
            return .privateCloud
        case .local:
            let size = local?.contextSize ?? 8_192
            return ContextBudget(contextSize: size, reservedForOutput: 1_600, reservedForToolTraffic: max(1_200, size / 5))
        }
    }

    /// Warm the on-device model while the user is still typing.
    public func prewarm(_ session: LanguageModelSession) {
        session.prewarm()
    }
}

/// Uses the on-device tokenizer; falls back to the heuristic if counting fails. Other
/// models tokenize differently, but within the ~3.2 chars/token margin this is close enough.
public struct SystemTokenCounter: TokenCounting {
    private let fallback = HeuristicTokenCounter()
    public init() {}
    public func count(_ text: String) async -> Int {
        if let n = try? await SystemLanguageModel.default.tokenCount(for: text) { return n }
        return await fallback.count(text)
    }
}

/// Maps framework errors to what the agent loop should do next.
enum GenerationFailure {
    case contextOverflow
    case guardrail
    case unsupportedLanguage
    case busy
    case unavailable
    case other(String)

    init(_ error: Error) {
        guard let e = error as? LanguageModelSession.GenerationError else {
            self = .other(error.localizedDescription)
            return
        }
        switch e {
        case .exceededContextWindowSize: self = .contextOverflow
        case .guardrailViolation: self = .guardrail
        case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
        case .rateLimited, .concurrentRequests: self = .busy
        case .assetsUnavailable: self = .unavailable
        default: self = .other(e.localizedDescription)
        }
    }

    /// Worth retrying on a different model.
    var shouldFallBack: Bool {
        switch self {
        case .busy, .unavailable, .other: return true
        default: return false
        }
    }

    var userMessage: String {
        switch self {
        case .contextOverflow: return "That was too long for the model, even after compressing. Try /new or a shorter request."
        case .guardrail: return "Apple's safety guardrails blocked that request."
        case .unsupportedLanguage: return "The on-device model doesn't support this language yet."
        case .busy: return "The model is busy or over its limit. Try again in a moment."
        case .unavailable: return "The model isn't available right now."
        case .other(let m): return "Something went wrong: \(m)"
        }
    }
}
