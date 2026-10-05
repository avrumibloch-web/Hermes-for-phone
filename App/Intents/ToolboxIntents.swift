import AppIntents
import HermesKit

// The "toolbox" half of the app: tools exposed directly to the system as plain App
// Intents, with no Hermes model in the loop.
//
// What iOS 27 does with them:
//   - Shortcuts: each one is an action that returns a value. In a Shortcut you can chain
//     them and pass the output to the built-in "Use Model" action, so Apple's model does
//     the reasoning ("if storage is low, tell me what's using it").
//   - Siri: through the App Shortcut phrases in HermesShortcuts.
//   - Spotlight: as actions.
//
// What iOS 27 does NOT do with them: Siri AI only reasons over and chains actions that
// adopt one of Apple's App Schemas (messages, mail, photos, calendar, reminders, audio,
// system search…). Custom tools like these don't fit a schema, so the open-ended
// path for them stays "Ask Hermes". See docs/FEASIBILITY.md.

struct GetPhoneStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Phone Status"
    static let description = IntentDescription("Battery, Low Power Mode, thermal state and free storage.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Include Storage", default: true)
    var includeStorage: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let report = await DeviceStatus.report(includeStorage: includeStorage)
        return .result(value: report, dialog: "\(report)")
    }
}

struct FetchURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Fetch URL as Text"
    static let description = IntentDescription("HTTP GET a URL (a web page, or a JSON API on your network such as Jellyfin or Home Assistant) and return its text.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "URL")
    var url: URL

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let settings = HermesSettings.load()
        guard settings.allowNetworkTools else {
            return .result(value: "Network tools are turned off in Hermes settings.")
        }
        return .result(value: await WebFetcher.fetch(url.absoluteString, maxChars: 20_000))
    }
}

struct RememberIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember with Hermes"
    static let description = IntentDescription("Save a fact to Hermes' memory, so it's in every future conversation.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Fact", requestValueDialog: "What should Hermes remember?")
    var fact: String

    @Parameter(title: "About Me", description: "On: a fact about you (USER.md). Off: a fact about your setup (MEMORY.md).", default: true)
    var aboutMe: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let agent = try await HermesRuntime.ready()
        let result = await agent.memory.add(aboutMe ? .user : .memory, content: fact)
        return .result(dialog: result.success ? "Saved." : "\(result.message)")
    }
}

struct SearchHermesHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Hermes Conversations"
    static let description = IntentDescription("Full-text search over past Hermes conversations.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Search For")
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let agent = try await HermesRuntime.ready()
        let hits = (try? await agent.sessions.search(query, limit: 8)) ?? []
        let text = hits.isEmpty ? "No matches." : hits.map { "\($0.role): \($0.snippet)" }.joined(separator: "\n")
        return .result(value: text)
    }
}

// MARK: Skills as entities

/// Skills exposed as App Entities, so a phrase can name one ("Run morning briefing with
/// Hermes") and Shortcuts can pick one from a list.
struct SkillEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Skill"
    static let defaultQuery = SkillQuery()

    let id: String
    let summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id.replacingOccurrences(of: "-", with: " "))", subtitle: "\(summary)")
    }
}

struct SkillQuery: EntityStringQuery {
    func entities(for identifiers: [SkillEntity.ID]) async throws -> [SkillEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SkillEntity] {
        let needle = string.lowercased().replacingOccurrences(of: " ", with: "-")
        return try await all().filter { $0.id.contains(needle) || $0.summary.lowercased().contains(string.lowercased()) }
    }

    func suggestedEntities() async throws -> [SkillEntity] {
        try await all()
    }

    private func all() async throws -> [SkillEntity] {
        let agent = try await HermesRuntime.ready()
        return await agent.skills.list().map { SkillEntity(id: $0.name, summary: $0.description) }
    }
}

struct RunSkillIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Hermes Skill"
    static let description = IntentDescription("Run one of Hermes' saved procedures, like the morning briefing.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Skill")
    var skill: SkillEntity

    @Parameter(title: "Details")
    var details: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let agent = try await HermesRuntime.ready()
        if let problem = await agent.availabilityProblem() {
            return .result(value: problem, dialog: "\(problem)")
        }
        let session = try await agent.siriSession()
        let reply = try await agent.send("/\(skill.id) \(details ?? "")", sessionID: session)
        return .result(value: reply.text, dialog: "\(reply.text)")
    }
}
