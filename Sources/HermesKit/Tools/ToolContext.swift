import Foundation
import FoundationModels

/// Everything a tool may touch during one turn. Built fresh per turn so concurrent turns
/// (a chat reply and a background review) keep separate activity logs.
public final class ToolContext: Sendable {
    let memory: MemoryStore
    let skills: SkillStore
    let sessions: SessionStore
    let cron: CronStore
    let calendar: CalendarService
    let settings: HermesSettings
    let sessionID: String
    let activity: ToolActivityLog
    /// Runs a focused subagent and returns its final answer (delegate_task). nil inside a
    /// subagent, so delegation is one level deep, as in Hermes.
    let delegate: (@Sendable (_ goal: String, _ context: String) async throws -> String)?

    init(
        memory: MemoryStore, skills: SkillStore, sessions: SessionStore, cron: CronStore,
        calendar: CalendarService, settings: HermesSettings, sessionID: String,
        activity: ToolActivityLog,
        delegate: (@Sendable (_ goal: String, _ context: String) async throws -> String)?
    ) {
        self.memory = memory
        self.skills = skills
        self.sessions = sessions
        self.cron = cron
        self.calendar = calendar
        self.settings = settings
        self.sessionID = sessionID
        self.activity = activity
        self.delegate = delegate
    }

    func log(_ tool: String, _ summary: String) async {
        await activity.record(tool, summary)
    }
}

/// Maps toolsets to concrete Foundation Models tools.
enum ToolRegistry {
    static func tools(for sets: [Toolset], context c: ToolContext, limit: Int) -> [any Tool] {
        var out: [any Tool] = []
        for set in sets {
            switch set {
            case .memory: out.append(MemoryTool(context: c))
            case .skills: out += [SkillViewTool(context: c), SkillsListTool(context: c)]
            case .skillAuthoring: out.append(SkillManageTool(context: c))
            case .sessions: out.append(SessionSearchTool(context: c))
            case .device:
                #if os(macOS)
                out += [DiskUsageTool(context: c), DeviceStatusTool(context: c)]
                #else
                out.append(DeviceStatusTool(context: c))
                #endif
            case .calendar: out += [CalendarEventsTool(context: c), CreateCalendarEventTool(context: c)]
            case .reminders: out += [RemindersListTool(context: c), CreateReminderTool(context: c)]
            case .web: if c.settings.allowNetworkTools { out.append(WebFetchTool(context: c)) }
            case .shortcuts: out.append(RunShortcutTool(context: c))
            case .cron: out.append(CronJobTool(context: c))
            case .delegate: if c.delegate != nil { out.append(DelegateTaskTool(context: c)) }
            case .terminal:
                #if os(macOS)
                if c.settings.allowTerminal { out.append(TerminalTool(context: c)) }
                #else
                break
                #endif
            }
        }
        // Toolsets are in priority order (memory and skills first), so trimming drops the
        // least likely tools.
        return Array(out.prefix(limit))
    }
}
