import Foundation
import HermesKit
import HermesLocalModels
#if os(iOS)
import BackgroundTasks
#endif

/// One agent per process, shared by the UI, App Intents (Siri) and background work.
enum HermesRuntime {
    static let cronTaskID = "com.example.hermes.cron"
    static let reviewTaskID = "com.example.hermes.review"

    private static let made: Result<HermesAgent, Error> = Result {
        try HermesAgent(paths: HermesPaths.defaultHome())
    }

    private actor Once {
        var done = false
        func run(_ agent: HermesAgent) async {
            guard !done else { return }
            done = true
            await agent.bootstrap()
            await HermesRuntime.installLocalModel(on: agent, settings: await agent.settings)
        }
    }
    private static let once = Once()

    static func ready() async throws -> HermesAgent {
        let agent = try made.get()
        await once.run(agent)
        return agent
    }

    /// Saves settings and rebuilds the local MLX model if its configuration changed.
    static func apply(_ settings: HermesSettings) async {
        guard let agent = try? await ready() else { return }
        let old = await agent.settings
        await agent.update(settings: settings)
        if old.smartModel != settings.smartModel || old.localModelID != settings.localModelID
            || old.localContextTokens != settings.localContextTokens || old.localModelReasoning != settings.localModelReasoning {
            await installLocalModel(on: agent, settings: settings)
        }
    }

    static func installLocalModel(on agent: HermesAgent, settings: HermesSettings) async {
        guard settings.smartModel == .local else {
            await agent.setLocalModel(nil)
            return
        }
        await agent.setLocalModel(MLXLocalModel(
            modelID: settings.localModelID,
            contextSize: settings.localContextTokens,
            reasoning: settings.localModelReasoning
        ))
    }

    // MARK: Background work (iPhone)

    #if os(iOS)
    /// Must run before the app finishes launching.
    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: cronTaskID, using: nil) { task in
            let work = Task {
                if let agent = try? await ready() { await agent.runDueJobs() }
                await scheduleBackgroundWork()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: reviewTaskID, using: nil) { task in
            let work = Task {
                if let agent = try? await ready() { await agent.runPendingReviews(limit: 5) }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    #endif

    /// iPhone: asks iOS for time to run the next due job, and for a charging-only slot for
    /// the learning loop. Mac: nothing to do; the app's own timer handles both.
    static func scheduleBackgroundWork() async {
        #if os(iOS)
        guard let agent = try? await ready() else { return }
        if let next = await agent.cron.nextWake() {
            let request = BGAppRefreshTaskRequest(identifier: cronTaskID)
            request.earliestBeginDate = max(next, Date().addingTimeInterval(60))
            try? BGTaskScheduler.shared.submit(request)
        }
        let review = BGProcessingTaskRequest(identifier: reviewTaskID)
        review.requiresExternalPower = true
        review.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(review)
        #endif
    }
}
