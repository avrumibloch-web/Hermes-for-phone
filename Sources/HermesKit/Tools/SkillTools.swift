import Foundation
import FoundationModels

struct SkillsListTool: Tool {
    let name = "skills_list"
    let description = "List every saved skill (procedure) with its description."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Optional word to filter skills by name or description")
        var filter: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var all = await context.skills.list()
        if let f = arguments.filter?.lowercased(), !f.isEmpty {
            all = all.filter { $0.name.contains(f) || $0.description.lowercased().contains(f) }
        }
        await context.log(name, "\(all.count) skills")
        guard !all.isEmpty else { return "No skills saved yet." }
        return all.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }
}

struct SkillViewTool: Tool {
    let name = "skill_view"
    let description = "Load a saved skill's instructions by name before doing that kind of task. Optional path loads one of its reference files."
    let context: ToolContext

    @Generable
    struct Arguments {
        @Guide(description: "Skill name, e.g. morning-briefing")
        var name: String
        @Guide(description: "Optional reference file, e.g. references/notes.md")
        var path: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await context.log(name, arguments.name + (arguments.path.map { "/" + $0 } ?? ""))
        return await context.skills.view(arguments.name, path: arguments.path, maxChars: context.settings.skillViewCharLimit)
    }
}

/// Hermes' `skill_manage`: the agent's procedural memory.
struct SkillManageTool: Tool {
    let name = "skill_manage"
    let description = """
    Create or update a saved skill: a reusable procedure for a class of task (steps in order, \
    tools to call, the user's preferences, pitfalls). create needs name, summary (≤80 chars) \
    and content (markdown). patch replaces oldText with content. edit rewrites the whole body. \
    writeFile adds references/<file>. delete removes the skill.
    """
    let context: ToolContext

    @Generable
    enum Action {
        case create
        case patch
        case edit
        case writeFile
        case removeFile
        case delete
    }

    @Generable
    struct Arguments {
        var action: Action
        @Guide(description: "lowercase-hyphenated skill name")
        var name: String
        @Guide(description: "One-line summary, max 80 characters (create/edit)")
        var summary: String?
        @Guide(description: "Markdown body for create/edit, replacement text for patch, file text for writeFile")
        var content: String?
        @Guide(description: "Exact text to replace (patch only)")
        var oldText: String?
        @Guide(description: "references/<file>.md for writeFile/removeFile")
        var path: String?
        @Guide(description: "Optional category folder, e.g. home or productivity")
        var category: String?
    }

    func call(arguments a: Arguments) async throws -> String {
        let s = context.skills
        let result: String
        switch a.action {
        case .create:
            result = await s.create(name: a.name, description: a.summary ?? "", body: a.content ?? "", category: a.category)
        case .patch:
            result = await s.patch(name: a.name, oldText: a.oldText ?? "", newText: a.content ?? "")
        case .edit:
            result = await s.edit(name: a.name, body: a.content ?? "", description: a.summary)
        case .writeFile:
            result = await s.writeFile(name: a.name, path: a.path ?? "", content: a.content ?? "")
        case .removeFile:
            result = await s.removeFile(name: a.name, path: a.path ?? "")
        case .delete:
            result = await s.delete(name: a.name)
        }
        await context.log(name, "\(a.action) \(a.name): \(result.hasPrefix("Error") ? "failed" : "ok")")
        return result
    }
}
