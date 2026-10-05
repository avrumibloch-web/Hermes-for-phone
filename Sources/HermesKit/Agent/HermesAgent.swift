import Foundation
import FoundationModels

public struct AgentReply: Sendable {
    public let text: String
    public let sessionID: String
    public let tier: ModelTier
    public let activity: [ToolActivityLog.Entry]
    public let compressedHistory: Bool
}

/// The harness. One instance per app process, shared by the chat UI, Siri (App Intents),
/// scheduled jobs and the learning loop.
///
/// Per turn:
///   1. parse slash commands, route to toolsets + model tier
///   2. build instructions: identity, frozen memory snapshot, skills index, summary
///   3. fit recent history into what's left of the context; summarize the overflow
///   4. one LanguageModelSession with only the routed tools; the framework runs the
///      tool-call loop (model → tool → model …) until a final answer
///   5. persist messages + tool activity; flag the session for the learning loop
public actor HermesAgent {
    public let paths: HermesPaths
    public let memory: MemoryStore
    public let skills: SkillStore
    public let sessions: SessionStore
    public let cron: CronStore
    let calendar = CalendarService()
    let models = ModelProvider()
    let counter: TokenCounting
    public private(set) var settings: HermesSettings

    /// Hermes' frozen snapshot: memory is captured once when a session starts, so writes
    /// during the session don't shift the prompt under the model.
    struct LiveSession {
        let id: String
        let source: SessionStore.Source
        let memorySnapshot: String
        var lastActive: Date
        var userTurns = 0
    }

    var live: [String: LiveSession] = [:]
    var siriSessionID: String?

    public init(paths: HermesPaths, settings: HermesSettings = .load(), counter: TokenCounting = SystemTokenCounter()) throws {
        try paths.prepare()
        self.paths = paths
        self.settings = settings
        self.counter = counter
        memory = MemoryStore(directory: paths.memories, memoryLimit: settings.memoryCharLimit, userLimit: settings.userCharLimit)
        skills = SkillStore(root: paths.skills)
        sessions = try SessionStore(url: paths.stateDB)
        cron = CronStore(url: paths.cronJobs)
    }

    /// Call once after init: seeds the bundled skills.
    public func bootstrap() async {
        let bundled = Bundle.module.url(forResource: "BundledSkills", withExtension: nil)
        await skills.seedBundledSkills(from: bundled, optOutMarker: paths.noBundledSkillsMarker)
    }

    public func update(settings new: HermesSettings) async {
        settings = new
        new.save()
        await memory.setLimits(memory: new.memoryCharLimit, user: new.userCharLimit)
    }

    /// nil when ready; otherwise why the agent can't run.
    public func availabilityProblem() -> String? {
        guard let reason = models.onDeviceUnavailableReason() else { return nil }
        return settings.allowPrivateCloud ? nil : reason
    }

    // MARK: Sessions

    /// Starts a session (Hermes' `/new`): fresh context, fresh memory snapshot.
    public func newSession(source: SessionStore.Source, title: String? = nil) async throws -> String {
        let id = try await sessions.createSession(source: source, title: title)
        live[id] = LiveSession(id: id, source: source, memorySnapshot: await memory.snapshot(), lastActive: Date())
        if source == .siri { siriSessionID = id }
        return id
    }

    /// Siri requests share one rolling session until it has been idle for
    /// `siriSessionIdleMinutes`; then the next request starts a new one.
    public func siriSession() async throws -> String {
        if let id = siriSessionID, let s = live[id],
           Date().timeIntervalSince(s.lastActive) < TimeInterval(settings.siriSessionIdleMinutes * 60) {
            return id
        }
        return try await newSession(source: .siri)
    }

    /// "New Hermes conversation" from Siri.
    public func endSiriSession() {
        if let id = siriSessionID { live[id] = nil }
        siriSessionID = nil
    }

    private func liveSession(_ id: String) async throws -> LiveSession {
        if let s = live[id] { return s }
        let source = try await sessions.session(id)?.source ?? .app
        let s = LiveSession(id: id, source: source, memorySnapshot: await memory.snapshot(), lastActive: Date())
        live[id] = s
        return s
    }

    // MARK: The turn

    public func send(_ input: String, sessionID: String) async throws -> AgentReply {
        var session = try await liveSession(sessionID)
        let installed = Set(await skills.list().map(\.name))
        let command = SlashCommand.parse(input, installedSkills: installed)
        let text = command.text

        var skillNames = command.skills
        for name in Router.impliedSkills(in: text, installed: installed) where !skillNames.contains(name) && skillNames.count < 2 {
            skillNames.append(name)
        }
        var preloaded: [(name: String, body: String)] = []
        for name in skillNames {
            if let body = await skills.body(of: name) { preloaded.append((name, TextUtil.truncate(body, to: 2_400))) }
        }

        var route = Router.route(
            text, settings: settings, hasSkills: !installed.isEmpty, forceTier: command.forceTier,
            loadedSkillBodies: preloaded.map { $0.body }
        )
        // Unattended sources can't open Shortcuts, and cron jobs don't schedule more cron jobs.
        if session.source != .app { route.toolsets.removeAll { $0 == .shortcuts } }
        if session.source == .cron { route.toolsets.removeAll { $0 == .cron } }

        var tier = route.tier
        if tier == .privateCloud, !settings.allowPrivateCloud { tier = .onDevice }
        if tier == .onDevice, let problem = models.onDeviceUnavailableReason() {
            guard settings.allowPrivateCloud else {
                return AgentReply(text: problem, sessionID: sessionID, tier: tier, activity: [], compressedHistory: false)
            }
            tier = .privateCloud
        }

        let userMessageID = try await sessions.append(sessionID, role: "user", content: input)
        session.userTurns += 1
        session.lastActive = Date()
        live[sessionID] = session
        if session.userTurns == 1, (try await sessions.session(sessionID))?.title == nil {
            try await sessions.setTitle(sessionID, String(text.prefix(48)))
        }

        let activity = ToolActivityLog()
        let context = makeToolContext(sessionID: sessionID, source: session.source, activity: activity)
        let tools = ToolRegistry.tools(for: route.toolsets, context: context, limit: settings.maxToolsPerTurn)

        var compressed = false
        var replyText: String?
        var lastFailure: GenerationFailure?

        // Attempt 0: normal. Attempt 1: squeeze history harder. Attempt 2: escalate to PCC if allowed.
        for attempt in 0..<3 {
            if attempt == 2 {
                guard tier == .onDevice, settings.allowPrivateCloud else { break }
                tier = .privateCloud
            }
            let prepared = try await prepareTurn(
                session: session, userText: text, excludeMessageID: userMessageID,
                tier: tier, toolCount: tools.count, toolsets: route.toolsets,
                preloaded: preloaded, squeeze: attempt == 1
            )
            compressed = compressed || prepared.compressed
            do {
                let lm = models.makeSession(tier: tier, tools: tools, instructions: prepared.instructions)
                let response = try await lm.respond(to: prepared.prompt, options: models.generationOptions(for: tier))
                replyText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            } catch {
                let failure = GenerationFailure(error)
                lastFailure = failure
                if case .contextOverflow = failure { continue }
                break
            }
        }

        let entries = await activity.drain()
        let finalText = replyText ?? (lastFailure?.userMessage ?? "No response.")
        try await sessions.append(sessionID, role: "assistant", content: finalText)
        if !entries.isEmpty {
            let log = entries.map { "\($0.tool): \($0.summary)" }.joined(separator: "\n")
            try await sessions.append(sessionID, role: "tool", content: log)
        }
        if replyText != nil, shouldReview(session: session, userText: text, toolCalls: entries.count) {
            try await sessions.setNeedsReview(sessionID, true)
        }
        return AgentReply(text: finalText, sessionID: sessionID, tier: tier, activity: entries, compressedHistory: compressed)
    }

    // MARK: Context assembly

    struct PreparedTurn {
        let instructions: String
        let prompt: String
        let compressed: Bool
    }

    func instructions(
        snapshot: String, summary: String?, toolsets: [Toolset], preloaded: [(name: String, body: String)]
    ) async -> String {
        let identity = (try? String(contentsOf: paths.soul, encoding: .utf8)) ?? PromptBuilder.defaultIdentity
        let hasSkills = toolsets.contains(.skills)
        let parts = PromptBuilder.Parts(
            identity: identity,
            memorySnapshot: snapshot,
            skillsIndex: hasSkills ? await skills.index(maxChars: settings.skillsIndexCharLimit) : "",
            conversationSummary: summary,
            preloadedSkills: preloaded,
            hasMemoryTool: toolsets.contains(.memory),
            hasSkillTools: hasSkills,
            hasSessionSearch: toolsets.contains(.sessions)
        )
        return PromptBuilder.instructions(parts)
    }

    private func prepareTurn(
        session: LiveSession, userText: String, excludeMessageID: Int64, tier: ModelTier,
        toolCount: Int, toolsets: [Toolset], preloaded: [(name: String, body: String)], squeeze: Bool
    ) async throws -> PreparedTurn {
        var compressed = false
        let budget = models.contextBudget(for: tier)
        for _ in 0..<3 {
            let info = try await sessions.session(session.id)
            let instr = await instructions(snapshot: session.memorySnapshot, summary: info?.summary, toolsets: toolsets, preloaded: preloaded)
            var allowance = budget.historyAllowance(instructionTokens: await counter.count(instr), toolCount: toolCount)
            if squeeze { allowance /= 2 }
            let history = try await sessions.messages(session.id, after: info?.compactedThrough ?? 0)
                .filter { ($0.role == "user" || $0.role == "assistant") && $0.id != excludeMessageID }
            let plan = await HistoryFitter.plan(
                history: history, newMessage: userText, allowance: allowance, counter: counter, maxKeep: squeeze ? 4 : 12
            )
            if plan.compress.isEmpty {
                return PreparedTurn(instructions: instr, prompt: PromptBuilder.prompt(history: plan.keep, userMessage: userText), compressed: compressed)
            }
            try await compress(sessionID: session.id, previousSummary: info?.summary, messages: plan.compress)
            compressed = true
        }
        // Still doesn't fit (e.g. a huge message): send it without history.
        let info = try await sessions.session(session.id)
        let instr = await instructions(snapshot: session.memorySnapshot, summary: info?.summary, toolsets: toolsets, preloaded: preloaded)
        return PreparedTurn(instructions: instr, prompt: userText, compressed: compressed)
    }

    func makeToolContext(sessionID: String, source: SessionStore.Source, activity: ToolActivityLog) -> ToolContext {
        let canDelegate = source != .subagent && source != .review
        return ToolContext(
            memory: memory, skills: skills, sessions: sessions, cron: cron, calendar: calendar,
            settings: settings, sessionID: sessionID, activity: activity,
            delegate: canDelegate ? { [weak self] goal, details in
                guard let self else { return "Error: agent unavailable." }
                return try await self.runSubagent(goal: goal, details: details)
            } : nil
        )
    }

    // MARK: Delegation

    func runSubagent(goal: String, details: String) async throws -> String {
        let id = try await newSession(source: .subagent, title: String(goal.prefix(48)))
        let prompt = """
        \(goal)

        Details:
        \(details)

        You are a helper working for Hermes. Do the task with your tools, then reply with only the result, in under 150 words.
        """
        let reply = try await send(prompt, sessionID: id)
        live[id] = nil
        return reply.text
    }
}
