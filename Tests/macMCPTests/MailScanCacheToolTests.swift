import XCTest
@testable import macmcp

/// `mail_clear_scan_cache` and `mail_mark_reviewed`'s bookkeeping half never
/// touch Mail, so unlike most mail tools they can be driven through the real
/// `ToolRegistry` dispatch hermetically -- as long as `MailScanCache.dbPath`
/// is pointed at a scratch file first, the same way `MessagesService.dbPath`
/// is redirected so no test reads the user's own data.
final class MailScanCacheToolTests: XCTestCase {
    private var scratchPath: String!
    private var savedPath: String!
    private var registry: ToolRegistry!

    override func setUp() {
        savedPath = MailScanCache.dbPath
        scratchPath = NSTemporaryDirectory() + "macmcp-scan-cache-tool-test-\(UUID().uuidString).sqlite3"
        MailScanCache.dbPath = scratchPath
        registry = ToolRegistry()
        MailService.register(registry)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: scratchPath)
        MailScanCache.dbPath = savedPath
    }

    private var scope: JSONObject {
        [
            "project_id": .string("proj-1"),
            "mail_accounts": .array([.string("Alice")]),
            "mail_mailboxes": .array([.string("INBOX")])
        ]
    }

    private func call(_ tool: String, _ args: JSONObject, meta: JSONObject? = nil) -> MCPCallResult {
        registry.call(name: tool, arguments: args, meta: meta)
    }

    func testClearWithNoFilterAndNoAllIsRefused() {
        let result = call("mail_clear_scan_cache", [:], meta: scope)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("all: true"))
    }

    func testClearWithAllRemovesEverythingThisProjectRecorded() {
        MailScanCache.record(projectID: "proj-1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        MailScanCache.record(projectID: "proj-1", account: "Alice", messageID: "b@x", verdict: "not_junk", note: nil)
        let result = call("mail_clear_scan_cache", ["all": .bool(true)], meta: scope)
        XCTAssertNotEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("\"removed\" : 2")
            || (result.content.first?.text ?? "").contains("\"removed\":2"))
    }

    func testClearIsRefusedUnderAMediatedCallWithNoMailScopeAtAll() {
        // Presence is required even though this tool never reaches Mail --
        // a profile granted no mail account scope was never given any
        // mail_* tool, and this one costs nothing extra to cover.
        let ungoverned: JSONObject = ["project_id": .string("proj-1")]
        let result = call("mail_clear_scan_cache", ["all": .bool(true)], meta: ungoverned)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
    }

    func testClearNeverCrossesAProjectBoundaryThroughTheRealHandler() {
        MailScanCache.record(projectID: "other-project", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        let result = call("mail_clear_scan_cache", ["all": .bool(true)], meta: scope)
        XCTAssertNotEqual(result.isError, true)
        XCTAssertTrue((result.content.first?.text ?? "").contains("\"removed\" : 0")
            || (result.content.first?.text ?? "").contains("\"removed\":0"))
    }

    func testUnmediatedCallIsNotSubjectToThePresenceCheck() {
        // No _meta at all is the "nobody mediated this" state every tool
        // here has always allowed.
        let result = call("mail_clear_scan_cache", ["all": .bool(true)])
        XCTAssertNotEqual(result.isError, true)
    }
}
