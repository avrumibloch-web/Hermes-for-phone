import Foundation
import FoundationModels

/// Hermes' delegation: hand a focused subtask to a subagent with its own fresh context.
/// On the phone this matters more than in Hermes: an 8K context fills fast, and a subagent
/// can read a long page or several tool results and return only a short answer.
/// Subagents run one at a time (one model, one Neural Engine) and cannot delegate further.
struct DelegateTaskTool: Tool {
    let name = "delegate_task"
    let description = "Give a self-contained subtask to a helper with a fresh memory; it returns a short result. Include every detail it needs in context."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "What the helper must accomplish")
        var goal: String
        @Guide(description: "All facts, URLs or constraints the helper needs")
        var details: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let delegate = context.delegate else { return "Error: delegation is unavailable here." }
        await context.log(name, arguments.goal)
        let answer = try await delegate(arguments.goal, arguments.details)
        return TextUtil.truncate(answer, to: 1_500)
    }
}
