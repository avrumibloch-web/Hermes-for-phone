import Foundation
import FoundationModels

/// Hermes' closed learning loop: after substantial turns a background review looks at the
/// conversation and decides whether anything belongs in memory (USER.md / MEMORY.md) or in
/// a skill. Hermes forks the agent into a thread after the turn. On the phone, the
/// session is *flagged* instead, and reviews run when the app goes to the background or in
/// a BGProcessingTask, so they never compete with the user for the Neural Engine.
extension HermesAgent {
    static let learningCues = [
        "remember", "don't forget", "i prefer", "i like", "i hate", "i don't like", "always", "never",
        "from now on", "actually", "no,", "that's wrong", "not what i", "my name", "i live", "i work",
        "my wife", "my husband", "my partner", "my kid", "my son", "my daughter", "call me",
    ]

    // Condensed from Hermes' combined memory + skill review prompt (agent/background_review.py).
    static let reviewPrompt = """
    Review the conversation above. Decide whether anything should be saved for future sessions.

    Two memory stores, pick ONE per fact:
    • target "user": who the user is: preferences, communication style, personal details they shared.
    • target "memory": facts about their environment: devices, apps, services, addresses of servers, conventions.
    Write each entry as a short declarative fact. If an entry on the same topic exists, replace it instead of adding.

    A skill is a reusable procedure for a CLASS of task, to this user's specifications: the steps \
    in order, the tools that worked, how they want the result. Create or patch one only if this \
    conversation worked out such a procedure, or the user corrected how a task should be done.

    Do NOT save: one-off requests, things that only matter today, failures that were not resolved, \
    or claims that a tool doesn't work.

    If nothing is worth saving, reply exactly "Nothing to save." Otherwise make the tool calls, then reply with one line saying what you saved.
    """

    func shouldReview(session: LiveSession, userText: String, toolCalls: Int) -> Bool {
        guard settings.backgroundReview else { return false }
        guard session.source != .review, session.source != .subagent else { return false }
        let lower = userText.lowercased()
        // Hermes nudges on an interval as well as on signals; every 6th user turn here.
        return toolCalls >= 3
            || Self.learningCues.contains(where: { lower.contains($0) })
            || session.userTurns % 6 == 0
    }

    /// Runs queued reviews. Call from scene-phase → background (inside a background task
    /// assertion) and from the BGProcessingTask handler.
    @discardableResult
    public func runPendingReviews(limit: Int = 2) async -> Int {
        guard settings.backgroundReview, await workerTier() != nil else { return 0 }
        let pending = (try? await sessions.sessionsNeedingReview(limit: limit)) ?? []
        var done = 0
        for info in pending {
            if Task.isCancelled { break }
            await review(info)
            try? await sessions.setNeedsReview(info.id, false)
            done += 1
        }
        return done
    }

    private func review(_ info: SessionStore.SessionInfo) async {
        guard let messages = try? await sessions.messages(info.id, after: 0) else { return }
        // Most recent ~7,000 chars (~2.2K tokens) of the conversation, newest kept.
        var lines: [String] = []
        var used = 0
        for m in messages.reversed() {
            let who: String
            switch m.role {
            case "user": who = "User"
            case "assistant": who = "Hermes"
            default: who = "Tools used"
            }
            let line = "\(who): \(TextUtil.truncate(m.content, to: 600))"
            if used + line.count > 7_000 { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        guard !lines.isEmpty else { return }

        let activity = ToolActivityLog()
        let context = makeToolContext(sessionID: info.id, source: .review, activity: activity)
        let tools: [any Tool] = [MemoryTool(context: context), SkillManageTool(context: context), SkillsListTool(context: context)]
        // The reviewer sees LIVE memory (not the session's frozen snapshot) so it can
        // replace instead of duplicating.
        let instructions = await self.instructions(
            snapshot: await memory.snapshot(), summary: nil, toolsets: [.memory, .skills, .skillAuthoring], preloaded: []
        )
        var prompt = ""
        if let summary = info.summary, !summary.isEmpty { prompt += "Earlier (summary): \(summary)\n\n" }
        prompt += "Conversation:\n" + lines.joined(separator: "\n") + "\n\n" + Self.reviewPrompt

        do {
            guard let tier = await workerTier() else { return }
            let session = models.makeSession(tier: tier, tools: tools, instructions: instructions)
            let content = try await models.respond(session, to: prompt, tier: tier)
            let saved = await activity.drain()
            if !saved.isEmpty {
                let log = "Learning review: " + content + "\n" + saved.map { "\($0.tool): \($0.summary)" }.joined(separator: "\n")
                try? await sessions.append(info.id, role: "tool", content: log)
            }
        } catch {
            // A failed review is not user-visible; the next flagged turn tries again.
        }
    }
}
