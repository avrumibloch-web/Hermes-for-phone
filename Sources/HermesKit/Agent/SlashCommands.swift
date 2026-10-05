import Foundation

/// Leading slash tokens, as in Hermes:
///   /think …          use the Private Cloud Compute model for this message (if allowed)
///   /local …          force the on-device model
///   /<skill> …        preload an installed skill (up to 3; stops at first non-skill token)
/// `/new` is handled by the UI (it starts a new session).
public struct SlashCommand: Sendable, Equatable {
    public var text: String
    public var forceTier: ModelTier?
    public var skills: [String]

    public static func parse(_ input: String, installedSkills: Set<String>) -> SlashCommand {
        var tokens = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = SlashCommand(text: "", forceTier: nil, skills: [])
        while let first = tokens.first, first.hasPrefix("/"), first.count > 1 {
            let word = String(first.dropFirst()).lowercased()
            if word == "think" {
                result.forceTier = .privateCloud
            } else if word == "local" {
                result.forceTier = .onDevice
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
