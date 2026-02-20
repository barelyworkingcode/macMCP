import Foundation
import SQLite3

enum MessagesService {
    private static let dbPath: String = {
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

    // MARK: - Tool Handlers

    private static func listChats(_ args: JSONObject?) -> MCPCallResult {
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

    private static func getChat(_ args: JSONObject?) -> MCPCallResult {
        guard let chatId = args?["chat_id"]?.stringValue, !chatId.isEmpty else {
            return errorResult("chat_id is required")
        }
        let limit = args?["limit"]?.intValue ?? 50

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.text, m.is_from_me, m.date
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
            let text = columnText(stmt, 0)
            let isFromMe = sqlite3_column_int64(stmt, 1) == 1
            let appleTimestamp = sqlite3_column_int64(stmt, 2)

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

    private static func sendMessage(_ args: JSONObject?) -> MCPCallResult {
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
                name: "messages_send",
                description: "Send an iMessage to a phone number or email address",
                inputSchema: schema(
                    properties: [
                        "to": stringProp("Recipient phone number or email address"),
                        "text": stringProp("Message text to send")
                    ],
                    required: ["to", "text"]
                )
            ),
            category: cat,
            handler: sendMessage
        )
    }
}
