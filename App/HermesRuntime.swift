import Foundation
import BackgroundTasks
import HermesKit

/// One agent per process, shared by the UI, App Intents (Siri) and background tasks.
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
        }
    }
    private static let once = Once()

    static func ready() async throws -> HermesAgent {
        let agent = try made.get()
        await once.run(agent)
        return agent
    }

    // MARK: Background work

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

    /// Asks iOS for time to run the next due job, and for a charging-only slot for the
    /// learning loop (reviews are the heaviest background work, so they wait for power).
    static func scheduleBackgroundWork() async {
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
    }
}
