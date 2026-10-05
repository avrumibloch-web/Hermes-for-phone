import Foundation
import FoundationModels

/// Hermes' `memory` tool: add / replace / remove entries in MEMORY.md or USER.md.
/// There is no read action; memory is already in the system prompt.
struct MemoryTool: Tool {
    let name = "memory"
    let description = """
    Save durable facts for future sessions. target "user": who the user is and their \
    preferences. target "memory": facts about their devices, services and setup. add needs \
    content; replace needs oldText (a unique snippet of the entry) and the full new content; \
    remove needs oldText.
    """
    let context: ToolContext

    @Generable
    enum Action {
        case add
        case replace
        case remove
    }

    @Generable
    enum Target {
        case user
        case memory
    }

    @Generable
    struct Arguments {
        @Guide(description: "add, replace or remove")
        var action: Action
        @Guide(description: "user or memory")
        var target: Target
        @Guide(description: "The complete entry text, one declarative fact, under 200 characters")
        var content: String?
        @Guide(description: "A short unique snippet of the existing entry to replace or remove")
        var oldText: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let target: MemoryStore.Target = arguments.target == .user ? .user : .memory
        let result: MemoryStore.Result
        switch arguments.action {
        case .add:
            result = await context.memory.add(target, content: arguments.content ?? "")
        case .replace:
            result = await context.memory.replace(target, oldText: arguments.oldText ?? "", content: arguments.content ?? "")
        case .remove:
            result = await context.memory.remove(target, oldText: arguments.oldText ?? "")
        }
        await context.log(name, "\(arguments.action) \(target.rawValue): \(result.success ? "ok" : "failed")")
        return result.message
    }
}
