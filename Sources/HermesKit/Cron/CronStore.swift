import Foundation

/// Hermes' cron, adapted to iOS. iOS has no always-on daemon, so jobs are *stored* here and
/// *run* when the system gives the app time:
///   1. a Shortcuts personal automation (Time of Day → "Run Hermes Scheduled Jobs") — the
///      reliable path, runs at the exact time
///   2. a BGAppRefreshTask — opportunistic, iOS decides when
///   3. whenever the app comes to the foreground
/// Results are delivered as local notifications.
public struct CronJob: Codable, Sendable, Identifiable, Hashable {
    public enum Schedule: Codable, Sendable, Hashable {
        case once(Date)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)               // Monday–Friday
        case weekly(weekday: Int, hour: Int, minute: Int)   // 1 = Sunday … 7 = Saturday
        case interval(minutes: Int)
    }

    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: Schedule
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastResult: String?

    public var scheduleDescription: String {
        switch schedule {
        case .once(let d): return "once at \(TextUtil.localDateTime.string(from: d))"
        case .daily(let h, let m): return String(format: "daily at %02d:%02d", h, m)
        case .weekdays(let h, let m): return String(format: "weekdays at %02d:%02d", h, m)
        case .weekly(let w, let h, let m):
            let names = Calendar.current.weekdaySymbols
            let day = (1...7).contains(w) ? names[w - 1] : "day \(w)"
            return String(format: "every %@ at %02d:%02d", day, h, m)
        case .interval(let n): return n % 60 == 0 ? "every \(n / 60)h" : "every \(n) min"
        }
    }
}

extension CronJob.Schedule {
    /// The first fire time strictly after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once(let d):
            return d > date ? d : nil
        case .daily(let h, let m):
            return calendar.nextDate(after: date, matching: DateComponents(hour: h, minute: m, second: 0), matchingPolicy: .nextTime)
        case .weekdays(let h, let m):
            var cursor = date
            for _ in 0..<8 {
                guard let candidate = calendar.nextDate(after: cursor, matching: DateComponents(hour: h, minute: m, second: 0), matchingPolicy: .nextTime) else { return nil }
                let weekday = calendar.component(.weekday, from: candidate)
                if (2...6).contains(weekday) { return candidate }
                cursor = candidate
            }
            return nil
        case .weekly(let w, let h, let m):
            return calendar.nextDate(after: date, matching: DateComponents(hour: h, minute: m, second: 0, weekday: w), matchingPolicy: .nextTime)
        case .interval(let n):
            return date.addingTimeInterval(TimeInterval(max(n, 15) * 60))
        }
    }
}

public actor CronStore {
    private let url: URL
    private var jobs: [CronJob] = []

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode([CronJob].self, from: data) {
            jobs = decoded
        }
    }

    public func all() -> [CronJob] { jobs }

    @discardableResult
    public func add(name: String, prompt: String, schedule: CronJob.Schedule, now: Date = Date()) throws -> CronJob {
        let job = CronJob(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            name: name, prompt: prompt, schedule: schedule, enabled: true,
            createdAt: now, lastRunAt: nil, nextRunAt: schedule.next(after: now), lastResult: nil
        )
        jobs.append(job)
        try save()
        return job
    }

    public func remove(id: String) throws -> Bool {
        let before = jobs.count
        jobs.removeAll { $0.id == id }
        try save()
        return jobs.count != before
    }

    public func setEnabled(id: String, _ enabled: Bool, now: Date = Date()) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].enabled = enabled
        if enabled { jobs[i].nextRunAt = jobs[i].schedule.next(after: now) }
        try save()
    }

    public func due(now: Date = Date()) -> [CronJob] {
        jobs.filter { $0.enabled && ($0.nextRunAt.map { $0 <= now } ?? false) }
    }

    /// Records a run and advances the job. A job that was missed several times while the
    /// phone was asleep runs once, not once per missed slot.
    public func markRan(id: String, result: String, at now: Date = Date()) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].lastRunAt = now
        jobs[i].lastResult = TextUtil.truncate(result, to: 500)
        jobs[i].nextRunAt = jobs[i].schedule.next(after: now)
        if jobs[i].nextRunAt == nil { jobs[i].enabled = false }
        try save()
    }

    public func nextWake() -> Date? {
        jobs.filter(\.enabled).compactMap(\.nextRunAt).min()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(jobs).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
