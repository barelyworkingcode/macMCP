import AppKit
import Foundation
import SQLite3

enum MessagesService {
    /// Not private, and a `var`: the test suite points this at a chat.db it
    /// builds itself, because no test may read the user's own messages.
    static var dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Messages/chat.db"
    }()

    /// Seconds between Unix epoch (1970-01-01) and Apple reference date (2001-01-01).
    private static let appleEpochOffset: Double = 978307200

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        if rc != SQLITE_OK {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return ""
    }

    /// Extract plain text from the attributedBody blob in chat.db.
    /// The blob uses NSArchiver's typedstream format containing an NSAttributedString.
    private static func extractText(fromAttributedBody data: Data) -> String? {
        if let attrStr = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
            let text = attrStr.string
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Tool Handlers

    private static func listChats(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let limit = args?["limit"]?.intValue ?? 20

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.service_name
            FROM chat c ORDER BY c.ROWID DESC LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return errorResult("failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var chats: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let identifier = columnText(stmt, 1)
            let displayName = columnText(stmt, 2)
            let serviceName = columnText(stmt, 3)

            var chat: [String: Any] = [
                "rowid": Int(rowid),
                "chat_identifier": identifier,
                "service_name": serviceName,
            ]
            if !displayName.isEmpty {
                chat["display_name"] = displayName
            }
            chats.append(chat)
        }

        return jsonResult(chats)
    }

    private static func getChat(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let chatId = args?["chat_id"]?.stringValue, !chatId.isEmpty else {
            return errorResult("chat_id is required")
        }
        let limit = args?["limit"]?.intValue ?? 50

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.text, m.is_from_me, m.date, m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE c.chat_identifier = ?
            ORDER BY m.date DESC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return errorResult("failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, chatId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var messages: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var text = columnText(stmt, 0)
            let isFromMe = sqlite3_column_int64(stmt, 1) == 1
            let appleTimestamp = sqlite3_column_int64(stmt, 2)

            // Fall back to attributedBody when text column is empty
            if text.isEmpty,
               let blobPtr = sqlite3_column_blob(stmt, 3) {
                let blobSize = Int(sqlite3_column_bytes(stmt, 3))
                if blobSize > 0 {
                    let data = Data(bytes: blobPtr, count: blobSize)
                    text = extractText(fromAttributedBody: data) ?? ""
                }
            }

            // Apple timestamps in chat.db are in nanoseconds since 2001-01-01
            let unixSeconds = Double(appleTimestamp) / 1_000_000_000.0 + appleEpochOffset
            let date = Date(timeIntervalSince1970: unixSeconds)
            let dateStr = iso8601.string(from: date)

            let msg: [String: Any] = [
                "text": text,
                "is_from_me": isFromMe,
                "date": dateStr,
            ]
            messages.append(msg)
        }

        return jsonResult(messages)
    }

    // MARK: - Search

    /// A handle as it can be compared.
    ///
    /// Messages stores the same person under several renderings -- `+15551234567`,
    /// `(555) 123-4567`, `555-1234` -- and `h.id = ?` matches exactly one of them,
    /// so a caller who passes the number the way their address book shows it gets
    /// an empty result rather than the conversation. Emails are compared
    /// lowercased; a number is compared on its digits, and on the last ten of
    /// them when it has more, which is what makes a national number and the same
    /// number written with a country code the same handle. Ten because that is
    /// the longest suffix that cannot collide across the plans this runs on; a
    /// shorter number is compared whole.
    static func normalizedHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.contains("@") else { return trimmed }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// The `handle.ROWID`s that are this contact, however either side spells it.
    ///
    /// The whole table is read and compared here rather than matched in SQL,
    /// because the comparison is not one SQLite can express: it is a
    /// normalisation on both sides. The table is one row per person per service.
    private static func handleRowIDs(matching contact: String, db: OpaquePointer) -> [Int64] {
        let want = normalizedHandle(contact)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, id FROM handle", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if normalizedHandle(columnText(stmt, 1)) == want {
                out.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return out
    }

    /// How many rows a search reads before it stops, whatever `limit` is.
    ///
    /// A text query cannot be pushed into SQL: a message's text lives in
    /// `m.text` *or* in the `attributedBody` archive, and only the second is
    /// readable after decoding it here (every message sent by a recent Messages
    /// build is in the second). So `LIMIT` cannot do the matching -- it would
    /// cut the candidates before anything had been read -- and the rows are read
    /// newest-first and filtered in Swift instead. This bounds that work.
    static let searchScanLimit = 5000

    private static func extractDouble(_ args: JSONObject?, key: String) -> Double? {
        guard let value = args?[key] else { return nil }
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    /// `since`, which is an ISO 8601 date and may or may not carry a time.
    ///
    /// `ISO8601DateFormatter` with `.withInternetDateTime` rejects `2026-03-15`
    /// outright, and a caller writing a date without a time is the likely case
    /// for a tool whose other knob is measured in hours.
    static func parseSince(_ raw: String) -> Date? {
        if let full = iso8601.date(from: raw) { return full }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: raw)
    }

    private static func searchMessages(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let limit = max(args?["limit"]?.intValue ?? 100, 0)
        let query = args?["query"]?.stringValue?.lowercased()

        let cutoff: Date
        if let since = args?["since"]?.stringValue, !since.isEmpty {
            guard let parsed = parseSince(since) else {
                return errorResult("could not read 'since' as an ISO 8601 date: \(since)")
            }
            cutoff = parsed
        } else {
            cutoff = Date(timeIntervalSinceNow: -(extractDouble(args, key: "hours_ago") ?? 24) * 3600)
        }
        // chat.db stores dates as nanoseconds since the Apple epoch.
        let cutoffNanos = Int64((cutoff.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)

        guard let db = openDB() else {
            return errorResult("failed to open the Messages database at \(dbPath) — reading it needs Full Disk Access")
        }
        defer { sqlite3_close(db) }

        var handleIDs: [Int64] = []
        if let contact = args?["contact"]?.stringValue, !contact.isEmpty {
            handleIDs = handleRowIDs(matching: contact, db: db)
            if handleIDs.isEmpty {
                return jsonResult([
                    "messages": [],
                    "messages_scanned": 0,
                    "scan_complete": true,
                    "note": "no chat handle matches \(contact), so no conversation could be searched. Handles are phone numbers and email addresses as Messages stores them; messages_list_chats shows the ones on this Mac."
                ])
            }
        }

        // The whole conversation, not only what the other side said: a caller
        // asking about a contact wants their own replies in the thread too, so
        // the filter is on the chats that contact is in rather than on each
        // message's own handle (which is 0 for anything sent from here).
        var sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, m.date,
                   h.id AS sender_id,
                   c.chat_identifier, c.display_name, c.service_name
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.date > ?1
            """
        if !handleIDs.isEmpty {
            let list = handleIDs.map(String.init).joined(separator: ",")
            sql += """
                \n  AND cmj.chat_id IN (
                        SELECT chj.chat_id FROM chat_handle_join chj WHERE chj.handle_id IN (\(list))
                    )
                """
        }
        sql += "\nORDER BY m.date DESC LIMIT ?2"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return errorResult("failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        // Read up to the scan cap and filter here, rather than asking SQLite for
        // `limit` rows: with a query, `limit` counts *matches*, and a row cannot
        // be known to match until its body has been decoded.
        let scanCap = query == nil ? limit : searchScanLimit
        sqlite3_bind_int64(stmt, 1, cutoffNanos)
        sqlite3_bind_int(stmt, 2, Int32(scanCap))

        var messages: [[String: Any]] = []
        var scanned = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            scanned += 1
            var text = columnText(stmt, 0)
            if text.isEmpty, let blob = sqlite3_column_blob(stmt, 1) {
                let size = Int(sqlite3_column_bytes(stmt, 1))
                if size > 0 {
                    text = extractText(fromAttributedBody: Data(bytes: blob, count: size)) ?? ""
                }
            }
            // A row with no text at all is an attachment, a tapback or a
            // deleted message; there is nothing to search or to show.
            if text.isEmpty { continue }
            if let query, !text.lowercased().contains(query) { continue }

            let isFromMe = sqlite3_column_int64(stmt, 2) == 1
            let senderID = columnText(stmt, 4)
            let displayName = columnText(stmt, 6)
            let unix = Double(sqlite3_column_int64(stmt, 3)) / 1_000_000_000.0 + appleEpochOffset

            var message: [String: Any] = [
                "text": text,
                "is_from_me": isFromMe,
                "date": iso8601.string(from: Date(timeIntervalSince1970: unix)),
                "chat_identifier": columnText(stmt, 5),
                "service": columnText(stmt, 7)
            ]
            if !isFromMe, !senderID.isEmpty { message["sender"] = senderID }
            if !displayName.isEmpty { message["display_name"] = displayName }
            messages.append(message)
            if messages.count >= limit { break }
        }

        // What was read, and whether that was all of it. A search that stopped
        // at the cap has found the newest matches and not necessarily all of
        // them, and a caller cannot tell that from the rows alone.
        let hitCap = scanned >= scanCap && messages.count < limit
        var payload: [String: Any] = [
            "messages": messages,
            "messages_scanned": scanned,
            "scan_complete": !hitCap
        ]
        if hitCap {
            payload["note"] = "stopped after reading \(scanned) messages, so these are the newest matches rather than all of them. Narrow the window with hours_ago or since, or name a contact."
        }
        return jsonResult(payload)
    }

    private static func sendMessage(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let to = args?["to"]?.stringValue, !to.isEmpty else {
            return errorResult("to is required")
        }
        guard let text = args?["text"]?.stringValue, !text.isEmpty else {
            return errorResult("text is required")
        }

        // Escape double quotes and backslashes for AppleScript string literals
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTo = to
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Messages"
                set targetService to first service whose service type = iMessage
                set targetBuddy to buddy "\(escapedTo)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return errorResult("failed to run osascript: \(error.localizedDescription)")
        }

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return errorResult("osascript failed: \(output)")
        }

        return textResult("message sent to \(to)")
    }

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Messages"

        registry.register(
            MCPTool(
                name: "messages_list_chats",
                description: "List recent chat conversations from Messages.app",
                inputSchema: schema(
                    properties: [
                        "limit": intProp("Maximum number of chats to return (default 20)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listChats
        )

        registry.register(
            MCPTool(
                name: "messages_get_chat",
                description: "Get messages from a specific chat conversation",
                inputSchema: schema(
                    properties: [
                        "chat_id": stringProp("The chat_identifier to retrieve messages from"),
                        "limit": intProp("Maximum number of messages to return (default 50)")
                    ],
                    required: ["chat_id"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: getChat
        )

        registry.register(
            MCPTool(
                name: "messages_search",
                description: "Search messages across every chat, by text and/or by who they are with. Requires Full Disk Access. Returns the newest matches first, with messages_scanned and scan_complete saying how much of the window was read.",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Text to look for, matched case-insensitively anywhere in a message. Omit to get every message in the window."),
                        "contact": stringProp("Phone number or email to limit the search to conversations with this person. Any formatting: +1 (555) 123-4567 and 5551234567 are the same handle. The whole thread is searched, including messages sent from this Mac."),
                        "hours_ago": numberProp("How far back to search, in hours (default 24). Ignored when 'since' is given."),
                        "since": stringProp("Search from this ISO 8601 date, with or without a time (2026-03-15 or 2026-03-15T09:00:00Z). Overrides hours_ago."),
                        "limit": intProp("Maximum number of matching messages to return (default 100)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: searchMessages
        )

        registry.register(
            MCPTool(
                name: "messages_send",
                description: "Send an iMessage to a phone number or email address",
                inputSchema: schema(
                    properties: [
                        "to": stringProp("Recipient phone number or email address"),
                        "text": stringProp("Message text to send")
                    ],
                    required: ["to", "text"]
                ),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: sendMessage
        )
    }
}
