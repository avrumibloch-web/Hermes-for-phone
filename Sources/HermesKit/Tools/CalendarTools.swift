import Foundation
import EventKit
import FoundationModels

/// Owns the EKEventStore (not Sendable) so tools can share it safely.
public actor CalendarService {
    private let store = EKEventStore()

    public init() {}

    private func ensureEventAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        guard try await store.requestFullAccessToEvents() else { throw AccessError.denied("Calendar") }
    }

    private func ensureReminderAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return }
        guard try await store.requestFullAccessToReminders() else { throw AccessError.denied("Reminders") }
    }

    enum AccessError: LocalizedError {
        case denied(String)
        var errorDescription: String? {
            if case .denied(let what) = self { return "\(what) access is off. Enable it in Settings › Privacy & Security › \(what)." }
            return nil
        }
    }

    func events(from start: Date, to end: Date) async throws -> [String] {
        try await ensureEventAccess()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d HH:mm"
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)
            .map { e in
                let time = e.isAllDay ? "\(TextUtil.localDate.string(from: e.startDate)) all day" : df.string(from: e.startDate)
                let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
                return "\(time): \(e.title ?? "(untitled)")\(loc)"
            }
    }

    func createEvent(title: String, start: Date, minutes: Int, location: String?) async throws -> String {
        try await ensureEventAccess()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(minutes, 5) * 60))
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return "Created \"\(title)\" on \(TextUtil.localDateTime.string(from: start)) for \(minutes) min."
    }

    func reminders(includeCompleted: Bool) async throws -> [String] {
        try await ensureReminderAccess()
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Map to strings inside the callback: EKReminder isn't Sendable.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).prefix(30).map { r -> String in
                    var line = (r.isCompleted ? "[x] " : "[ ] ") + (r.title ?? "(untitled)")
                    if let due = r.dueDateComponents?.date { line += " (due \(TextUtil.localDateTime.string(from: due)))" }
                    return line
                }
                continuation.resume(returning: Array(lines))
            }
        }
    }

    func createReminder(title: String, due: Date?, notes: String?) async throws -> String {
        try await ensureReminderAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return "Added reminder \"\(title)\"" + (due.map { " for \(TextUtil.localDateTime.string(from: $0))" } ?? "") + "."
    }
}

// Small models are bad at date arithmetic, so reading takes day offsets instead of dates.
struct CalendarEventsTool: Tool {
    let name = "calendar_events"
    let description = "Read calendar events. startDay 0 = today, 1 = tomorrow, -1 = yesterday. days = how many days to cover (1-14)."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "First day as an offset from today", .range(-30...365))
        var startDay: Int
        @Guide(description: "Number of days to include", .range(1...14))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: arguments.startDay, to: today),
              let end = cal.date(byAdding: .day, value: min(max(arguments.days, 1), 14), to: start) else {
            return "Error: invalid range."
        }
        do {
            let lines = try await context.calendar.events(from: start, to: end)
            await context.log(name, "\(lines.count) events")
            return lines.isEmpty ? "No events in that range." : lines.joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

struct CreateCalendarEventTool: Tool {
    let name = "create_calendar_event"
    let description = "Add an event to the user's default calendar."
    let context: ToolContext

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Start as YYYY-MM-DD HH:mm local time")
        var start: String
        @Guide(description: "Duration in minutes", .range(5...1440))
        var durationMinutes: Int
        var location: String?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let start = TextUtil.parseDate(arguments.start) else { return "Error: start must be YYYY-MM-DD HH:mm." }
        do {
            let result = try await context.calendar.createEvent(
                title: arguments.title, start: start, minutes: arguments.durationMinutes, location: arguments.location
            )
            await context.log(name, result)
            return result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

struct RemindersListTool: Tool {
    let name = "reminders_list"
    let description = "List the user's reminders (incomplete by default)."
    let context: ToolContext

    @Generable
    struct Arguments {
        var includeCompleted: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let lines = try await context.calendar.reminders(includeCompleted: arguments.includeCompleted)
            await context.log(name, "\(lines.count) reminders")
            return lines.isEmpty ? "No reminders." : lines.joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

struct CreateReminderTool: Tool {
    let name = "create_reminder"
    let description = "Add a reminder, optionally with a due time that alerts the user."
    let context: ToolContext

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Optional due time as YYYY-MM-DD HH:mm local time")
        var due: String?
        var notes: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var due: Date?
        if let raw = arguments.due, !raw.isEmpty {
            guard let d = TextUtil.parseDate(raw) else { return "Error: due must be YYYY-MM-DD HH:mm." }
            due = d
        }
        do {
            let result = try await context.calendar.createReminder(title: arguments.title, due: due, notes: arguments.notes)
            await context.log(name, result)
            return result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
