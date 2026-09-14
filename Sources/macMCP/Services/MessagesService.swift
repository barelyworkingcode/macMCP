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

    /// Seconds between Unix epoch (1970-01-01) and Apple reference date
    /// (2001-01-01). chat.db stores every date as nanoseconds since the
    /// latter.
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

    /// A caller-supplied `limit`, read as leniently as `extractDouble` reads
    /// `hours_ago` (a model writing `"50"` or `50.0` is as validly JSON as
    /// `50`, and `JSONValue.intValue` matched `.int` alone), then bound for
    /// `sqlite3_bind_int`.
    ///
    /// `Int32(limit)` traps on anything outside Int32's range, which took the
    /// whole process down with it (verified: `limit: 99999999999` crashed
    /// macmcp, all 50 tools, not just Messages) -- and a value read as a
    /// `Double` first can be finite and still overflow `Int32`, or fail to
    /// convert at all if it is NaN or infinite, so the clamp has to happen
    /// before any conversion to `Int`, not after. Negative is floored at zero
    /// rather than passed through -- SQLite reads a negative LIMIT as "no
    /// limit", which would make a negative value a way to dump the whole
    /// table past the documented default.
    private static func boundedLimit(_ args: JSONObject?, key: String, default def: Int) -> Int32 {
        let raw: Double
        switch args?[key] {
        case .int(let i): raw = Double(i)
        case .double(let d): raw = d
        case .string(let s): raw = Double(s) ?? Double(def)
        default: raw = Double(def)
        }
        guard raw.isFinite else { return Int32(def) }
        if raw <= 0 { return 0 }
        return raw >= Double(Int32.max) ? Int32.max : Int32(raw)
    }

    /// The blob is NSArchiver's typedstream format, archiving an
    /// NSAttributedString -- not the newer keyed-archive format, which is why
    /// this reads it with `NSUnarchiver` rather than `NSKeyedUnarchiver`.
    private static func extractText(fromAttributedBody data: Data) -> String? {
        if let attrStr = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
            let text = attrStr.string
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Attachments (images only)

    /// The image attachments on one message, each an `attachment_id` a
    /// caller passes to `messages_save_attachment` plus what it is.
    ///
    /// Filtered to `mime_type` starting `image/`: this Mac's Messages tools
    /// handle images and nothing else, so a video, PDF, vCard or sticker
    /// stays exactly as invisible as it always has been rather than showing
    /// up as a kind of attachment nothing here can save. `filename` is the
    /// attachment's own file name, not the path it happens to sit at on this
    /// disk -- `messages_save_attachment` is the only place that path is
    /// used, and it is never a caller-visible value.
    private static func imageAttachments(forMessage messageID: Int64, db: OpaquePointer) -> [[String: Any]] {
        let sql = """
            SELECT a.ROWID, a.filename, a.mime_type
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            WHERE maj.message_id = ?1 AND a.mime_type LIKE 'image/%'
            ORDER BY a.ROWID
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, messageID)
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append([
                "attachment_id": Int(sqlite3_column_int64(stmt, 0)),
                "filename": (columnText(stmt, 1) as NSString).lastPathComponent,
                "mime_type": columnText(stmt, 2)
            ])
        }
        return out
    }

    /// The on-disk path and MIME type behind one `attachment_id`, for
    /// `messages_save_attachment`. `~` in `filename` is literal in chat.db (a
    /// received attachment is stored under `~/Library/Messages/Attachments/...`)
    /// and has to be expanded before the path can be opened.
    private static func attachmentFile(id: Int64, db: OpaquePointer) -> (path: String, mimeType: String)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT filename, mime_type FROM attachment WHERE ROWID = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let filename = columnText(stmt, 0)
        guard !filename.isEmpty else { return nil }
        return ((filename as NSString).expandingTildeInPath, columnText(stmt, 1))
    }

    // MARK: - Tool Handlers

    private static func listChats(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let limit = boundedLimit(args, key: "limit", default: 20)

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        // By last message, not by `c.ROWID`: the ROWID order is chat
        // *creation*, so a conversation that has run for years and a chat
        // created moments ago by an unrelated failed send sort the same way
        // creation always does -- oldest first by ROWID reversed, which puts
        // the newest-*created* chat on top regardless of when anyone last
        // said anything in it. The join also drops a chat with no messages
        // at all, which "recent conversations" should not list to begin with.
        let sql = """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.service_name
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID
            ORDER BY MAX(cmj.message_date) DESC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return errorResult("failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, limit)

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
        let limit = boundedLimit(args, key: "limit", default: 50)

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.text, m.is_from_me, m.date, m.attributedBody, m.error, m.ROWID
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
        sqlite3_bind_int(stmt, 2, limit)

        var messages: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var text = columnText(stmt, 0)
            let isFromMe = sqlite3_column_int64(stmt, 1) == 1
            let appleTimestamp = sqlite3_column_int64(stmt, 2)
            let sendError = sqlite3_column_int(stmt, 4)

            if text.isEmpty,
               let blobPtr = sqlite3_column_blob(stmt, 3) {
                let blobSize = Int(sqlite3_column_bytes(stmt, 3))
                if blobSize > 0 {
                    let data = Data(bytes: blobPtr, count: blobSize)
                    text = extractText(fromAttributedBody: data) ?? ""
                }
            }

            let unixSeconds = Double(appleTimestamp) / 1_000_000_000.0 + appleEpochOffset
            let date = Date(timeIntervalSince1970: unixSeconds)
            let dateStr = iso8601.string(from: date)

            var msg: [String: Any] = [
                "text": text,
                "is_from_me": isFromMe,
                "date": dateStr,
            ]
            // `is_sent`/`error` describe an outgoing message's own delivery,
            // not an incoming one; without this a message this Mac tried and
            // failed to send reads identically to one that went through --
            // `messages_send`'s own delivery check reads these same columns.
            if isFromMe, sendError != 0 { msg["send_error"] = Int(sendError) }
            let attachments = imageAttachments(forMessage: sqlite3_column_int64(stmt, 5), db: db)
            if !attachments.isEmpty { msg["attachments"] = attachments }
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
    ///
    /// It is the SQL `LIMIT` even with no `query`: an attachment, tapback or
    /// deleted message has no text and is dropped after being read (below),
    /// so a row read is not always a row returned. Binding `LIMIT` to `limit`
    /// itself used to mean a window with plenty of real messages past a run
    /// of attachments came back short, having spent its whole budget on rows
    /// that were never going to count.
    static let searchScanLimit = 5000

    /// `nil` for NaN and infinity, not just for a value the JSON couldn't
    /// carry as a number in the first place: `Double("inf")` and `Double("nan")`
    /// both succeed, and a caller-string is exactly how a JSON message reaches
    /// either, since JSON itself has no way to encode them as a number.
    /// Something downstream eventually converts this to an `Int` or `Int64`,
    /// which traps rather than saturating on either.
    private static func extractDouble(_ args: JSONObject?, key: String) -> Double? {
        guard let value = args?[key] else { return nil }
        let parsed: Double?
        switch value {
        case .double(let d): parsed = d
        case .int(let i): parsed = Double(i)
        case .string(let s): parsed = Double(s)
        default: parsed = nil
        }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }

    /// A `Date`, as chat.db's own unit: nanoseconds since the Apple epoch.
    ///
    /// Clamped to `Int64`'s range rather than merely finite: `hours_ago:
    /// 100000000000` (about 11 million years) is a finite `Double` that still
    /// overflows once multiplied out to nanoseconds, and `Int64(Double)`
    /// traps on overflow rather than saturating. A window that reaches back
    /// further than `chat.db` could ever hold rounds to "since the beginning",
    /// which is what the caller meant anyway.
    private static func appleEpochNanos(_ date: Date) -> Int64 {
        let nanos = (date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000
        if !nanos.isFinite { return nanos > 0 ? Int64.max : Int64.min }
        if nanos >= Double(Int64.max) { return Int64.max }
        if nanos <= Double(Int64.min) { return Int64.min }
        return Int64(nanos)
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
        let limit = Int(boundedLimit(args, key: "limit", default: 100))
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
        let cutoffNanos = appleEpochNanos(cutoff)

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
                   c.chat_identifier, c.display_name, c.service_name, m.error, m.ROWID
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

        let scanCap = searchScanLimit
        sqlite3_bind_int64(stmt, 1, cutoffNanos)
        sqlite3_bind_int(stmt, 2, Int32(clamping: scanCap))

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
            let attachments = imageAttachments(forMessage: sqlite3_column_int64(stmt, 9), db: db)
            // A row with no text and no image is a tapback, a non-image
            // attachment or a deleted message; there is nothing to search or
            // to show. One with an image and no text can still be browsed
            // (no `query`) but cannot match a text query -- there is no text
            // for it to match.
            if text.isEmpty, attachments.isEmpty { continue }
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
            // An outgoing message that failed reads identically to one that
            // went through unless this is surfaced -- `messages_send`'s own
            // delivery check reads this same column.
            let sendError = sqlite3_column_int(stmt, 8)
            if isFromMe, sendError != 0 { message["send_error"] = Int(sendError) }
            if !attachments.isEmpty { message["attachments"] = attachments }
            // Checked before appending, not after: a `limit` of zero must
            // return zero messages rather than the first match found.
            if messages.count >= limit { break }
            messages.append(message)
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

    /// What became of a message this call just handed to Messages.
    ///
    /// Messages' AppleScript dictionary has no delivery status at all --
    /// `send` declares no result, and nothing it does return carries
    /// `chat.db`'s own `is_sent`/`error` columns -- so an exit code of 0 from
    /// osascript only means the *request* didn't throw, not that Apple's
    /// servers accepted the message. `chat.db` is the one place that
    /// distinguishes the two, and macMCP already reads it read-only for every
    /// other Messages tool.
    private enum DeliveryOutcome {
        case sent
        case failed(code: Int32)
        case unconfirmed
        /// chat.db could not be opened on any attempt -- almost always a
        /// missing Full Disk Access grant. Kept apart from `.unconfirmed`
        /// because the two need different advice: "check messages_get_chat"
        /// is useless to a caller who has just learned that same permission
        /// is what is missing.
        case cannotVerify
    }

    /// Not private: `Tests/MessagesSendVerificationTests` pins this query
    /// against a fixture database, since `sendMessage` itself needs a real
    /// Messages.app and cannot run hermetically.
    ///
    /// Ordered by `m.ROWID DESC`, not `m.date`. `date` looked like the right
    /// column -- it is when chat.db timestamps a message -- but it is not
    /// stable across the two rows one `messages_send` call with both `text`
    /// and `image_path` creates: measured live, the text row's `date`
    /// advanced past the image row's once the text was confirmed sent,
    /// putting the *older*, already-confirmed row first under `ORDER BY
    /// date DESC` and making the still-pending image row invisible to a
    /// `LIMIT 1` check -- the call reported "message and image sent" while
    /// the image sat at `is_sent: 0` for over two minutes. `ROWID` is
    /// assigned once, at insertion, and never revised.
    static func newestOutgoingMessages(
        handleIDs: [Int64], sentAfter cutoffNanos: Int64, limit: Int, db: OpaquePointer
    ) -> [(isSent: Bool, error: Int32)] {
        guard !handleIDs.isEmpty else { return [] }
        let list = handleIDs.map(String.init).joined(separator: ",")
        let sql = """
            SELECT m.is_sent, m.error
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
            WHERE chj.handle_id IN (\(list))
              AND m.is_from_me = 1
              AND m.date >= ?1
            ORDER BY m.ROWID DESC
            LIMIT ?2
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffNanos)
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [(isSent: Bool, error: Int32)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0) == 1, sqlite3_column_int(stmt, 1)))
        }
        return out
    }

    /// Measured against this box's real Messages: a text message to a
    /// working recipient reaches `is_sent = 1` in under two seconds, while
    /// one sent to an address Apple's servers do not recognise sat at
    /// `is_sent = 0, error: 0` for a 20-second watch and only carried
    /// `error: 22` at around 22 seconds. An image is slower and less
    /// predictable still -- measured taking minutes, and surfacing different
    /// error codes (`25`, `1`) on otherwise-identical sends -- which this
    /// cannot paper over; it only reports what chat.db actually says. A
    /// bound long enough to always catch a failure is long enough to make
    /// every successful send pay for it too, so the default favours the
    /// fast common case and reports a slow one as unconfirmed rather than
    /// guessing; `timeoutSeconds` is how a caller asks to wait longer for
    /// the stronger answer.
    ///
    /// `expectedCount` is 2 when both `text` and `image_path` were sent --
    /// two rows land in chat.db, and *both* have to confirm sent for the
    /// call to report `.sent`; one failing reports `.failed` even if the
    /// other already succeeded, because "the image didn't go out" is not a
    /// success by any reading a caller would accept.
    private static func awaitDeliveryOutcome(
        to: String, sentAfter cutoffNanos: Int64, expectedCount: Int, timeoutSeconds: Double
    ) -> DeliveryOutcome {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var everOpenedDB = false
        repeat {
            // Re-resolved every iteration rather than once up front: a buddy
            // that did not exist in the `handle` table a moment ago (a
            // recipient this Mac has never messaged before) can appear in it
            // moments later, and resolving it only once would miss that.
            if let db = openDB() {
                everOpenedDB = true
                defer { sqlite3_close(db) }
                let handleIDs = handleRowIDs(matching: to, db: db)
                let rows = newestOutgoingMessages(
                    handleIDs: handleIDs, sentAfter: cutoffNanos, limit: expectedCount, db: db
                )
                if let failed = rows.first(where: { $0.error != 0 }) {
                    return .failed(code: failed.error)
                }
                if rows.count >= expectedCount, rows.allSatisfy(\.isSent) {
                    return .sent
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return everOpenedDB ? .unconfirmed : .cannotVerify
    }

    /// `true` if `process` finished on its own within `timeout`; `false` if it
    /// is still running and the caller must decide what to do about that.
    private static func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Whether `NSImage` can decode the file -- content, not the extension: a
    /// file named `photo.png` that is not actually a valid image must not
    /// reach `send`, which happily hands anything at all to Messages (see
    /// `image_path` not existing at all doing the same).
    private static func isImageFile(at path: String) -> Bool {
        NSImage(contentsOfFile: path) != nil
    }

    /// Messages.app is itself sandboxed and can only read files under a
    /// small set of its own directories -- not an arbitrary path a caller
    /// names. Verified on this box: a real, valid image at `/tmp/...` or
    /// `~/Desktop/...` is silently unreadable to it (`send` still exits 0,
    /// and chat.db later reports `error: 25` with nothing surfaced to
    /// osascript at the time), while the identical bytes staged under
    /// Messages' own `~/Library/Messages/` tree are not. Copying into
    /// `.send-staging` there -- a name of macMCP's own choosing, not
    /// Apple's -- turns "Messages cannot read the caller's file" into
    /// "Messages can read it", which is the most a client can fix: actual
    /// delivery past that point is Apple's servers and this Mac's network,
    /// and -- measured on this box -- can take minutes rather than the ~2s a
    /// text send confirms in, or fail with an error code that is not always
    /// the same one twice.
    ///
    /// Falls back to the original path on any failure (an unwritable
    /// staging directory, a copy that fails partway) rather than refusing to
    /// send -- worst case this reproduces the pre-staging behaviour rather
    /// than costing the caller the send outright.
    private static func stagedForSending(_ path: String) -> String {
        let stagingDir = ("~/Library/Messages/.send-staging" as NSString).expandingTildeInPath
        guard (try? FileManager.default.createDirectory(
            atPath: stagingDir, withIntermediateDirectories: true
        )) != nil else { return path }
        let staged = (stagingDir as NSString).appendingPathComponent(
            "\(UUID().uuidString)-\((path as NSString).lastPathComponent)"
        )
        guard (try? FileManager.default.copyItem(atPath: path, toPath: staged)) != nil else { return path }
        return staged
    }

    private static func sendMessage(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let to = args?["to"]?.stringValue, !to.isEmpty else {
            return errorResult("to is required")
        }
        let text = args?["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let imageArg = args?["image_path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard text != nil || imageArg != nil else {
            return errorResult("at least one of text or image_path is required")
        }
        let timeout = min(max(extractDouble(args, key: "timeout_seconds") ?? 8, 0), 60)

        // `image_path` is optional -- the tool sends a plain message without
        // one -- so it is not in `file_dirs`'s `applies_to` and is confined
        // here instead, exactly as `mail_send`'s `attachments` is. The scope
        // check and the existence/image checks run against the caller's own
        // path; staging (below) is a Messages-sandbox workaround applied
        // after, invisible to the caller and to the scope.
        var imagePath: String?
        var stagedImagePath: String?
        if let imageArg {
            let scope = ResourceScope.parse(ctx.meta)
            switch HostFileScope.resolve(imageArg, scope: scope, use: .read, what: "image") {
            case .use(let resolved): imagePath = resolved
            case .refuse(let message): return scopeViolationResult(message)
            case .error(let message): return errorResult(message)
            }
            guard FileManager.default.fileExists(atPath: imagePath!) else {
                return errorResult("image_path not found: \(imageArg)")
            }
            guard isImageFile(at: imagePath!) else {
                return errorResult("image_path is not a readable image file: \(imageArg)")
            }
            let staged = stagedForSending(imagePath!)
            if staged != imagePath! { stagedImagePath = staged }
        }
        defer { if let stagedImagePath { try? FileManager.default.removeItem(atPath: stagedImagePath) } }

        let escapedTo = escapeForAppleScript(to)
        // Two `send` calls, not one: Messages' `send` command takes either a
        // block of text or a file, never both, so a captioned photo is a text
        // send immediately followed by a file send to the same buddy.
        var sendLines: [String] = []
        if let text { sendLines.append("    send \"\(escapeForAppleScript(text))\" to targetBuddy") }
        if let imagePath {
            let sendPath = stagedImagePath ?? imagePath
            sendLines.append("    send (POSIX file \"\(escapeForAppleScript(sendPath))\") to targetBuddy")
        }

        let script = """
            tell application "Messages"
                set targetService to first service whose service type = iMessage
                set targetBuddy to buddy "\(escapedTo)" of targetService
            \(sendLines.joined(separator: "\n"))
            end tell
            """

        // As a file rather than an `-e` argument, for the reason Mail's JXA
        // calls are (`runJXAData`): an `-e` argument is bounded by ARG_MAX, and
        // a long message text would fail with "Argument list too long" instead
        // of sending. `MailService.stripScriptPath` undoes the path prefix
        // osascript then puts on a thrown error line.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-messages-\(UUID().uuidString).applescript")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
        } catch {
            return errorResult("failed to write the script for osascript: \(error.localizedDescription)")
        }

        // Separate files, not one shared `Pipe`: a pipe's buffer is 64KB, and
        // AppleScript's own error text echoes back whatever it failed on --
        // "no such buddy" quotes the identifier, "can't make ... into type"
        // quotes the value. `to` or `text` past that size, echoed into a
        // thrown error, fills the pipe while nothing is draining it, and
        // `waitUntilExit()` deadlocks forever: this server's single
        // synchronous stdin loop with it. A temp file has no such ceiling.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-messages-\(UUID().uuidString).out")
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-messages-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return errorResult("failed to open temp files for osascript output")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path]
        process.standardOutput = outHandle
        process.standardError = errHandle

        // Captured before the script runs, with a one-second margin, so the
        // delivery poll below can never mistake a message already in the
        // thread for the one this call is sending.
        let sentAfter = appleEpochNanos(Date(timeIntervalSinceNow: -1))

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return errorResult("failed to run osascript: \(error.localizedDescription)")
        }

        // A `send` that hasn't hung normally returns in well under a second;
        // this bound is for the one that has -- an unanswered Automation
        // consent prompt blocks osascript until it is answered, and nothing
        // else here would ever notice or recover.
        if !waitForProcess(process, timeout: 30) {
            process.terminate()
            if !waitForProcess(process, timeout: 2) {
                kill(process.processIdentifier, SIGKILL)
            }
            try? outHandle.close()
            try? errHandle.close()
            return errorResult(
                "osascript did not finish within 30s and was stopped -- Messages may be waiting on an "
                    + "Automation permission prompt; see permissions_check"
            )
        }
        try? outHandle.close()
        try? errHandle.close()

        if process.terminationStatus != 0 {
            let output = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            return errorResult("osascript failed: \(MailService.stripScriptPath(output, scriptPath: scriptURL.path))")
        }

        // osascript exiting 0 only means the request didn't throw -- Messages'
        // own scripting dictionary carries no delivery status at all, so
        // whether Apple actually accepted the message is read back from
        // chat.db rather than assumed. `sendLines.count` is 1 or 2 rows to
        // confirm, matching however many `send` calls the script just made.
        let sentWhat = text != nil && imagePath != nil ? "message and image" : (imagePath != nil ? "image" : "message")
        switch awaitDeliveryOutcome(
            to: to, sentAfter: sentAfter, expectedCount: sendLines.count, timeoutSeconds: timeout
        ) {
        case .sent:
            return textResult("\(sentWhat) sent to \(to)")
        case .failed(let code):
            return errorResult("Messages did not send the \(sentWhat) to \(to) (chat.db reports error \(code))")
        case .unconfirmed:
            return textResult(
                "\(sentWhat) handed to Messages for \(to), not yet confirmed sent after \(Int(timeout))s -- "
                    + "check messages_get_chat or messages_search to confirm delivery"
            )
        case .cannotVerify:
            return textResult(
                "\(sentWhat) handed to Messages for \(to); delivery could not be confirmed because chat.db "
                    + "could not be opened -- this needs Full Disk Access, in System Settings > Privacy & "
                    + "Security > Full Disk Access"
            )
        }
    }

    /// `destination` is required and this tool cannot function without one
    /// (there is nowhere else to put the bytes), which is why it is in
    /// `file_dirs`'s `applies_to` -- the `mail_save_attachment` /
    /// `utilities_play_sound` shape, not the optional-parameter one.
    private static func saveAttachment(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let attachmentID = args?["attachment_id"]?.intValue else {
            return errorResult("attachment_id is required")
        }
        guard let destinationArg = args?["destination"]?.stringValue, !destinationArg.isEmpty else {
            return errorResult("destination is required")
        }

        let scope = ResourceScope.parse(ctx.meta)
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return scopeViolationResult(refusal)
        }
        let destination: String
        switch HostFileScope.resolve(destinationArg, scope: scope, use: .write, what: "image attachment") {
        case .use(let resolved): destination = resolved
        case .refuse(let message): return scopeViolationResult(message)
        case .error(let message): return errorResult(message)
        }

        guard let db = openDB() else {
            return errorResult("failed to open Messages database")
        }
        defer { sqlite3_close(db) }

        guard let file = attachmentFile(id: Int64(attachmentID), db: db) else {
            return errorResult("no attachment with id \(attachmentID)")
        }
        guard file.mimeType.hasPrefix("image/") else {
            return errorResult(
                "attachment \(attachmentID) is not an image "
                    + "(mime type: \(file.mimeType.isEmpty ? "unknown" : file.mimeType))"
            )
        }
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return errorResult(
                "could not read attachment \(attachmentID) at \(file.path) -- it may no longer be on disk"
            )
        }

        do {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } catch {
            return errorResult("failed to write \(destination): \(error.localizedDescription)")
        }

        return jsonResult([
            "attachment_id": attachmentID,
            "filename": (file.path as NSString).lastPathComponent,
            "mime_type": file.mimeType,
            "bytes_saved": data.count,
            "destination": destination
        ])
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
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: false)
            ),
            category: cat,
            handler: listChats
        )

        registry.register(
            MCPTool(
                name: "messages_get_chat",
                description: "Get messages from a specific chat conversation, newest first. chat_id is the "
                    + "chat_identifier as messages_list_chats reports it. A message's image attachments are "
                    + "listed under attachments (attachment_id, filename, mime_type); save one with "
                    + "messages_save_attachment.",
                inputSchema: schema(
                    properties: [
                        "chat_id": stringProp("The chat_identifier to retrieve messages from"),
                        "limit": intProp("Maximum number of messages to return (default 50)")
                    ],
                    required: ["chat_id"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: false)
            ),
            category: cat,
            handler: getChat
        )

        registry.register(
            MCPTool(
                name: "messages_search",
                description: "Search messages across every chat, by text and/or by who they are with. Requires Full Disk Access. Returns the newest matches first, with messages_scanned and scan_complete saying how much of the window was read. A message's image attachments are listed under attachments (attachment_id, filename, mime_type) — an image with no caption has no text to match query and only appears when query is omitted.",
                inputSchema: schema(
                    properties: [
                        "query": stringProp("Text to look for, matched case-insensitively anywhere in a message. Omit to get every message in the window."),
                        "contact": stringProp("Phone number or email to limit the search to conversations with this person. Any formatting: +1 (555) 123-4567 and 5551234567 are the same handle. The whole thread is searched, including messages sent from this Mac."),
                        "hours_ago": numberProp("How far back to search, in hours (default 24). Ignored when 'since' is given."),
                        "since": stringProp("Search from this ISO 8601 date, with or without a time (2026-03-15 or 2026-03-15T09:00:00Z). Overrides hours_ago."),
                        "limit": intProp("Maximum number of matching messages to return (default 100)")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: false)
            ),
            category: cat,
            handler: searchMessages
        )

        // **The one open-world tool here, and the split that says why the
        // three above are not.** The reads are SQLite queries against
        // `~/Library/Messages/chat.db`, a local file Messages.app keeps in
        // sync on its own schedule; nothing the caller supplies leaves this
        // Mac and no request is made because a read happened. `messages_send`
        // hands text the caller wrote to a recipient the caller named, and
        // Apple delivers it to a device that is not this one -- irreversibly,
        // to an address that was never configured here.
        registry.register(
            MCPTool(
                name: "messages_send",
                description: "Send an iMessage to a phone number or email address, and confirm from chat.db "
                    + "that it actually sent (Messages' own scripting interface has no delivery status). "
                    + "Returns an error if it definitely failed, or an 'unconfirmed' result if that isn't "
                    + "known within timeout_seconds. text alone is reliable. image_path is NOT: on the "
                    + "environment this was verified on, every real image send failed after being handed to "
                    + "Messages (chat.db error 25, 22 or 1 on different attempts, never success), despite the "
                    + "text half of the same call sending correctly every time — treat image_path as "
                    + "unverified/likely broken until confirmed working on the machine you're running on, and "
                    + "always check messages_get_chat afterward rather than trusting an 'unconfirmed' or even "
                    + "a non-error result at face value for an image.",
                inputSchema: schema(
                    properties: [
                        "to": stringProp("Recipient phone number or email address"),
                        "text": stringProp("Message text to send. Optional if image_path is given."),
                        "image_path": stringProp(
                            "Absolute path to an image file to send. Must be a real, readable image; "
                                + "any other file is refused rather than handed to Messages."
                        ),
                        "timeout_seconds": numberProp(
                            "How long to wait for Messages to confirm the send before reporting it as "
                                + "unconfirmed (default 8, max 60). A message to a working recipient typically "
                                + "confirms in under 2 seconds; one that will fail can take 20s or more to report "
                                + "why, so raise this to wait for that answer instead of an 'unconfirmed' one."
                        )
                    ],
                    required: ["to"]
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: true)
            ),
            category: cat,
            handler: sendMessage
        )

        // Not open world: the source is a file already on this Mac's disk
        // (Messages' own storage) and the destination is a file on this same
        // Mac; nothing here is a request to anywhere else.
        registry.register(
            MCPTool(
                name: "messages_save_attachment",
                description: "Save an image attachment to disk, by the attachment_id messages_get_chat or "
                    + "messages_search reported. Refuses an attachment that is not an image.",
                inputSchema: schema(
                    properties: [
                        "attachment_id": intProp("attachment_id from messages_get_chat or messages_search"),
                        "destination": stringProp("Absolute path to save the image to")
                    ],
                    required: ["attachment_id", "destination"]
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
            ),
            category: cat,
            handler: saveAttachment
        )
    }
}
