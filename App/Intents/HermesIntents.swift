import AppIntents
import HermesKit

/// "Hey Siri, ask Hermes" → Siri asks "What should Hermes do?" → the answer is spoken back.
/// Runs in the background (the app doesn't open) inside the app's own process.
struct AskHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription("Ask your on-device Hermes agent to answer or do something.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Request", requestValueDialog: "What should Hermes do?")
    var request: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let agent = try await HermesRuntime.ready()
        if let problem = await agent.availabilityProblem() {
            return .result(value: problem, dialog: "\(problem)")
        }
        let session = try await agent.siriSession()
        let reply = try await agent.send(request, sessionID: session)
        return .result(value: reply.text, dialog: "\(reply.text)")
    }
}

struct NewHermesConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "New Hermes Conversation"
    static let description = IntentDescription("Start a fresh Siri conversation with Hermes.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let agent = try await HermesRuntime.ready()
        await agent.endSiriSession()
        return .result(dialog: "OK, starting fresh.")
    }
}

/// Target of the Shortcuts "Time of Day" automation that gives scheduled jobs exact timing.
struct RunScheduledJobsIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Hermes Scheduled Jobs"
    static let description = IntentDescription("Runs any Hermes scheduled jobs that are due and sends their results as notifications.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let agent = try await HermesRuntime.ready()
        let ran = await agent.runDueJobs()
        await HermesRuntime.scheduleBackgroundWork()
        return .result(value: ran)
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)"],
            shortTitle: "Ask Hermes",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: NewHermesConversationIntent(),
            phrases: ["New \(.applicationName) conversation"],
            shortTitle: "New Conversation",
            systemImageName: "plus.bubble"
        )
        AppShortcut(
            intent: RunSkillIntent(),
            phrases: ["Run \(\.$skill) with \(.applicationName)", "\(.applicationName) \(\.$skill)"],
            shortTitle: "Run Skill",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: GetPhoneStatusIntent(),
            phrases: ["Get phone status with \(.applicationName)", "Check my phone with \(.applicationName)"],
            shortTitle: "Phone Status",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: RememberIntent(),
            phrases: ["Remember something with \(.applicationName)", "Tell \(.applicationName) to remember"],
            shortTitle: "Remember",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: RunScheduledJobsIntent(),
            phrases: ["Run \(.applicationName) scheduled jobs"],
            shortTitle: "Run Scheduled Jobs",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
