import Foundation
import UserNotifications

extension HermesAgent {
    static let cronSuffix = """


    (Scheduled job: the user is not watching. Do the task with your tools and answer in at most \
    three sentences, suitable for a notification.)
    """

    /// Runs every due job in its own fresh session and notifies the user with each answer.
    /// Returns how many jobs ran.
    @discardableResult
    public func runDueJobs(now: Date = Date()) async -> Int {
        let due = await cron.due(now: now)
        var ran = 0
        for job in due {
            if Task.isCancelled { break }
            do {
                let id = try await newSession(source: .cron, title: job.name)
                let reply = try await send(job.prompt + Self.cronSuffix, sessionID: id)
                live[id] = nil
                try await cron.markRan(id: job.id, result: reply.text)
                await Notifier.post(title: job.name, body: reply.text, id: "cron-\(job.id)-\(Int(now.timeIntervalSince1970))")
                ran += 1
            } catch {
                try? await cron.markRan(id: job.id, result: "Failed: \(error.localizedDescription)")
            }
        }
        return ran
    }
}

public enum Notifier {
    public static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = TextUtil.truncate(body, to: 600)
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
