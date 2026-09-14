import Foundation
import SQLite3
import XCTest
@testable import macmcp

/// Image attachments, end to end against a chat.db this test builds itself:
/// surfaced by `messages_get_chat` and `messages_search`, filtered to images
/// only, and saved to disk by `messages_save_attachment`.
final class MessagesAttachmentTests: XCTestCase {
    private var dbURL: URL!
    private var savedPath: String!
    private var imageURL: URL!
    private var videoURL: URL!

    private func appleNanos(hoursAgo: Double) -> Int64 {
        let unix = Date(timeIntervalSinceNow: -hoursAgo * 3600).timeIntervalSince1970
        return Int64((unix - 978_307_200) * 1_000_000_000)
    }

    /// A tiny real PNG, not a stand-in: `messages_save_attachment` copies
    /// bytes off disk, and the fixture has to have real bytes to copy.
    private func onePixelPNG() -> Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
            0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedPath = MessagesService.dbPath
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-messages-attach-\(UUID().uuidString).db")
        imageURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-attach-\(UUID().uuidString).png")
        videoURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-attach-\(UUID().uuidString).mov")
        try onePixelPNG().write(to: imageURL)
        try Data("not really a video, just needs to exist".utf8).write(to: videoURL)

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
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        exec(db, "INSERT INTO handle (ROWID, id) VALUES (1, '+15559876543')")
        exec(db, "INSERT INTO chat (ROWID, chat_identifier, display_name, service_name) VALUES (1, '+15559876543', '', 'iMessage')")
        exec(db, "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")

        // 1: a captioned photo -- text and an image together.
        insertMessage(db, rowid: 1, text: "check this out", fromMe: 0, hoursAgo: 3, handle: 1)
        insertAttachment(db, id: 1, messageID: 1, filename: imageURL.path, mimeType: "image/png")

        // 2: an image with no caption at all.
        insertMessage(db, rowid: 2, text: nil, fromMe: 0, hoursAgo: 2, handle: 1)
        insertAttachment(db, id: 2, messageID: 2, filename: imageURL.path, mimeType: "image/png")

        // 3: a video, not an image -- must never surface as an attachment.
        insertMessage(db, rowid: 3, text: nil, fromMe: 0, hoursAgo: 1, handle: 1)
        insertAttachment(db, id: 3, messageID: 3, filename: videoURL.path, mimeType: "video/quicktime")

        MessagesService.dbPath = dbURL.path
    }

    override func tearDownWithError() throws {
        MessagesService.dbPath = savedPath
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: videoURL)
        try super.tearDownWithError()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func insertMessage(_ db: OpaquePointer?, rowid: Int, text: String?, fromMe: Int, hoursAgo: Double, handle: Int) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO message (ROWID, text, is_from_me, date, handle_id) VALUES (?,?,?,?,?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, Int64(rowid))
        if let text { sqlite3_bind_text(stmt, 2, text, -1, transient) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_int(stmt, 3, Int32(fromMe))
        let nanos = appleNanos(hoursAgo: hoursAgo)
        sqlite3_bind_int64(stmt, 4, nanos)
        sqlite3_bind_int64(stmt, 5, Int64(handle))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        exec(db, "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, \(rowid), \(nanos))")
    }

    private func insertAttachment(_ db: OpaquePointer?, id: Int, messageID: Int, filename: String, mimeType: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO attachment (ROWID, filename, mime_type) VALUES (?,?,?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, Int64(id))
        sqlite3_bind_text(stmt, 2, filename, -1, transient)
        sqlite3_bind_text(stmt, 3, mimeType, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        exec(db, "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (\(messageID), \(id))")
    }

    private func call(_ tool: String, _ args: [String: JSONValue], meta: JSONObject? = nil) throws -> Any {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(name: tool, arguments: args, meta: meta)
        let text = result.content.first?.text ?? ""
        XCTAssertNotEqual(result.isError, true, text)
        return try JSONSerialization.jsonObject(with: XCTUnwrap(text.data(using: .utf8)), options: .allowFragments)
    }

    // MARK: - messages_get_chat

    func testGetChatSurfacesImageAttachmentsOnACaptionedMessage() throws {
        let rows = try call("messages_get_chat", ["chat_id": .string("+15559876543"), "limit": .int(50)]) as? [[String: Any]] ?? []
        let captioned = rows.first { $0["text"] as? String == "check this out" }
        let attachments = try XCTUnwrap(captioned?["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["attachment_id"] as? Int, 1)
        XCTAssertEqual(attachments.first?["mime_type"] as? String, "image/png")
        XCTAssertEqual(attachments.first?["filename"] as? String, imageURL.lastPathComponent)
    }

    func testGetChatSurfacesAnUncaptionedImageWithEmptyText() throws {
        let rows = try call("messages_get_chat", ["chat_id": .string("+15559876543"), "limit": .int(50)]) as? [[String: Any]] ?? []
        let uncaptioned = rows.first { ($0["attachments"] as? [[String: Any]])?.first?["attachment_id"] as? Int == 2 }
        XCTAssertEqual(uncaptioned?["text"] as? String, "")
    }

    func testGetChatNeverSurfacesANonImageAttachment() throws {
        let rows = try call("messages_get_chat", ["chat_id": .string("+15559876543"), "limit": .int(50)]) as? [[String: Any]] ?? []
        for row in rows {
            let ids = (row["attachments"] as? [[String: Any]] ?? []).compactMap { $0["attachment_id"] as? Int }
            XCTAssertFalse(ids.contains(3), "the video attachment must never be listed")
        }
    }

    // MARK: - messages_search

    func testSearchSurfacesAttachmentsAndIncludesAnUncaptionedImageWithNoQuery() throws {
        let payload = try call("messages_search", ["hours_ago": .int(48)]) as? [String: Any] ?? [:]
        let rows = payload["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(rows.contains { $0["text"] as? String == "" && $0["attachments"] != nil })
        XCTAssertFalse(
            rows.contains { ($0["attachments"] as? [[String: Any]])?.contains { $0["attachment_id"] as? Int == 3 } == true },
            "the video attachment must never be listed"
        )
    }

    func testSearchExcludesAnUncaptionedImageWhenAQueryIsGiven() throws {
        // No text to match, so a text query correctly finds nothing for it --
        // browsing (no query) is the only way to see an uncaptioned photo.
        let payload = try call("messages_search", ["query": .string("out"), "hours_ago": .int(48)]) as? [String: Any] ?? [:]
        let rows = payload["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["text"] as? String, "check this out")
    }

    // MARK: - messages_save_attachment

    func testSaveAttachmentWritesTheExactBytesUnscoped() throws {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macmcp-saved-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: dest) }
        let payload = try call(
            "messages_save_attachment", ["attachment_id": .int(1), "destination": .string(dest.path)]
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(payload["mime_type"] as? String, "image/png")
        XCTAssertEqual(payload["bytes_saved"] as? Int, onePixelPNG().count)
        XCTAssertEqual(try Data(contentsOf: dest), onePixelPNG())
    }

    func testSaveAttachmentRefusesANonImageAttachment() {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(
            name: "messages_save_attachment",
            arguments: ["attachment_id": .int(3), "destination": .string("/tmp/whatever.mov")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("not an image"))
    }

    func testSaveAttachmentRefusesAnUnknownId() {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        let result = registry.call(
            name: "messages_save_attachment",
            arguments: ["attachment_id": .int(9999), "destination": .string("/tmp/whatever.png")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("no attachment with id"))
    }
}
