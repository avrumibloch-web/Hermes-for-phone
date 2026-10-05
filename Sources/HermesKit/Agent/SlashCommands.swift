import Foundation

/// Leading slash tokens, as in Hermes:
///   /think …          use the smart model (local MLX or Private Cloud Compute) for this message
///   /fast …           use Apple's on-device model for this message
///   /<skill> …        preload an installed skill (up to 3; stops at first non-skill token)
/// `/new` is handled by the UI (it starts a new session).
public struct SlashCommand: Sendable, Equatable {
    public var text: String
    /// true for /think, false for /fast.
    public var forceSmart: Bool?
    public var skills: [String]

    public static func parse(_ input: String, installedSkills: Set<String>) -> SlashCommand {
        var tokens = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = SlashCommand(text: "", forceSmart: nil, skills: [])
        while let first = tokens.first, first.hasPrefix("/"), first.count > 1 {
            let word = String(first.dropFirst()).lowercased()
            if word == "think" {
                result.forceSmart = true
            } else if word == "fast" {
                result.forceSmart = false
            } else if installedSkills.contains(word), result.skills.count < 3 {
                result.skills.append(word)
            } else {
                break
            }
            tokens.removeFirst()
        }
        result.text = tokens.joined(separator: " ")
        if result.text.isEmpty, let skill = result.skills.first {
            result.text = "Use the \(skill) skill. Ask me for anything you need."
        }
        return result
    }
}
