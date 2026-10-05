import Foundation

/// User-tunable knobs. Defaults keep everything on the phone: Private Cloud Compute is
/// opt-in, and the only network tool (web_fetch) can be switched off.
public struct HermesSettings: Codable, Sendable, Equatable {
    /// Let hard requests escalate to Apple's Private Cloud Compute model (32K context,
    /// reasoning). Off = every request runs on the on-device model.
    public var allowPrivateCloud = false
    /// Escalate automatically when a request looks hard. When false, only `/think` escalates.
    public var autoEscalate = true
    /// Allow the web_fetch tool (plain HTTP GET). The model itself never leaves the phone.
    public var allowNetworkTools = true
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
