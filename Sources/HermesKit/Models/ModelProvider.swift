import Foundation
import FoundationModels

// Every call into the Foundation Models framework that is specific to the iOS 27 SDK lives
// in this file, so if an API shape differs in your Xcode build, this is the one place to fix.
//
// iOS 27 facts this relies on (WWDC26 "What's new in the Foundation Models framework"):
//   - SystemLanguageModel: on-device model, `contextSize` (8,192), `tokenCount(for:)`
//   - PrivateCloudComputeLanguageModel: Apple's server model, 32K context, same API
//   - both conform to the new `LanguageModel` protocol and back a LanguageModelSession
//   - Tool / @Generable / GenerationOptions work the same on either model

/// Builds sessions for a tier and answers model questions.
public struct ModelProvider: Sendable {
    public init() {}

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

    public func makeSession(tier: ModelTier, tools: [any Tool], instructions: String) -> LanguageModelSession {
        switch tier {
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
        case .privateCloud:
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
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
        }
    }

    public func generationOptions(for tier: ModelTier) -> GenerationOptions {
        GenerationOptions(temperature: 0.4, maximumResponseTokens: tier == .onDevice ? 800 : 1_800)
    }

    /// Warm the on-device model while the user is still typing.
    public func prewarm(_ session: LanguageModelSession) {
        session.prewarm()
    }
}

/// Uses the on-device tokenizer; falls back to the heuristic if counting fails.
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

    var userMessage: String {
        switch self {
        case .contextOverflow: return "That was too long for the on-device model, even after compressing. Try /new or a shorter request."
        case .guardrail: return "Apple's safety guardrails blocked that request."
        case .unsupportedLanguage: return "The on-device model doesn't support this language yet."
        case .busy: return "The model is busy. Try again in a moment."
        case .unavailable: return "The model isn't available right now."
        case .other(let m): return "Something went wrong: \(m)"
        }
    }
}
