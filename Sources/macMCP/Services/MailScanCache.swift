import Foundation
import SQLite3

/// Tracks which messages a calling profile has already triaged (via
/// `mail_move_to_junk` or `mail_mark_reviewed`), so a batch run that asks for
/// "the next N unreviewed messages" does not keep re-serving ones already
/// looked at.
///
/// Keyed on the RFC Message-ID, never the numeric id -- the numeric id does
/// not survive a move, and a triaged message that gets filed to Junk is
/// exactly the case this exists to remember past. Scoped per
/// `_meta.project_id` (empty string for an unmediated caller) so two relay
/// profiles reading the same mailbox never see or influence each other's
/// triage progress.
///
/// Holds no message content: a row is an account, a Message-ID, a verdict, an
/// optional note and a timestamp. This is deliberate rather than an
/// oversight -- see the tool descriptions in `MailService.register` for why
/// Mail's own per-message state (flags, colours) was ruled out as the marker:
/// every one of them is a slot the human user also owns, is not durable
/// against the user touching it, and Mail syncs it to every device the
/// account is on.
enum MailScanCache {
    /// Not private: a test points this at a scratch file so the suite never
    /// touches -- or leaves behind state in -- the user's own cache.
    static var dbPath: String = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macmcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scan_cache.sqlite3").path
    }()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func withDB<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS reviewed (
            project_id TEXT NOT NULL,
            account TEXT NOT NULL,
            message_id TEXT NOT NULL,
            verdict TEXT NOT NULL,
            note TEXT,
            reviewed_at INTEGER NOT NULL,
            PRIMARY KEY (project_id, account, message_id)
        )
        """, nil, nil, nil)
        return body(db)
    }

    /// Account names fold the same way every other mail scope comparison
    /// does, so a cache entry written under one spelling is found under any
    /// canonically-equivalent one.
    private static func fold(_ account: String) -> String { MailScope.fold(account) }

    /// Records (or updates) a verdict. `messageID` is the RFC Message-ID with
    /// any angle brackets already stripped, as every other mail tool reports
    /// it.
    @discardableResult
    static func record(
        projectID: String,
        account: String,
        messageID: String,
        verdict: String,
        note: String?
    ) -> Bool {
        withDB { db in
            var stmt: OpaquePointer?
            let sql = """
            INSERT OR REPLACE INTO reviewed (project_id, account, message_id, verdict, note, reviewed_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, projectID, -1, transient)
            sqlite3_bind_text(stmt, 2, fold(account), -1, transient)
            sqlite3_bind_text(stmt, 3, messageID, -1, transient)
            sqlite3_bind_text(stmt, 4, verdict, -1, transient)
            if let note { sqlite3_bind_text(stmt, 5, note, -1, transient) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    /// Of `messageIDs` in one account, which have NOT already been recorded.
    /// Order is not preserved -- callers apply their own limit after this.
    static func unreviewed(projectID: String, account: String, messageIDs: [String]) -> Set<String> {
        guard !messageIDs.isEmpty else { return [] }
        let already: Set<String> = withDB { db in
            var stmt: OpaquePointer?
            let sql = "SELECT message_id FROM reviewed WHERE project_id = ? AND account = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, projectID, -1, transient)
            sqlite3_bind_text(stmt, 2, fold(account), -1, transient)
            var found = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { found.insert(String(cString: c)) }
            }
            return found
        } ?? []
        return Set(messageIDs).subtracting(already)
    }

    /// Deletes matching rows, scoped to `projectID`, and returns how many were
    /// removed. Never crosses a project boundary: a caller can only ever
    /// clear its own triage history. At least one of `account`, `messageID`
    /// or `olderThanDays` must be given unless `all` is true -- a clear with
    /// no target and no explicit `all` is refused by the caller before this
    /// is reached, the same rule the rest of this file applies to a mutating
    /// call with nothing to bound it.
    static func clear(
        projectID: String,
        account: String?,
        messageID: String?,
        olderThanDays: Int?
    ) -> Int {
        withDB { db in
            var clauses = ["project_id = ?"]
            var binds = [projectID]
            if let account { clauses.append("account = ?"); binds.append(fold(account)) }
            if let messageID { clauses.append("message_id = ?"); binds.append(messageID) }
            if let olderThanDays {
                let cutoff = Int64(Date().addingTimeInterval(-Double(olderThanDays) * 86400).timeIntervalSince1970)
                clauses.append("reviewed_at < \(cutoff)")
            }
            let sql = "DELETE FROM reviewed WHERE " + clauses.joined(separator: " AND ")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            for (i, value) in binds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        } ?? 0
    }
}
