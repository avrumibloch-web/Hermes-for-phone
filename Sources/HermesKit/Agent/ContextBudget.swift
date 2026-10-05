import Foundation

/// Counts tokens. On device the agent uses the model's own tokenizer
/// (`SystemLanguageModel.tokenCount(for:)`, iOS 27); tests and fallbacks use a heuristic.
public protocol TokenCounting: Sendable {
    func count(_ text: String) async -> Int
}

/// ~3.2 characters per token is conservative for English with Apple's tokenizer; erring
/// high means we compress a little early rather than hit `exceededContextWindowSize`.
public struct HeuristicTokenCounter: TokenCounting {
    public var charsPerToken: Double = 3.2
    public init() {}
    public func count(_ text: String) async -> Int {
        Int((Double(text.count) / charsPerToken).rounded(.up))
    }
}

/// How the context window is split for one turn.
public struct ContextBudget: Sendable {
    public var contextSize: Int
    public var reservedForOutput: Int
    /// Tool schemas are injected into the instructions by the framework; we can't measure
    /// them directly, so each tool is charged a flat estimate.
    public var perToolSchemaTokens: Int
    /// Tool calls and their outputs consume context during the turn.
    public var reservedForToolTraffic: Int

    public init(contextSize: Int = 8_192, reservedForOutput: Int = 900, perToolSchemaTokens: Int = 110, reservedForToolTraffic: Int = 1_200) {
        self.contextSize = contextSize
        self.reservedForOutput = reservedForOutput
        self.perToolSchemaTokens = perToolSchemaTokens
        self.reservedForToolTraffic = reservedForToolTraffic
    }

    public static let onDevice = ContextBudget()
    public static let privateCloud = ContextBudget(contextSize: 32_000, reservedForOutput: 2_000, reservedForToolTraffic: 6_000)

    /// Tokens left for the conversation history + new message.
    public func historyAllowance(instructionTokens: Int, toolCount: Int) -> Int {
        contextSize - reservedForOutput - reservedForToolTraffic - instructionTokens - toolCount * perToolSchemaTokens
    }
}

/// Decides which recent messages stay verbatim and which get folded into the summary.
public enum HistoryFitter {
    public struct Plan: Sendable {
        public let keep: [SessionStore.Message]
        public let compress: [SessionStore.Message]
    }

    /// Keeps the newest messages that fit `allowance` and marks everything older for
    /// compression. Like Hermes, the most recent context is protected and older turns are
    /// summarized. `maxKeep` bounds the verbatim tail even when it would fit, because a
    /// small model follows a short transcript plus a summary better than a long one.
    public static func plan(
        history: [SessionStore.Message],
        newMessage: String,
        allowance: Int,
        counter: TokenCounting,
        maxKeep: Int = 12
    ) async -> Plan {
        var remaining = allowance - (await counter.count(newMessage)) - 40
        var keep: [SessionStore.Message] = []
        for message in history.reversed() {
            let cost = await counter.count(message.content) + 4
            if remaining - cost < 0 || keep.count >= maxKeep { break }
            remaining -= cost
            keep.insert(message, at: 0)
        }
        let compress = Array(history.dropLast(keep.count))
        return Plan(keep: keep, compress: compress)
    }
}
