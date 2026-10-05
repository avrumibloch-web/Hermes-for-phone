import Foundation

/// On-disk layout. Mirrors Hermes Agent's `~/.hermes/` home, rooted in the app's
/// Application Support container instead of the user's home directory.
///
///     Hermes/
///       SOUL.md               personality / identity (editable)
///       memories/MEMORY.md    agent notes      (§-separated entries)
///       memories/USER.md      user profile     (§-separated entries)
///       skills/<name>/SKILL.md (+ references/)
///       cron/jobs.json
///       state.db              sessions + messages + FTS5 index
public struct HermesPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var memories: URL { root.appendingPathComponent("memories", isDirectory: true) }
    public var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    public var cronDirectory: URL { root.appendingPathComponent("cron", isDirectory: true) }
    public var cronJobs: URL { cronDirectory.appendingPathComponent("jobs.json") }
    public var stateDB: URL { root.appendingPathComponent("state.db") }
    public var soul: URL { root.appendingPathComponent("SOUL.md") }
    public var noBundledSkillsMarker: URL { root.appendingPathComponent(".no-bundled-skills") }

    public static func defaultHome() throws -> HermesPaths {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return HermesPaths(root: base.appendingPathComponent("Hermes", isDirectory: true))
    }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, memories, skills, cronDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: soul.path) {
            try Self.bundledSoul().write(to: soul, atomically: true, encoding: .utf8)
        }
    }

    static func bundledSoul() -> String {
        if let url = Bundle.module.url(forResource: "SOUL", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return PromptBuilder.defaultIdentity
    }
}
