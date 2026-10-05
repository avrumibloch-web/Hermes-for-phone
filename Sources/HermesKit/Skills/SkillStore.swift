import Foundation

/// Hermes skills: on-demand procedure documents in the agentskills.io `SKILL.md` format,
/// loaded with progressive disclosure so they cost nothing until needed.
///
///     Level 0  skills index in the system prompt   (name + short description)
///     Level 1  skill_view(name)                    (full SKILL.md body)
///     Level 2  skill_view(name, path)              (one file under references/)
///
/// The agent writes its own skills with `skill_manage` — that is its procedural memory.
public actor SkillStore {
    public struct Summary: Sendable, Hashable, Codable {
        public let name: String
        public let description: String
        public let category: String?
        public let directory: URL
    }

    public struct Frontmatter: Sendable, Equatable {
        public var name: String?
        public var description: String?
        public var version: String?
        public var category: String?
        public var tags: [String] = []
        public var platforms: [String] = []
    }

    static let maxDescription = 80
    static let maxBody = 20_000

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: Discovery

    public func list() -> [Summary] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [String: Summary] = [:]
        for case let url as URL in walker where url.lastPathComponent == "SKILL.md" {
            // Don't descend into references/ looking for nested skills.
            if url.pathComponents.contains("references") { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (meta, _) = Self.split(raw)
            if !meta.platforms.isEmpty, !meta.platforms.contains(where: { ["ios", "iphone", "apple"].contains($0.lowercased()) }) {
                continue
            }
            let dir = url.deletingLastPathComponent()
            let name = meta.name ?? dir.lastPathComponent
            guard found[name] == nil else { continue }
            found[name] = Summary(
                name: name,
                description: meta.description ?? "",
                category: meta.category,
                directory: dir
            )
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Level 0: compact index for the system prompt, capped to `maxChars`.
    public func index(maxChars: Int) -> String {
        var lines: [String] = []
        var used = 0
        let all = list()
        for (i, skill) in all.enumerated() {
            let line = "- \(skill.name): \(skill.description)"
            if used + line.count + 1 > maxChars {
                lines.append("- …and \(all.count - i) more (call skills_list)")
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    public func find(_ name: String) -> Summary? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return list().first { $0.name.lowercased() == key }
    }

    /// Levels 1 and 2.
    public func view(_ name: String, path: String? = nil, maxChars: Int) -> String {
        guard let skill = find(name) else {
            let names = list().map(\.name).joined(separator: ", ")
            return "Error: no skill named \"\(name)\". Installed: \(names.isEmpty ? "none" : names)."
        }
        if let path, !path.isEmpty {
            guard let url = safeURL(path, in: skill.directory) else { return "Error: invalid path." }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "Error: \(path) not found in \(skill.name). Files: \(referenceFiles(skill).joined(separator: ", "))"
            }
            return TextUtil.truncate(text, to: maxChars)
        }
        let url = skill.directory.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "Error: unreadable skill." }
        let (_, body) = Self.split(raw)
        var out = "# skill: \(skill.name)\n" + body
        let refs = referenceFiles(skill)
        if !refs.isEmpty {
            out += "\n\nReference files (skill_view with path): " + refs.joined(separator: ", ")
        }
        return TextUtil.truncate(out, to: maxChars)
    }

    /// Body only, for `/skill-name` preloading.
    public func body(of name: String) -> String? {
        guard let skill = find(name),
              let raw = try? String(contentsOf: skill.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        else { return nil }
        return Self.split(raw).body
    }

    private func referenceFiles(_ skill: Summary) -> [String] {
        let refs = skill.directory.appendingPathComponent("references", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: refs.path)) ?? []
        return files.sorted().map { "references/\($0)" }
    }

    // MARK: skill_manage

    public func create(name: String, description: String, body: String, category: String?) -> String {
        guard Self.isValidName(name) else {
            return "Error: name must be lowercase letters, digits and hyphens (max 64), e.g. \"morning-briefing\"."
        }
        if find(name) != nil { return "Error: skill \"\(name)\" exists. Use patch or edit." }
        let desc = TextUtil.collapseWhitespace(description)
        guard !desc.isEmpty, desc.count <= Self.maxDescription else {
            return "Error: description is required and must be ≤\(Self.maxDescription) characters."
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Error: content is required." }
        guard body.count <= Self.maxBody else { return "Error: content too long; move depth into references/." }
        if let threat = MemoryGuard.scan(body) { return "Error: blocked, \(threat)." }

        var dir = root
        if let category, Self.isValidName(category) { dir.appendPathComponent(category, isDirectory: true) }
        dir.appendPathComponent(name, isDirectory: true)
        let doc = Self.render(name: name, description: desc, category: category, body: body)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try doc.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        return "Created skill \"\(name)\"."
    }

    /// Targeted edit: replace one unique occurrence of `oldText` in SKILL.md.
    public func patch(name: String, oldText: String, newText: String) -> String {
        guard let skill = find(name) else { return "Error: no skill named \"\(name)\"." }
        let url = skill.directory.appendingPathComponent("SKILL.md")
        guard var raw = try? String(contentsOf: url, encoding: .utf8) else { return "Error: unreadable skill." }
        let count = raw.components(separatedBy: oldText).count - 1
        guard !oldText.isEmpty, count == 1 else {
            return count == 0 ? "Error: old_text not found in \(name)." : "Error: old_text matches \(count) places; be more specific."
        }
        if let threat = MemoryGuard.scan(newText) { return "Error: blocked, \(threat)." }
        raw = raw.replacingOccurrences(of: oldText, with: newText)
        return write(raw, to: url, ok: "Patched \(name).")
    }

    /// Full rewrite of the body, keeping the frontmatter (description optionally updated).
    public func edit(name: String, body: String, description: String?) -> String {
        guard let skill = find(name) else { return "Error: no skill named \"\(name)\"." }
        let url = skill.directory.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "Error: unreadable skill." }
        guard body.count <= Self.maxBody else { return "Error: content too long." }
        if let threat = MemoryGuard.scan(body) { return "Error: blocked, \(threat)." }
        let (meta, _) = Self.split(raw)
        let desc = description.map(TextUtil.collapseWhitespace) ?? meta.description ?? ""
        let doc = Self.render(name: skill.name, description: String(desc.prefix(Self.maxDescription)), category: meta.category, body: body)
        return write(doc, to: url, ok: "Rewrote \(name).")
    }

    public func writeFile(name: String, path: String, content: String) -> String {
        guard let skill = find(name) else { return "Error: no skill named \"\(name)\"." }
        guard path.hasPrefix("references/"), let url = safeURL(path, in: skill.directory) else {
            return "Error: path must be under references/, e.g. references/recipes.md"
        }
        if let threat = MemoryGuard.scan(content) { return "Error: blocked, \(threat)." }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return write(content, to: url, ok: "Wrote \(path) in \(name).")
    }

    public func removeFile(name: String, path: String) -> String {
        guard let skill = find(name) else { return "Error: no skill named \"\(name)\"." }
        guard path.hasPrefix("references/"), let url = safeURL(path, in: skill.directory) else { return "Error: invalid path." }
        do { try FileManager.default.removeItem(at: url) } catch { return "Error: \(error.localizedDescription)" }
        return "Removed \(path) from \(name)."
    }

    public func delete(name: String) -> String {
        guard let skill = find(name) else { return "Error: no skill named \"\(name)\"." }
        do { try FileManager.default.removeItem(at: skill.directory) } catch { return "Error: \(error.localizedDescription)" }
        return "Deleted skill \(name)."
    }

    // MARK: Bundled skills

    /// Copies the app's bundled skills into the skills directory on first run, unless the
    /// user opted out (Hermes' `.no-bundled-skills` marker). Existing skills are never
    /// overwritten.
    public func seedBundledSkills(from bundled: URL?, optOutMarker: URL) {
        let fm = FileManager.default
        guard let bundled, !fm.fileExists(atPath: optOutMarker.path) else { return }
        guard let items = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for item in items {
            let target = root.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: item, to: target)
            }
        }
    }

    // MARK: Parsing

    static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }

    /// Splits `---` YAML frontmatter from the markdown body. Understands the subset of
    /// YAML that SKILL.md files use (scalars, inline lists, `metadata.hermes.*`).
    static func split(_ raw: String) -> (Frontmatter, body: String) {
        var meta = Frontmatter()
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return (meta, text)
        }
        let yaml = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var body = String(text[end.upperBound...])
        if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) } else { body = "" }

        for line in yaml.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "name": meta.name = value
            case "description": meta.description = value
            case "version": meta.version = value
            case "category": meta.category = value
            case "tags": meta.tags = parseList(value)
            case "platforms": meta.platforms = parseList(value)
            default: break
            }
        }
        return (meta, body.trimmingCharacters(in: .newlines))
    }

    static func parseList(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    static func render(name: String, description: String, category: String?, body: String) -> String {
        var fm = "---\nname: \(name)\ndescription: \(description)\nversion: 1.0.0\n"
        fm += "platforms: [ios]\nmetadata:\n  hermes:\n    author: agent\n"
        if let category, !category.isEmpty { fm += "    category: \(category)\n" }
        return fm + "---\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func safeURL(_ relative: String, in dir: URL) -> URL? {
        guard !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        return dir.appendingPathComponent(relative)
    }

    private func write(_ text: String, to url: URL, ok: String) -> String {
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return "Error: \(error.localizedDescription)" }
        return ok
    }
}
