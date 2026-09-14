import Foundation
import SQLite3
import XCTest
@testable import macmcp

/// `messages_search`, against a chat.db this test builds itself.
///
/// The suite must never read the user's own messages, so `MessagesService.dbPath`
/// is pointed at a temporary database carrying the columns the query actually
/// uses. That is enough to exercise the whole path for real: the SQL, the
/// `attributedBody` decode (a message sent by any recent Messages build has an
/// empty `text` column and lives only in that archive), the handle
/// normalisation, and the scan cap.
final class MessagesSearchTests: XCTestCase {
    private var dbURL: URL!
    private var savedPath: String!

    /// Nanoseconds since the Apple epoch, which is how chat.db stores a date.
    private func appleNanos(hoursAgo: Double) -> Int64 {
        let unix = Date(timeIntervalSinceNow: -hoursAgo * 3600).timeIntervalSince1970
        return Int64((unix - 978_307_200) * 1_000_000_000)
    }

    /// An NSAttributedString in the typedstream form chat.db stores, which is
    /// what `extractText(fromAttributedBody:)` reads.
    private func attributedBody(_ text: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedPath = MessagesService.dbPath
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-messages-\(UUID().uuidString).db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER,
                date INTEGER, handle_id INTEGER, error INTEGER DEFAULT 0
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // Two people, two chats. Ada is stored the way Messages stores a US
        // number; the tests ask for her by other renderings of the same one.
        exec(db, "INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567'), (2, 'grace@example.org')")
        exec(db, """
            INSERT INTO chat (ROWID, chat_identifier, display_name, service_name) VALUES
                (1, '+15551234567', '', 'iMessage'),
                (2, 'grace@example.org', 'Compiler crew', 'iMessage'),
                (3, 'nobody-ever-wrote-here@example.org', '', 'iMessage')
            """)
        exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1), (2, 2)")

        // 1: from Ada, text column populated.
        insert(db, rowid: 1, text: "Lunch at the analytical engine?", body: nil, fromMe: 0, hoursAgo: 2, handle: 1, chat: 1)
        // 2: sent from this Mac, in Ada's thread, body only in the archive.
        insert(db, rowid: 2, text: nil, body: attributedBody("Yes — bring the punch cards"), fromMe: 1, hoursAgo: 1, handle: 0, chat: 1)
        // 3: Grace's thread, mentions lunch too.
        insert(db, rowid: 3, text: "no lunch for me, debugging", body: nil, fromMe: 0, hoursAgo: 3, handle: 2, chat: 2)
        // 4: older than any window under test.
        insert(db, rowid: 4, text: "lunch last week", body: nil, fromMe: 0, hoursAgo: 300, handle: 1, chat: 1)
        // 5: an attachment or tapback -- no text anywhere.
        insert(db, rowid: 5, text: nil, body: nil, fromMe: 0, hoursAgo: 1, handle: 1, chat: 1)
        // 6: sent from this Mac, but Messages never delivered it.
        insert(
            db, rowid: 6, text: nil, body: attributedBody("dinner plans?"),
            fromMe: 1, hoursAgo: 0.5, handle: 0, chat: 1, error: 22
        )

        MessagesService.dbPath = dbURL.path
    }

    override func tearDownWithError() throws {
        MessagesService.dbPath = savedPath
        try? FileManager.default.removeItem(at: dbURL)
        try super.tearDownWithError()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func insert(
        _ db: OpaquePointer?, rowid: Int, text: String?, body: Data?,
        fromMe: Int, hoursAgo: Double, handle: Int, chat: Int, error: Int32 = 0
    ) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO message (ROWID, text, attributedBody, is_from_me, date, handle_id, error) VALUES (?,?,?,?,?,?,?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, Int64(rowid))
        if let text { sqlite3_bind_text(stmt, 2, text, -1, transient) } else { sqlite3_bind_null(stmt, 2) }
        if let body {
            _ = body.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(body.count), transient) }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int(stmt, 4, Int32(fromMe))
        sqlite3_bind_int64(stmt, 5, appleNanos(hoursAgo: hoursAgo))
        sqlite3_bind_int64(stmt, 6, Int64(handle))
        sqlite3_bind_int(stmt, 7, error)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        let messageDate = appleNanos(hoursAgo: hoursAgo)
        exec(db, "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (\(chat), \(rowid), \(messageDate))")
    }

    private func search(_ args: [String: JSONValue]) throws -> [String: Any] {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(name: "messages_search", arguments: args)
        let text = result.content.first?.text ?? ""
        XCTAssertNotEqual(result.isError, true, text)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func texts(_ payload: [String: Any]) -> [String] {
        (payload["messages"] as? [[String: Any]] ?? []).map { $0["text"] as? String ?? "" }
    }

    private func call(_ tool: String, _ args: [String: JSONValue]) throws -> Any {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(name: tool, arguments: args)
        let text = result.content.first?.text ?? ""
        XCTAssertNotEqual(result.isError, true, text)
        return try JSONSerialization.jsonObject(with: XCTUnwrap(text.data(using: .utf8)), options: .allowFragments)
    }

    // MARK: - Listing chats

    func testChatsAreOrderedByTheirNewestMessageNotByWhenTheChatWasCreated() throws {
        // Grace's chat has the lower ROWID (2) but Ada's has the newer
        // message (30 minutes ago vs. 3 hours), so ordering by `c.ROWID DESC`
        // -- creation order -- put Grace on top regardless of who had
        // actually said something more recently.
        let chats = try call("messages_list_chats", [:]) as? [[String: Any]] ?? []
        XCTAssertEqual(chats.map { $0["chat_identifier"] as? String }, ["+15551234567", "grace@example.org"])
    }

    func testAChatWithNoMessagesIsNotListedAsARecentConversation() throws {
        let chats = try call("messages_list_chats", [:]) as? [[String: Any]] ?? []
        XCTAssertFalse(chats.contains { $0["chat_identifier"] as? String == "nobody-ever-wrote-here@example.org" })
        XCTAssertEqual(chats.count, 2)
    }

    // MARK: - Searching

    func testAQueryMatchesTheTextColumnAndTheArchivedBodyAlike() throws {
        // The half that cannot be done in SQL. A message sent from this Mac has
        // an empty `text` column and its words only in `attributedBody`, so a
        // `LIKE` in the query would find the first of these and never the
        // second -- and the second is the majority of a modern chat.db.
        let payload = try search(["query": .string("punch cards"), "hours_ago": .int(48)])
        XCTAssertEqual(texts(payload), ["Yes — bring the punch cards"])
    }

    func testAQueryIsCaseInsensitiveAndMatchesAnywhereInTheMessage() throws {
        let payload = try search(["query": .string("LUNCH"), "hours_ago": .int(48)])
        XCTAssertEqual(texts(payload), [
            "Lunch at the analytical engine?",
            "no lunch for me, debugging"
        ], "newest first, and both threads")
    }

    func testTheWindowExcludesWhatIsOlderThanIt() throws {
        // `lunch last week` is 300 hours old and must not appear at 48.
        XCTAssertFalse(texts(try search(["query": .string("lunch"), "hours_ago": .int(48)])).contains("lunch last week"))
        XCTAssertTrue(texts(try search(["query": .string("lunch"), "hours_ago": .int(400)])).contains("lunch last week"))
    }

    func testAnHoursAgoFarBeyondInt64NanosecondsDoesNotCrash() throws {
        // `hours_ago * 3600 * 1e9` overflows `Int64` for anything past about
        // 2.6 million hours; it used to trap rather than clamp, killing the
        // whole process. Everything in a normal-sized window is still "since
        // the beginning of chat.db" as far as this cutoff is concerned.
        let payload = try search(["query": .string("lunch"), "hours_ago": .double(100_000_000_000)])
        XCTAssertTrue(texts(payload).contains("lunch last week"))
    }

    func testAnHoursAgoWrittenAsNanOrInfinityFallsBackToTheDefaultWindow() throws {
        // `Double("nan")` and `Double("inf")` both succeed, so a string here
        // is exactly how a NaN or an infinity reaches `hours_ago` -- and
        // `Int64(Double)` traps on both.
        for bad in ["nan", "inf", "-inf"] {
            let payload = try search(["query": .string("lunch"), "hours_ago": .string(bad)])
            XCTAssertFalse(texts(payload).contains("lunch last week"), "\(bad) did not fall back to the default window")
        }
    }

    func testSinceAcceptsADateWithNoTimeOnIt() throws {
        // `.withInternetDateTime` alone rejects a bare date, and a bare date is
        // what a caller writes for a tool whose other knob is in hours.
        let yesterday = ISO8601DateFormatter()
        yesterday.formatOptions = [.withFullDate]
        let stamp = yesterday.string(from: Date(timeIntervalSinceNow: -36 * 3600))
        let payload = try search(["query": .string("lunch"), "since": .string(stamp)])
        XCTAssertFalse(texts(payload).isEmpty, "a date-only 'since' was rejected: \(payload)")
    }

    func testASinceFarInTheFutureDoesNotCrash() throws {
        // A valid ISO 8601 date this far out still overflows Int64
        // nanoseconds-since-1970 once converted; the cutoff clamps instead of
        // trapping, and a window that starts after every message returns none.
        let payload = try search(["since": .string("9999-12-31")])
        XCTAssertEqual(texts(payload), [])
    }

    func testAnUnreadableSinceIsAnErrorRatherThanAWindowNobodyAskedFor() {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(name: "messages_search", arguments: ["since": .string("last tuesday")])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("last tuesday"))
    }

    // MARK: - Naming a contact

    func testAContactIsFoundHoweverTheNumberIsWritten() throws {
        // Messages stores one rendering of a number and a caller has another.
        // `h.id = ?` matched only the stored one, so asking for the number the
        // way an address book shows it returned nothing at all.
        for spelling in ["+1 (555) 123-4567", "555-123-4567", "5551234567", "+15551234567"] {
            let payload = try search(["contact": .string(spelling), "hours_ago": .int(48)])
            XCTAssertEqual(
                texts(payload),
                ["dinner plans?", "Yes — bring the punch cards", "Lunch at the analytical engine?"],
                "not found as \(spelling)"
            )
        }
    }

    func testNamingAContactSearchesTheWholeThreadNotOnlyWhatTheySent() throws {
        // The replies were sent from this Mac, so their `handle_id` is 0 and
        // they belong to the contact only by way of the chat.
        let payload = try search(["contact": .string("5551234567"), "hours_ago": .int(48)])
        let mine = (payload["messages"] as? [[String: Any]] ?? []).filter { $0["is_from_me"] as? Bool == true }
        XCTAssertEqual(mine.count, 2, "the caller's own side of the conversation is missing")
    }

    func testAContactNobodyHasIsSaidSoRatherThanReturnedAsNoMessages() throws {
        // An empty list would read as "you have no messages with them", which is
        // a different answer from "there is no such handle on this Mac".
        let payload = try search(["contact": .string("nobody@example.org")])
        XCTAssertEqual(texts(payload), [])
        XCTAssertTrue((payload["note"] as? String ?? "").contains("nobody@example.org"), "\(payload)")
    }

    func testAnEmailContactIsMatchedCaseInsensitively() throws {
        let payload = try search(["contact": .string("GRACE@example.org"), "hours_ago": .int(48)])
        XCTAssertEqual(texts(payload), ["no lunch for me, debugging"])
        XCTAssertEqual((payload["messages"] as? [[String: Any]])?.first?["display_name"] as? String, "Compiler crew")
    }

    // MARK: - What comes back

    func testARowWithNoTextAnywhereIsNotReturnedAsAnEmptyMessage() throws {
        // An attachment, a tapback or a deleted message. There is nothing to
        // show, and `"text": ""` is not a message.
        let payload = try search(["hours_ago": .int(48), "limit": .int(50)])
        XCTAssertFalse(texts(payload).contains(""), "\(payload)")
        XCTAssertEqual(texts(payload).count, 4)
    }

    func testAFailedOutgoingMessageReportsItsSendErrorInSearchAndGetChat() throws {
        // Without this, a message this Mac tried and failed to send reads
        // identically to one that actually went through -- in both tools that
        // return message rows, not just the one that just sent it.
        let searchRows = (try search(["hours_ago": .int(48)])["messages"] as? [[String: Any]]) ?? []
        let failedInSearch = searchRows.first { $0["text"] as? String == "dinner plans?" }
        XCTAssertEqual(failedInSearch?["send_error"] as? Int, 22)
        let sentRow = searchRows.first { $0["text"] as? String == "Yes — bring the punch cards" }
        XCTAssertNil(sentRow?["send_error"], "a message that sent must not carry a send_error")

        let chatRows = try call(
            "messages_get_chat", ["chat_id": .string("+15551234567"), "limit": .int(50)]
        ) as? [[String: Any]] ?? []
        let failedInChat = chatRows.first { $0["text"] as? String == "dinner plans?" }
        XCTAssertEqual(failedInChat?["send_error"] as? Int, 22)
    }

    func testSenderIsReportedForIncomingMessagesOnly() throws {
        let rows = try search(["hours_ago": .int(48)])["messages"] as? [[String: Any]] ?? []
        let incoming = rows.first { $0["is_from_me"] as? Bool == false }
        let outgoing = rows.first { $0["is_from_me"] as? Bool == true }
        XCTAssertNotNil(incoming?["sender"])
        XCTAssertNil(outgoing?["sender"], "a message sent from here has no sender handle to report")
    }

    func testTheLimitCountsMatchesRatherThanRowsRead() throws {
        // The reason the scan cap exists: a query cannot be pushed into SQL, so
        // asking SQLite for `limit` rows would cut the candidates before any of
        // them had been decoded. Two messages match `lunch` inside the window;
        // at limit 1 exactly one comes back, and it is the newest.
        let payload = try search(["query": .string("lunch"), "hours_ago": .int(48), "limit": .int(1)])
        XCTAssertEqual(texts(payload), ["Lunch at the analytical engine?"])
    }

    func testALimitOfZeroReturnsNoMessagesRatherThanOne() throws {
        // The count was checked against `limit` after appending a match, so a
        // limit of zero still let the first match through.
        let payload = try search(["query": .string("lunch"), "hours_ago": .int(48), "limit": .int(0)])
        XCTAssertEqual(texts(payload), [])
    }

    func testCoverageIsReportedOnEveryAnswer() throws {
        let payload = try search(["query": .string("lunch"), "hours_ago": .int(48)])
        XCTAssertEqual(payload["scan_complete"] as? Bool, true)
        XCTAssertEqual(payload["messages_scanned"] as? Int, 5, "every row in the window was read, matching or not")
        XCTAssertNil(payload["note"])
    }

    // MARK: - Limit bounds

    func testAnOversizedLimitIsClampedRatherThanCrashingTheProcess() throws {
        // `limit` arrives as a 64-bit Int and used to be bound straight into a
        // 32-bit sqlite parameter with `Int32(limit)`, which traps -- and took
        // the whole process down -- on anything past Int32.max.
        let huge = JSONValue.int(Int(Int32.max) + 1)
        XCTAssertEqual(texts(try search(["hours_ago": .int(48), "limit": huge])).count, 4)
        XCTAssertEqual((try call("messages_list_chats", ["limit": huge]) as? [[String: Any]])?.count, 2)
        let rows = try call(
            "messages_get_chat", ["chat_id": .string("+15551234567"), "limit": huge]
        ) as? [[String: Any]]
        XCTAssertEqual(rows?.count, 5)
    }

    func testALimitWrittenAsAStringOrADoubleIsHonouredLikeAnInt() throws {
        // `hours_ago` and `timeout_seconds` already read a string or a whole
        // double the way a model might write one; `limit` only matched
        // `JSONValue.int` and silently fell back to its default for either.
        let byString = try search(["hours_ago": .int(48), "limit": .string("1")])
        XCTAssertEqual(texts(byString).count, 1)
        let byDouble = try search(["hours_ago": .int(48), "limit": .double(1)])
        XCTAssertEqual(texts(byDouble).count, 1)
    }

    func testALimitThatIsNotFiniteFallsBackToTheDefaultRatherThanCrashing() throws {
        let payload = try search(["hours_ago": .int(48), "limit": .string("nan")])
        XCTAssertEqual(texts(payload).count, 4, "falls back to the default (100), not to zero or a crash")
    }

    func testANegativeLimitReturnsNothingRatherThanEveryRow() throws {
        // SQLite reads a negative LIMIT as "no limit"; passed through raw, a
        // negative value would let a caller dump every row past the default.
        XCTAssertEqual(texts(try search(["hours_ago": .int(48), "limit": .int(-1)])), [])
        XCTAssertEqual((try call("messages_list_chats", ["limit": .int(-1)]) as? [[String: Any]])?.count, 0)
        let rows = try call(
            "messages_get_chat", ["chat_id": .string("+15551234567"), "limit": .int(-1)]
        ) as? [[String: Any]]
        XCTAssertEqual(rows?.count, 0)
    }

    // MARK: - Handle normalisation

    func testNormalisedHandleComparesTheThingsThatAreTheSameNumber() {
        XCTAssertEqual(MessagesService.normalizedHandle("+1 (555) 123-4567"), MessagesService.normalizedHandle("555-123-4567"))
        XCTAssertEqual(MessagesService.normalizedHandle("+44 20 7946 0958"), MessagesService.normalizedHandle("020 7946 0958"))
        XCTAssertEqual(MessagesService.normalizedHandle("Ada@Example.ORG "), "ada@example.org")
        XCTAssertNotEqual(MessagesService.normalizedHandle("5551234567"), MessagesService.normalizedHandle("5551234568"))
        // A short code is compared whole rather than by a ten-digit suffix.
        XCTAssertEqual(MessagesService.normalizedHandle("262966"), "262966")
    }
}
