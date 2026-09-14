import Foundation
import XCTest
@testable import macmcp

/// `file_dirs` on the two Messages tools that touch a file on this host:
/// `messages_save_attachment` (a required `destination`, the tool cannot
/// function without one -- the `mail_save_attachment`/`utilities_play_sound`
/// shape) and `messages_send`'s optional `image_path` (the tool works fine
/// without one, exactly like `mail_send`'s `attachments`).
///
/// Every case here is a refusal that returns before any AppleScript is
/// written or `osascript` is spawned -- `HostFileScope.resolve` runs first in
/// both handlers -- so no real Messages.app interaction happens and none of
/// this needs Full Disk Access either.
final class MessagesHostFileScopeTests: XCTestCase {
    private func registry() -> ToolRegistry {
        let registry = ToolRegistry()
        MessagesService.register(registry)
        return registry
    }

    /// `_meta` present with nothing else in it: relay injects `project_id` on
    /// every mediated call, so this is a profile that carries no `file_dirs`.
    private let mediatedWithNoDirs: JSONObject = ["project_id": .string("prof_hermes")]

    private func dirs(_ paths: [String]) -> JSONObject {
        ["project_id": .string("prof_hermes"), "file_dirs": .array(paths.map { .string($0) })]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmcp-messages-hostfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
    }

    // MARK: - Which shape each tool is

    func testMessagesSaveAttachmentIsDeclaredAsGovernedByFileDirs() {
        XCTAssertTrue(restrictFieldsGoverning(tool: "messages_save_attachment").contains("file_dirs"))
    }

    func testMessagesSendIsNotDeclaredAsGovernedByFileDirs() {
        // `image_path` is optional -- a plain-text send works with no
        // `file_dirs` at all -- so the whole tool must not be denied over it.
        XCTAssertFalse(restrictFieldsGoverning(tool: "messages_send").contains("file_dirs"))
    }

    // MARK: - messages_save_attachment: required destination

    func testMessagesSaveAttachmentRefusesADestinationOutsideFileDirs() throws {
        let root = try temporaryDirectory()
        let result = registry().call(
            name: "messages_save_attachment",
            arguments: ["attachment_id": .int(1), "destination": .string("/tmp/zsec-out.png")],
            meta: dirs([root.path])
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(
            (result.content.first?.text ?? "").contains("outside the directories"),
            result.content.first?.text ?? ""
        )
    }

    func testMessagesSaveAttachmentRefusesWhenNoFileDirsAtAll() {
        let result = registry().call(
            name: "messages_save_attachment",
            arguments: ["attachment_id": .int(1), "destination": .string("/tmp/x.png")],
            meta: mediatedWithNoDirs
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(
            (result.content.first?.text ?? "").contains("refusal rather than \"anywhere\""),
            result.content.first?.text ?? ""
        )
    }

    func testMessagesSaveAttachmentRefusesBeforeEverOpeningChatDatabase() {
        // A scope refusal must not depend on Full Disk Access being granted:
        // `openDB()` is unreachable code on this path, not merely untested.
        // Pointed at a path that cannot possibly be a real chat.db, so if the
        // handler ever reached `openDB()` this would surface as some other
        // failure instead of the scope refusal asserted above.
        MessagesService.dbPath = "/nonexistent/definitely-not-a-real/chat.db"
        defer { MessagesService.dbPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Messages/chat.db" }
        let result = registry().call(
            name: "messages_save_attachment",
            arguments: ["attachment_id": .int(1), "destination": .string("/tmp/x.png")],
            meta: mediatedWithNoDirs
        )
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
    }

    // MARK: - messages_send: optional image_path

    func testMessagesSendRefusesAnImagePathOutsideFileDirs() throws {
        let root = try temporaryDirectory()
        let result = registry().call(
            name: "messages_send",
            arguments: [
                "to": .string("nobody@nowhere.invalid"),
                "text": .string("probe"),
                "image_path": .string("/tmp/zsec-photo.png")
            ],
            meta: dirs([root.path])
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(
            (result.content.first?.text ?? "").contains("outside the directories"),
            result.content.first?.text ?? ""
        )
    }

    func testMessagesSendRefusesAnImagePathWhenNoFileDirsAtAll() {
        let result = registry().call(
            name: "messages_send",
            arguments: [
                "to": .string("nobody@nowhere.invalid"),
                "text": .string("probe"),
                "image_path": .string("/tmp/zsec-photo.png")
            ],
            meta: mediatedWithNoDirs
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(
            (result.content.first?.text ?? "").contains("may not read files"),
            result.content.first?.text ?? ""
        )
    }
}
