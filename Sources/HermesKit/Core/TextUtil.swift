import Foundation

enum TextUtil {
    /// Truncates to `limit` characters, appending a marker the model can act on.
    static func truncate(_ text: String, to limit: Int, marker: String = "… [truncated]") -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - marker.count))) + marker
    }

    static func formatCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Crude HTML → text for web_fetch. Good enough for a small model to read.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return collapseWhitespace(s)
    }

    /// "2026-10-05 14:30" in the user's time zone — the one date format the tools accept.
    static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let localDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Accepts "yyyy-MM-dd HH:mm", "yyyy-MM-dd", ISO 8601, "today", "tomorrow".
    static func parseDate(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower == "today" || lower == "now" { return now }
        if lower == "tomorrow" { return calendar.date(byAdding: .day, value: 1, to: now) }
        if let d = localDateTime.date(from: s) { return d }
        if let d = localDate.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return iso.date(from: s)
    }
}

/// Thread-safe accumulator for things tools report back to the agent loop
/// (what ran, how many calls) without threading state through the framework.
public actor ToolActivityLog {
    public struct Entry: Sendable, Codable, Hashable {
        public let tool: String
        public let summary: String
    }

    private(set) var entries: [Entry] = []

    public init() {}

    func record(_ tool: String, _ summary: String) {
        entries.append(Entry(tool: tool, summary: TextUtil.truncate(summary, to: 160)))
    }

    func drain() -> [Entry] {
        defer { entries.removeAll() }
        return entries
    }
}
