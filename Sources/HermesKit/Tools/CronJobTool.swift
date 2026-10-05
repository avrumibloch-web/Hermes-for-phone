import Foundation
import FoundationModels

/// Hermes' cron tool: the agent schedules its own recurring work in natural language
/// ("every weekday at 7:30 summarize my calendar"). Each run is a fresh agent session whose
/// answer is delivered as a notification.
struct CronJobTool: Tool {
    let name = "cronjob"
    let description = """
    Schedule a prompt for Hermes to run later and notify the user with the answer. kind: daily, weekdays \
    (Mon-Fri), weekly, interval or once. Use list to show jobs and remove (with jobId) to delete one.
    """
    let context: ToolContext

    @Generable
    enum Action {
        case create
        case list
        case remove
    }

    @Generable
    enum Kind {
        case daily
        case weekdays
        case weekly
        case interval
        case once
    }

    @Generable
    struct Arguments {
        var action: Action
        @Guide(description: "Short job name")
        var jobName: String?
        @Guide(description: "What Hermes should do each time, written as a request")
        var prompt: String?
        var kind: Kind?
        @Guide(description: "Hour 0-23 for daily/weekdays/weekly")
        var hour: Int?
        @Guide(description: "Minute 0-59")
        var minute: Int?
        @Guide(description: "Weekday for weekly: 1 Sunday … 7 Saturday")
        var weekday: Int?
        @Guide(description: "Minutes between runs for interval (at least 15)")
        var everyMinutes: Int?
        @Guide(description: "For once: YYYY-MM-DD HH:mm")
        var at: String?
        @Guide(description: "Job id for remove")
        var jobId: String?
    }

    func call(arguments a: Arguments) async throws -> String {
        switch a.action {
        case .list:
            let jobs = await context.cron.all()
            await context.log(name, "list \(jobs.count)")
            guard !jobs.isEmpty else { return "No scheduled jobs." }
            return jobs.map { "\($0.id) · \($0.name) · \($0.scheduleDescription)\($0.enabled ? "" : " (paused)")" }
                .joined(separator: "\n")
        case .remove:
            guard let id = a.jobId else { return "Error: jobId is required." }
            let removed = try await context.cron.remove(id: id)
            await context.log(name, "remove \(id)")
            return removed ? "Removed job \(id)." : "Error: no job \(id)."
        case .create:
            guard let prompt = a.prompt, !prompt.isEmpty else { return "Error: prompt is required." }
            let schedule: CronJob.Schedule
            switch a.kind ?? .daily {
            case .daily:
                schedule = .daily(hour: clamp(a.hour ?? 8, 0...23), minute: clamp(a.minute ?? 0, 0...59))
            case .weekdays:
                schedule = .weekdays(hour: clamp(a.hour ?? 8, 0...23), minute: clamp(a.minute ?? 0, 0...59))
            case .weekly:
                schedule = .weekly(weekday: clamp(a.weekday ?? 2, 1...7), hour: clamp(a.hour ?? 8, 0...23), minute: clamp(a.minute ?? 0, 0...59))
            case .interval:
                schedule = .interval(minutes: max(a.everyMinutes ?? 60, 15))
            case .once:
                guard let raw = a.at, let date = TextUtil.parseDate(raw), date > Date() else {
                    return "Error: once needs a future time in `at` (YYYY-MM-DD HH:mm)."
                }
                schedule = .once(date)
            }
            let job = try await context.cron.add(name: a.jobName ?? String(prompt.prefix(30)), prompt: prompt, schedule: schedule)
            await context.log(name, "create \(job.scheduleDescription)")
            return "Scheduled \"\(job.name)\" (\(job.id)) \(job.scheduleDescription). "
                + "For exact timing the user should add the Shortcuts automation described in Settings › Scheduled jobs."
        }
    }
}

private func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}
