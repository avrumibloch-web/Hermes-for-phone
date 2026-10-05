import Foundation

/// Hermes groups tools into toolsets. On the phone every tool schema eats into an 8K
/// context and a ~3B model chooses tools less reliably from a long list, so each turn gets
/// only the toolsets the request plausibly needs.
public enum Toolset: String, CaseIterable, Sendable, Codable {
    case memory          // memory
    case skills          // skills_list, skill_view
    case skillAuthoring  // skill_manage
    case sessions        // session_search
    case device          // device_status (+ disk_usage on Mac)
    case calendar        // calendar_events, create_calendar_event
    case reminders       // reminders_list, create_reminder
    case web             // web_fetch
    case shortcuts       // run_shortcut
    case cron            // cronjob
    case delegate        // delegate_task
    case terminal        // terminal (Mac only, off by default)
}

/// Which model runs a turn. All three are reached through the same Foundation Models
/// API (`LanguageModelSession`), and none costs anything per token.
public enum ModelTier: String, Sendable, Codable {
    /// Apple's on-device model (`SystemLanguageModel`). Fast, offline, 8K context.
    case onDevice
    /// An open-weight model (e.g. Qwen3) running on this device through MLX.
    case local
    /// Apple's server model on Private Cloud Compute: 32K context, reasoning, free
    /// with a daily per-user limit.
    case privateCloud
}

public struct RouteDecision: Sendable, Equatable {
    public var toolsets: [Toolset]
    /// The request should go to the "smart" model (local MLX or PCC) if one is set up.
    public var wantsSmart: Bool
    public var reason: String
}

public enum Router {
    static let keywords: [(Toolset, [String])] = [
        (.calendar, ["calendar", "meeting", "event", "schedule", "appointment", "agenda", "free time", "busy", "today", "tomorrow", "this week", "next week"]),
        (.reminders, ["remind", "reminder", "to-do", "todo", "task list", "grocery", "shopping list"]),
        (.device, ["battery", "charge", "storage", "disk", "space left", "what's using", "whats using", "low power", "thermal", "hot", "device", "phone status"]),
        (.sessions, ["last time", "earlier", "yesterday", "we talked", "we discussed", "did i tell", "did i say", "remember when", "previous", "before", "you said"]),
        (.web, ["http://", "https://", "website", "web page", "url", "fetch", "look up", "server", " api", "jellyfin", "endpoint"]),
        (.shortcuts, ["shortcut", "home", "lights", "thermostat", "music", "play ", "send message", "text ", "message "]),
        (.cron, ["every day", "every weekday", "weekdays", "every morning", "every evening", "every night", "every week", "daily", "weekly", "each morning", "every hour", "schedule a job", "recurring", "cron", "automatically at"]),
        (.skillAuthoring, ["skill", "save this workflow", "save the procedure", "learn how", "/learn", "remember how to"]),
        (.delegate, ["research", "compare", "step by step", "plan out", "break down", "investigate"]),
        (.terminal, ["terminal", "shell", "command line", "run the command", "brew ", "git ", "script", "process", "folder", "directory", "files in"]),
    ]

    static let hardSignals = [
        "analyze", "analyse", "explain in detail", "write code", "debug", "prove", "derive", "essay",
        "detailed plan", "think hard", "think carefully", "reason through", "pros and cons", "compare and contrast",
    ]

    static let toolsetForTool: [String: Toolset] = [
        "calendar_events": .calendar, "create_calendar_event": .calendar,
        "reminders_list": .reminders, "create_reminder": .reminders,
        "device_status": .device, "web_fetch": .web, "run_shortcut": .shortcuts,
        "session_search": .sessions, "cronjob": .cron, "skill_manage": .skillAuthoring,
        "delegate_task": .delegate, "terminal": .terminal, "disk_usage": .device,
    ]

    /// Toolsets whose tools a skill body mentions, so a loaded skill gets the tools its
    /// procedure calls for.
    public static func toolsets(referencedBy text: String) -> [Toolset] {
        var seen = Set<Toolset>()
        return toolsetForTool
            .filter { text.contains($0.key) }
            .map { $0.value }
            .sorted { $0.rawValue < $1.rawValue }
            .filter { seen.insert($0).inserted }
    }

    /// Skills the message names in plain words ("my morning briefing" → morning-briefing),
    /// so they load without the user typing a slash command.
    public static func impliedSkills(in message: String, installed: Set<String>) -> [String] {
        let text = message.lowercased()
        return installed
            .filter { text.contains($0.replacingOccurrences(of: "-", with: " ")) }
            .sorted()
    }

    /// Picks toolsets, and whether the request wants the smart model.
    /// `forceSmart`: true for `/think`, false for `/fast`, nil to decide here.
    public static func route(
        _ message: String,
        settings: HermesSettings,
        hasSkills: Bool,
        forceSmart: Bool? = nil,
        loadedSkillBodies: [String] = []
    ) -> RouteDecision {
        let text = message.lowercased()
        // Always on: memory (so the learning loop works in every turn) and skill lookup.
        // A loaded skill's own tools come before skill lookup and keyword guesses, so the
        // per-turn tool cap never drops what the procedure needs.
        var sets: [Toolset] = [.memory]
        for body in loadedSkillBodies {
            sets += toolsets(referencedBy: body).filter { $0 != .web || settings.allowNetworkTools }
        }
        if hasSkills { sets.append(.skills) }

        for (set, words) in keywords where words.contains(where: { text.contains($0) }) {
            if set == .web, !settings.allowNetworkTools { continue }
            if set == .terminal, !settings.allowTerminal { continue }
            sets.append(set)
        }

        let wantsSmart: Bool
        let reason: String
        if let forceSmart {
            wantsSmart = forceSmart
            reason = forceSmart ? "/think" : "/fast"
        } else if settings.smartModel == .off {
            wantsSmart = false
            reason = "no smart model set up"
        } else if settings.useSmartModelForEverything {
            wantsSmart = true
            reason = "smart model for everything"
        } else if settings.autoEscalate,
                  message.count > 900 || hardSignals.contains(where: { text.contains($0) }) {
            wantsSmart = true
            reason = "looks hard"
        } else {
            wantsSmart = false
            reason = "simple"
        }

        // Remove duplicates, keep order.
        var seen = Set<Toolset>()
        sets = sets.filter { seen.insert($0).inserted }
        return RouteDecision(toolsets: sets, wantsSmart: wantsSmart, reason: reason)
    }
}
