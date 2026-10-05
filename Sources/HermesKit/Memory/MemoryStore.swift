import Foundation

/// Hermes' bounded, curated memory: two §-delimited markdown files with hard character
/// budgets, managed by the agent through the `memory` tool (add / replace / remove).
///
/// Behaviour copied from Hermes Agent:
/// - entries are separated by a line containing only `§`
/// - the system prompt gets a *frozen snapshot* taken at session start; writes land on
///   disk immediately but only show up in the prompt next session
/// - a write that would exceed the budget fails with the current entries attached, so the
///   model consolidates in the same turn instead of silently losing entries
/// - replace/remove locate one entry by a unique substring (`old_text`); an exact
///   whole-entry match wins over substring matches
/// - exact duplicates are ignored; entries are scanned for prompt-injection patterns
public actor MemoryStore {
    public enum Target: String, Sendable, CaseIterable, Codable {
        case memory
        case user

        var fileName: String { self == .memory ? "MEMORY.md" : "USER.md" }
        var heading: String { self == .memory ? "MEMORY (your notes)" : "USER PROFILE (who the user is)" }
    }

    public struct Result: Sendable, Equatable {
        public let success: Bool
        public let message: String
    }

    static let delimiter = "\n§\n"

    private let directory: URL
    private var limits: [Target: Int]

    public init(directory: URL, memoryLimit: Int, userLimit: Int) {
        self.directory = directory
        self.limits = [.memory: memoryLimit, .user: userLimit]
    }

    public func setLimits(memory: Int, user: Int) {
        limits = [.memory: memory, .user: user]
    }

    // MARK: Reading

    public func entries(_ target: Target) -> [String] {
        let url = directory.appendingPathComponent(target.fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parse(raw)
    }

    static func parse(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces) == "§" })
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func serialize(_ entries: [String]) -> String {
        entries.joined(separator: delimiter) + (entries.isEmpty ? "" : "\n")
    }

    func usage(_ entries: [String]) -> Int {
        Self.serialize(entries).trimmingCharacters(in: .newlines).count
    }

    /// The block injected into the system prompt at session start.
    public func snapshot() -> String {
        Target.allCases.compactMap { target -> String? in
            let list = entries(target)
            guard !list.isEmpty else { return nil }
            let used = usage(list)
            let limit = limits[target] ?? 0
            let pct = limit > 0 ? Int((Double(used) / Double(limit) * 100).rounded()) : 0
            let header = "\(target.heading) [\(pct)% — \(TextUtil.formatCount(used))/\(TextUtil.formatCount(limit)) chars]"
            return header + "\n" + list.joined(separator: "\n§\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Writing

    public func add(_ target: Target, content raw: String) -> Result {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return fail("content is required for add.") }
        if let threat = MemoryGuard.scan(content) { return fail("Blocked: \(threat).") }

        var list = entries(target)
        if list.contains(content) {
            return Result(success: true, message: "Already saved; no duplicate added.")
        }
        list.append(content)
        return commit(list, to: target, verb: "Added")
    }

    public func replace(_ target: Target, oldText: String, content raw: String) -> Result {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return fail("content is required for replace (the full new entry).") }
        if let threat = MemoryGuard.scan(content) { return fail("Blocked: \(threat).") }

        var list = entries(target)
        switch locate(oldText, in: list) {
        case .failure(let message):
            return fail(message, entries: list)
        case .success(let index):
            list[index] = content
            return commit(list, to: target, verb: "Replaced")
        }
    }

    public func remove(_ target: Target, oldText: String) -> Result {
        var list = entries(target)
        switch locate(oldText, in: list) {
        case .failure(let message):
            return fail(message, entries: list)
        case .success(let index):
            list.remove(at: index)
            return commit(list, to: target, verb: "Removed")
        }
    }

    // MARK: Internals

    private enum Located { case success(Int), failure(String) }

    private func locate(_ needleRaw: String, in list: [String]) -> Located {
        let needle = needleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .failure("old_text is required to find the entry.") }
        if let exact = list.firstIndex(of: needle) { return .success(exact) }
        let hits = list.indices.filter { list[$0].range(of: needle, options: .caseInsensitive) != nil }
        switch hits.count {
        case 1: return .success(hits[0])
        case 0: return .failure("No entry contains \"\(needle)\".")
        default: return .failure("\"\(needle)\" matches \(hits.count) entries; use a more specific old_text.")
        }
    }

    private func commit(_ list: [String], to target: Target, verb: String) -> Result {
        let used = usage(list)
        let limit = limits[target] ?? 0
        if used > limit {
            let current = entries(target)
            return fail(
                "\(target.rawValue) would be \(TextUtil.formatCount(used))/\(TextUtil.formatCount(limit)) chars. "
                    + "Consolidate now: replace overlapping entries with shorter ones or remove stale ones, "
                    + "then retry, all in this turn.",
                entries: current
            )
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(target.fileName)
            try Self.serialize(list).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return fail("Could not write \(target.fileName): \(error.localizedDescription)")
        }
        return Result(success: true, message: "\(verb). \(target.rawValue) now \(TextUtil.formatCount(used))/\(TextUtil.formatCount(limit)) chars.")
    }

    private func fail(_ message: String, entries: [String]? = nil) -> Result {
        guard let entries, !entries.isEmpty else { return Result(success: false, message: "Error: " + message) }
        let listing = entries.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return Result(success: false, message: "Error: \(message)\nCurrent entries:\n\(listing)")
    }
}

/// Memory is injected into every future system prompt, so it is a prompt-injection
/// target. Same idea as Hermes' memory security scan, smaller pattern list.
enum MemoryGuard {
    static let patterns: [String] = [
        "ignore (all )?(previous|prior|above) instructions",
        "disregard (the )?(system|previous) (prompt|instructions)",
        "you are now",
        "new system prompt",
        "reveal (your|the) (system prompt|instructions)",
        "(send|post|upload|exfiltrate) .*(password|api key|token|secret)",
        "BEGIN (RSA|OPENSSH) PRIVATE KEY",
    ]

    static func scan(_ text: String) -> String? {
        let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{202E}"]
        if text.unicodeScalars.contains(where: { invisible.contains($0) }) {
            return "invisible Unicode characters"
        }
        for pattern in patterns where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return "looks like a prompt-injection or exfiltration pattern"
        }
        return nil
    }
}
