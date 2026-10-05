import Foundation
import FoundationModels

/// Hermes compresses the middle of a long conversation into a summary and keeps the tail
/// verbatim. Same here, but it triggers much sooner: the on-device context is 8K tokens.
/// The summary is rolling (each compression folds new messages into the previous summary)
/// and is stored on the session row, so it survives app restarts.
extension HermesAgent {
    static let summaryCharLimit = 900
    static let chunkCharLimit = 7_000

    static let summarizerInstructions = """
    You maintain a running summary of a conversation between the user and Hermes, their \
    phone assistant, so Hermes can continue it later without the full transcript. Keep: facts \
    the user stated, decisions, names, numbers, dates, what Hermes did with tools, and open \
    questions or unfinished tasks. Drop greetings and filler. Write plain sentences, at most 120 words.
    """

    func compress(sessionID: String, previousSummary: String?, messages: [SessionStore.Message]) async throws {
        guard let lastID = messages.last?.id else { return }
        let lines = messages.map { m -> String in
            let who = m.role == "user" ? "User" : "Hermes"
            return "\(who): \(TextUtil.truncate(m.content, to: 700))"
        }
        // Fold in chunks so one oversized backlog can't overflow the summarizer itself.
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count > Self.chunkCharLimit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }

        var summary = previousSummary ?? ""
        for chunk in chunks {
            summary = await summarize(previous: summary, transcript: chunk)
        }
        try await sessions.setSummary(sessionID, summary: summary, compactedThrough: lastID)
    }

    private func summarize(previous: String, transcript: String) async -> String {
        let prompt = """
        Current summary:
        \(previous.isEmpty ? "(none yet)" : previous)

        New messages to fold in:
        \(transcript)

        Write the updated summary.
        """
        // Summaries always run on-device when possible: cheap, private, and fast.
        let tier: ModelTier = models.onDeviceUnavailableReason() == nil ? .onDevice : .privateCloud
        do {
            let session = models.makeSession(tier: tier, tools: [], instructions: Self.summarizerInstructions)
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 260)
            )
            return TextUtil.truncate(response.content.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.summaryCharLimit)
        } catch {
            // Never lose the ability to make progress: fall back to a mechanical digest.
            let digest = transcript.split(separator: "\n").suffix(6).map { TextUtil.truncate(String($0), to: 120) }.joined(separator: " ")
            return TextUtil.truncate([previous, digest].filter { !$0.isEmpty }.joined(separator: " "), to: Self.summaryCharLimit)
        }
    }
}
