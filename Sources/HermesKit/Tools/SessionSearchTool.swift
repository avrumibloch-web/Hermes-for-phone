import Foundation
import FoundationModels

/// Hermes' `session_search`: full-text search over every past conversation, plus scrolling
/// around a hit. No LLM summarization; it returns the stored messages.
struct SessionSearchTool: Tool {
    let name = "session_search"
    let description = "Search past conversations by keywords. To read more around a result, call again with aroundMessage set to its msg number."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Keywords to search for")
        var query: String
        @Guide(description: "Optional msg number from an earlier result to show the surrounding messages")
        var aroundMessage: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        if let id = arguments.aroundMessage {
            let messages = try await context.sessions.around(messageID: Int64(id))
            await context.log(name, "scroll \(id)")
            guard !messages.isEmpty else { return "No message \(id)." }
            return messages.map {
                "[\(df.string(from: $0.createdAt))] \($0.role): \(TextUtil.truncate($0.content, to: 300))"
            }.joined(separator: "\n")
        }
        let hits = try await context.sessions.search(arguments.query, limit: 6, excludingSession: context.sessionID)
        await context.log(name, "\"\(arguments.query)\" → \(hits.count)")
        guard !hits.isEmpty else { return "No past messages match \"\(arguments.query)\"." }
        return hits.map {
            "msg \($0.messageID) [\(df.string(from: $0.createdAt))] \($0.role): \($0.snippet)"
        }.joined(separator: "\n")
    }
}
