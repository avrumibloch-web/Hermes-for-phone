import Foundation
import SQLite3

/// Every conversation (app chat, Siri, scheduled job) is stored in SQLite with an FTS5
/// index over message text, the same design as Hermes' `state.db`. `session_search`
/// queries it so the agent can recall things that never made it into MEMORY.md.
public actor SessionStore {
    public enum Source: String, Sendable, Codable {
        case app, siri, cron, review, subagent
    }

    public struct Message: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let sessionID: String
        public let role: String        // "user" | "assistant" | "tool"
        public let content: String
        public let createdAt: Date
    }

    public struct SessionInfo: Sendable, Hashable, Identifiable {
        public let id: String
        public let source: Source
        public let title: String?
        public let startedAt: Date
        public let updatedAt: Date
        public let summary: String?
        public let compactedThrough: Int64
        public let needsReview: Bool
    }

    public struct Hit: Sendable, Hashable {
        public let messageID: Int64
        public let sessionID: String
        public let role: String
        public let snippet: String
        public let createdAt: Date
    }

    private var db: OpaquePointer?
    private var hasFTS = false

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        var fts = false
        do {
            try Self.migrate(handle!, hasFTS: &fts)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = handle
        hasFTS = fts
    }

    deinit {
        sqlite3_close(db)
    }

    public enum StoreError: Error, LocalizedError {
        case sqlite(String)
        public var errorDescription: String? {
            if case .sqlite(let m) = self { return "SQLite: \(m)" }
            return nil
        }
    }

    private static func migrate(_ db: OpaquePointer, hasFTS: inout Bool) throws {
        try exec(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            title TEXT,
            started_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            summary TEXT,
            compacted_through INTEGER NOT NULL DEFAULT 0,
            needs_review INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_by_session ON messages(session_id, id);
        """)
        // FTS5 ships in Apple's SQLite; fall back to LIKE search if it is ever missing.
        do {
            try exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                content, content='messages', content_rowid='id', tokenize='unicode61'
            );
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content) VALUES ('delete', old.id, old.content);
            END;
            """)
            hasFTS = true
        } catch {
            hasFTS = false
        }
    }

    // MARK: Sessions

    public func createSession(id: String = UUID().uuidString, source: Source, title: String? = nil) throws -> String {
        let now = Date().timeIntervalSince1970
        try run("INSERT INTO sessions(id, source, title, started_at, updated_at) VALUES (?,?,?,?,?)",
                .text(id), .text(source.rawValue), title.map(Bind.text) ?? .null, .real(now), .real(now))
        return id
    }

    public func session(_ id: String) throws -> SessionInfo? {
        try query("SELECT id, source, title, started_at, updated_at, summary, compacted_through, needs_review FROM sessions WHERE id = ?",
                  .text(id), map: Self.sessionRow).first
    }

    public func recentSessions(limit: Int = 30, source: Source? = nil) throws -> [SessionInfo] {
        let base = "SELECT id, source, title, started_at, updated_at, summary, compacted_through, needs_review FROM sessions"
        if let source {
            return try query(base + " WHERE source = ? ORDER BY updated_at DESC LIMIT ?", .text(source.rawValue), .int(Int64(limit)), map: Self.sessionRow)
        }
        return try query(base + " ORDER BY updated_at DESC LIMIT ?", .int(Int64(limit)), map: Self.sessionRow)
    }

    public func setTitle(_ id: String, _ title: String) throws {
        try run("UPDATE sessions SET title = ? WHERE id = ?", .text(title), .text(id))
    }

    /// Stores the rolling compression summary and how far into the log it reaches.
    public func setSummary(_ id: String, summary: String, compactedThrough: Int64) throws {
        try run("UPDATE sessions SET summary = ?, compacted_through = ? WHERE id = ?",
                .text(summary), .int(compactedThrough), .text(id))
    }

    public func setNeedsReview(_ id: String, _ flag: Bool) throws {
        try run("UPDATE sessions SET needs_review = ? WHERE id = ?", .int(flag ? 1 : 0), .text(id))
    }

    public func sessionsNeedingReview(limit: Int = 3) throws -> [SessionInfo] {
        try query("SELECT id, source, title, started_at, updated_at, summary, compacted_through, needs_review FROM sessions WHERE needs_review = 1 ORDER BY updated_at LIMIT ?",
                  .int(Int64(limit)), map: Self.sessionRow)
    }

    public func deleteSession(_ id: String) throws {
        try run("DELETE FROM messages WHERE session_id = ?", .text(id))
        try run("DELETE FROM sessions WHERE id = ?", .text(id))
    }

    // MARK: Messages

    @discardableResult
    public func append(_ sessionID: String, role: String, content: String) throws -> Int64 {
        let now = Date().timeIntervalSince1970
        try run("INSERT INTO messages(session_id, role, content, created_at) VALUES (?,?,?,?)",
                .text(sessionID), .text(role), .text(content), .real(now))
        let id = sqlite3_last_insert_rowid(db)
        try run("UPDATE sessions SET updated_at = ? WHERE id = ?", .real(now), .text(sessionID))
        return id
    }

    public func messages(_ sessionID: String, after id: Int64 = 0, limit: Int = 500) throws -> [Message] {
        try query("SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? AND id > ? ORDER BY id LIMIT ?",
                  .text(sessionID), .int(id), .int(Int64(limit)), map: Self.messageRow)
    }

    /// Scroll: messages around `messageID` within its session.
    public func around(messageID: Int64, radius: Int = 4) throws -> [Message] {
        guard let sid = try query("SELECT session_id FROM messages WHERE id = ?", .int(messageID), map: { Self.text($0, 0) }).first else {
            return []
        }
        let before = try query("SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? AND id <= ? ORDER BY id DESC LIMIT ?",
                               .text(sid), .int(messageID), .int(Int64(radius + 1)), map: Self.messageRow)
        let after = try query("SELECT id, session_id, role, content, created_at FROM messages WHERE session_id = ? AND id > ? ORDER BY id LIMIT ?",
                              .text(sid), .int(messageID), .int(Int64(radius)), map: Self.messageRow)
        return before.reversed() + after
    }

    // MARK: Search

    public func search(_ raw: String, limit: Int = 6, excludingSession: String? = nil) throws -> [Hit] {
        let terms = Self.searchTerms(raw)
        guard !terms.isEmpty else { return [] }
        let exclude = excludingSession ?? ""
        if hasFTS {
            let sql = """
            SELECT m.id, m.session_id, m.role, snippet(messages_fts, 0, '[', ']', '…', 14), m.created_at
            FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ? AND m.session_id != ? AND m.role != 'tool'
            ORDER BY rank LIMIT ?
            """
            // All terms first; if nothing matches, any term.
            let all = terms.map { "\"\($0)\"" }.joined(separator: " ")
            var hits = try query(sql, .text(all), .text(exclude), .int(Int64(limit)), map: Self.hitRow)
            if hits.isEmpty, terms.count > 1 {
                let any = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
                hits = try query(sql, .text(any), .text(exclude), .int(Int64(limit)), map: Self.hitRow)
            }
            return hits
        }
        let like = "%" + terms.joined(separator: "%") + "%"
        return try query("""
            SELECT id, session_id, role, substr(content, 1, 160), created_at FROM messages
            WHERE content LIKE ? AND session_id != ? AND role != 'tool' ORDER BY id DESC LIMIT ?
            """, .text(like), .text(exclude), .int(Int64(limit)), map: Self.hitRow)
    }

    static func searchTerms(_ raw: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "we", "i", "you", "did", "do", "about", "what", "that", "is", "was"]
        return raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
            .prefix(8)
            .map { $0 }
    }

    // MARK: SQLite plumbing

    enum Bind {
        case text(String), int(Int64), real(Double), null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: Bind...) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ binds: Bind..., map: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { rows.append(map(stmt)); continue }
            if rc == SQLITE_DONE { break }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func optionalText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : text(stmt, col)
    }

    private static func date(_ stmt: OpaquePointer, _ col: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, col))
    }

    private static func sessionRow(_ s: OpaquePointer) -> SessionInfo {
        SessionInfo(
            id: text(s, 0),
            source: Source(rawValue: text(s, 1)) ?? .app,
            title: optionalText(s, 2),
            startedAt: date(s, 3),
            updatedAt: date(s, 4),
            summary: optionalText(s, 5),
            compactedThrough: sqlite3_column_int64(s, 6),
            needsReview: sqlite3_column_int64(s, 7) != 0
        )
    }

    private static func messageRow(_ s: OpaquePointer) -> Message {
        Message(id: sqlite3_column_int64(s, 0), sessionID: text(s, 1), role: text(s, 2), content: text(s, 3), createdAt: date(s, 4))
    }

    private static func hitRow(_ s: OpaquePointer) -> Hit {
        Hit(messageID: sqlite3_column_int64(s, 0), sessionID: text(s, 1), role: text(s, 2), snippet: text(s, 3), createdAt: date(s, 4))
    }
}
