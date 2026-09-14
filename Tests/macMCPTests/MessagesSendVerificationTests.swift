import Foundation
import SQLite3
import XCTest
@testable import macmcp

/// `MessagesService.newestOutgoingMessages`, against a chat.db this test
/// builds itself. `messages_send` itself is not exercised here -- it drives a
/// real Messages.app over AppleScript, which no hermetic test may do -- but
/// the query that reads back whether Messages actually sent a message is
/// pure SQL over a database shape, and that is what this pins.
final class MessagesSendVerificationTests: XCTestCase {
    private var dbURL: URL!
    private var db: OpaquePointer!

    private func appleNanos(secondsAgo: Double) -> Int64 {
        let unix = Date(timeIntervalSinceNow: -secondsAgo).timeIntervalSince1970
        return Int64((unix - 978_307_200) * 1_000_000_000)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-messages-send-\(UUID().uuidString).db")

        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)

        let schema = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY, is_from_me INTEGER, date INTEGER,
                is_sent INTEGER, error INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        exec("INSERT INTO handle (ROWID, id) VALUES (1, '+15559876543')")
        exec("INSERT INTO chat (ROWID, chat_identifier) VALUES (1, '+15559876543')")
        exec("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")
    }

    override func tearDownWithError() throws {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dbURL)
        try super.tearDownWithError()
    }

    private func exec(_ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func insertMessage(rowid: Int, isFromMe: Int, secondsAgo: Double, isSent: Int, error: Int) {
        exec("""
            INSERT INTO message (ROWID, is_from_me, date, is_sent, error)
            VALUES (\(rowid), \(isFromMe), \(appleNanos(secondsAgo: secondsAgo)), \(isSent), \(error))
            """)
        exec("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(rowid))")
    }

    func testTheNewestMatchingOutgoingMessageIsReturnedFirst() {
        // An older sent message, then a newer one that is still pending --
        // the newer one is the one a just-issued send is asking about.
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 30, isSent: 1, error: 0)
        insertMessage(rowid: 2, isFromMe: 1, secondsAgo: 1, isSent: 0, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 60), limit: 1, db: db
        )
        XCTAssertEqual(rows.map(\.isSent), [false])
        XCTAssertEqual(rows.map(\.error), [0])
    }

    /// The bug this ordering fixes: `messages_send` with both `text` and
    /// `image_path` creates two rows, and the text row's `date` advances
    /// past the image row's once Messages confirms the text sent --
    /// measured live, this made a `date`-ordered `LIMIT 1` return the older,
    /// already-sent text row while the image sat unconfirmed for minutes,
    /// and the call reported "message and image sent" for a message whose
    /// image never went out. `ROWID` is assigned once, at insertion, and
    /// cannot move backward the way `date` just did.
    func testOrderingIsByRowidRatherThanByDateWhichCanMoveBackward() {
        // rowid 1 inserted first (the text, sent second in the AppleScript
        // but confirmed first) now carries the *later* date; rowid 2 (the
        // image, sent second) carries the *earlier* one -- reproducing the
        // measured inversion directly rather than relying on timing.
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 1, isSent: 1, error: 0)
        insertMessage(rowid: 2, isFromMe: 1, secondsAgo: 5, isSent: 0, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 60), limit: 2, db: db
        )
        // ROWID DESC: the image (2) first, the text (1) second -- regardless
        // of which one's `date` is later.
        XCTAssertEqual(rows.map(\.isSent), [false, true])
    }

    func testAMessageOlderThanTheCutoffIsIgnored() {
        // A send call captures "sent after" before it runs, precisely so an
        // older message already in the thread cannot be mistaken for the one
        // it just issued.
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 30, isSent: 1, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 5), limit: 1, db: db
        )
        XCTAssertEqual(rows.count, 0)
    }

    func testAnIncomingMessageIsNeverReadAsTheOutcomeOfASend() {
        insertMessage(rowid: 1, isFromMe: 0, secondsAgo: 1, isSent: 0, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 60), limit: 1, db: db
        )
        XCTAssertEqual(rows.count, 0)
    }

    func testAFailureCodeIsReadBackExactly() {
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 1, isSent: 0, error: 22)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 60), limit: 1, db: db
        )
        XCTAssertEqual(rows.map(\.error), [22])
    }

    func testNoHandleIDsIsNoMatchRatherThanEveryMessage() {
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 1, isSent: 1, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [], sentAfter: appleNanos(secondsAgo: 60), limit: 1, db: db
        )
        XCTAssertEqual(rows.count, 0, "an empty handle list must not silently match every chat")
    }

    func testFewerRowsThanExpectedComeBackShortRatherThanPadded() {
        // Only one row exists yet even though the caller expects two (a
        // text+image send whose image row has not been created at all) --
        // the array is simply shorter, which `awaitDeliveryOutcome` reads as
        // "not confirmed yet" rather than treating a missing row as sent.
        insertMessage(rowid: 1, isFromMe: 1, secondsAgo: 1, isSent: 1, error: 0)

        let rows = MessagesService.newestOutgoingMessages(
            handleIDs: [1], sentAfter: appleNanos(secondsAgo: 60), limit: 2, db: db
        )
        XCTAssertEqual(rows.count, 1)
    }
}
