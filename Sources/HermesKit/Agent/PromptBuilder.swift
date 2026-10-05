import Foundation

/// Assembles the system instructions the way Hermes does (identity → memory guidance →
/// frozen memory snapshot → skills index → session-search guidance), condensed for an
/// ~8K-token on-device context.
public enum PromptBuilder {
    public static let defaultIdentity = """
    You are Hermes, a personal agent running privately on the user's iPhone. Be direct: match the \
    length of your reply to the weight of the ask; a one-line question gets a one-line answer. No \
    filler, no restating the request, no narrating tool calls. When unsure, say so plainly. Agree \
    because it's right, not because the user said it.
    """

    // Hermes' memory guidance, shortened. The routing rule (skills first, memory is the
    // narrow exception) and the declarative-not-imperative rule are kept verbatim in spirit.
    static let memoryGuidance = """
    You have persistent memory carried across sessions. Procedures and how-to knowledge belong in \
    skills (skill_manage); memory is only for facts true in EVERY session: who the user is, their \
    preferences, environment facts. Write declarative facts ("User prefers short answers"), not \
    commands to yourself. Memory has a hard size budget: when it is full, replace or merge stale \
    entries instead of skipping the save. Only say something is saved after the memory tool \
    reports success.
    """

    static let skillsGuidance = """
    Skills are saved procedures. If one below matches the task, load it with skill_view before \
    acting and follow it. When you work out a reusable multi-step workflow, offer to save it as a skill.
    """

    static let sessionSearchGuidance = """
    If the user refers to an earlier conversation, use session_search before asking them to repeat themselves.
    """

    static let toolDiscipline = """
    Use a tool only when it is needed to answer or act. Never invent tool results. Dates for tools \
    use the format YYYY-MM-DD HH:mm in the user's local time.
    """

    public struct Parts: Sendable {
        public var identity: String
        public var memorySnapshot: String
        public var skillsIndex: String
        public var conversationSummary: String?
        public var preloadedSkills: [(name: String, body: String)] = []
        public var hasMemoryTool: Bool
        public var hasSkillTools: Bool
        public var hasSessionSearch: Bool
        public var now: Date = Date()
        public var timeZone: TimeZone = .current
        public var locale: Locale = .current
    }

    public static func instructions(_ p: Parts) -> String {
        var out: [String] = [p.identity.trimmingCharacters(in: .whitespacesAndNewlines)]

        let when = DateFormatter()
        when.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        when.timeZone = p.timeZone
        out.append("Now: \(when.string(from: p.now)) (\(p.timeZone.identifier)). Device: iPhone. Locale: \(p.locale.identifier).")

        out.append(toolDiscipline)
        if p.hasMemoryTool { out.append(memoryGuidance) }
        if !p.memorySnapshot.isEmpty { out.append(p.memorySnapshot) }

        if !p.skillsIndex.isEmpty, p.hasSkillTools {
            out.append(skillsGuidance + "\nSKILLS\n" + p.skillsIndex)
        }
        for skill in p.preloadedSkills {
            out.append("LOADED SKILL: \(skill.name)\n\(skill.body)")
        }
        if p.hasSessionSearch { out.append(sessionSearchGuidance) }

        if let summary = p.conversationSummary, !summary.isEmpty {
            out.append("EARLIER IN THIS CONVERSATION (summary)\n" + summary)
        }
        return out.joined(separator: "\n\n")
    }

    /// Recent turns rendered as a plain transcript; the new message goes last.
    public static func prompt(history: [SessionStore.Message], userMessage: String) -> String {
        guard !history.isEmpty else { return userMessage }
        let lines = history.compactMap { m -> String? in
            switch m.role {
            case "user": return "User: \(m.content)"
            case "assistant": return "Hermes: \(m.content)"
            default: return nil
            }
        }
        return "Conversation so far:\n" + lines.joined(separator: "\n") + "\n\nUser's new message:\n" + userMessage
    }
}
