import Foundation

/// The bigger model a request can go to when Apple's on-device model isn't enough.
/// Both options are free; neither needs an API key.
public enum SmartModel: String, Codable, Sendable, CaseIterable {
    /// Everything runs on Apple's on-device model.
    case off
    /// An open-weight model downloaded once from Hugging Face and run locally with MLX.
    /// Best on a Mac; a 4B model also runs on an iPhone 18 Pro.
    case local
    /// Apple's Private Cloud Compute model: 32K context and reasoning, no token cost,
    /// a daily limit per iCloud account. Leaves the device (Apple's private servers).
    case privateCloud
}

/// User-tunable knobs. Defaults keep everything on the device.
public struct HermesSettings: Codable, Sendable, Equatable {
    public var smartModel: SmartModel = .off
    /// Hugging Face id of the local MLX model (see README for which fits your device).
    public var localModelID = "mlx-community/Qwen3-4B-4bit"
    /// Context the local model is allowed to use. Larger costs RAM for the KV cache.
    public var localContextTokens = 16_384
    /// Let the local model "think" before answering (slower, smarter).
    public var localModelReasoning = false
    /// Send every request to the smart model, not just hard ones. Sensible on a Mac
    /// with a good local model.
    public var useSmartModelForEverything = false
    /// Send requests that look hard to the smart model. `/think` always does.
    public var autoEscalate = true

    /// Allow the web_fetch tool (plain HTTP GET).
    public var allowNetworkTools = true
    /// Mac only: allow the terminal tool to run shell commands (from the chat window only).
    public var allowTerminal = false
    /// Run the learning loop (memory/skill review) after substantial turns.
    public var backgroundReview = true
    /// A Siri conversation ends after this much idle time, so the next request starts a
    /// fresh session with an updated memory snapshot (Hermes' session boundary).
    public var siriSessionIdleMinutes = 30

    // Budgets sized for the on-device model's 8,192-token context (iOS 27). Hermes' own
    // defaults (2,200 / 1,375 chars) assume a 128K+ cloud context.
    public var memoryCharLimit = 1_200
    public var userCharLimit = 700
    public var skillsIndexCharLimit = 600
    public var skillViewCharLimit = 5_000
    public var maxToolsPerTurn = 7

    public init() {}

    // Decode field by field so settings saved by an older build keep their values when
    // fields are added or removed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HermesSettings()
        smartModel = (try? c.decodeIfPresent(SmartModel.self, forKey: .smartModel)) ?? d.smartModel
        localModelID = (try? c.decodeIfPresent(String.self, forKey: .localModelID)) ?? d.localModelID
        localContextTokens = (try? c.decodeIfPresent(Int.self, forKey: .localContextTokens)) ?? d.localContextTokens
        localModelReasoning = (try? c.decodeIfPresent(Bool.self, forKey: .localModelReasoning)) ?? d.localModelReasoning
        useSmartModelForEverything = (try? c.decodeIfPresent(Bool.self, forKey: .useSmartModelForEverything)) ?? d.useSmartModelForEverything
        autoEscalate = (try? c.decodeIfPresent(Bool.self, forKey: .autoEscalate)) ?? d.autoEscalate
        allowNetworkTools = (try? c.decodeIfPresent(Bool.self, forKey: .allowNetworkTools)) ?? d.allowNetworkTools
        allowTerminal = (try? c.decodeIfPresent(Bool.self, forKey: .allowTerminal)) ?? d.allowTerminal
        backgroundReview = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundReview)) ?? d.backgroundReview
        siriSessionIdleMinutes = (try? c.decodeIfPresent(Int.self, forKey: .siriSessionIdleMinutes)) ?? d.siriSessionIdleMinutes
        memoryCharLimit = (try? c.decodeIfPresent(Int.self, forKey: .memoryCharLimit)) ?? d.memoryCharLimit
        userCharLimit = (try? c.decodeIfPresent(Int.self, forKey: .userCharLimit)) ?? d.userCharLimit
        skillsIndexCharLimit = (try? c.decodeIfPresent(Int.self, forKey: .skillsIndexCharLimit)) ?? d.skillsIndexCharLimit
        skillViewCharLimit = (try? c.decodeIfPresent(Int.self, forKey: .skillViewCharLimit)) ?? d.skillViewCharLimit
        maxToolsPerTurn = (try? c.decodeIfPresent(Int.self, forKey: .maxToolsPerTurn)) ?? d.maxToolsPerTurn
    }

    static let defaultsKey = "hermes.settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> HermesSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(HermesSettings.self, from: data) else {
            return HermesSettings()
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
