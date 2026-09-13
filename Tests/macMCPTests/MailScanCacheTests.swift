import XCTest
@testable import macmcp

/// `MailScanCache` is macMCP's own local bookkeeping -- never Mail.app state
/// -- so these tests point it at a scratch file for the duration of the test
/// and never touch the user's own cache.
final class MailScanCacheTests: XCTestCase {
    private var scratchPath: String!
    private var savedPath: String!

    override func setUp() {
        savedPath = MailScanCache.dbPath
        scratchPath = NSTemporaryDirectory() + "macmcp-scan-cache-test-\(UUID().uuidString).sqlite3"
        MailScanCache.dbPath = scratchPath
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: scratchPath)
        MailScanCache.dbPath = savedPath
    }

    func testAnUnrecordedMessageIsUnreviewed() {
        let result = MailScanCache.unreviewed(projectID: "p1", account: "Alice", messageIDs: ["a@x", "b@x"])
        XCTAssertEqual(result, ["a@x", "b@x"])
    }

    func testARecordedMessageDropsOutOfUnreviewed() {
        XCTAssertTrue(MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil))
        let result = MailScanCache.unreviewed(projectID: "p1", account: "Alice", messageIDs: ["a@x", "b@x"])
        XCTAssertEqual(result, ["b@x"])
    }

    func testAccountNamesFoldTheSameWayEveryOtherScopeComparisonDoes() {
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        // A different spelling of the same account (case, here) must still
        // find the entry -- the same fold every mail scope comparison uses.
        let result = MailScanCache.unreviewed(projectID: "p1", account: "ALICE", messageIDs: ["a@x"])
        XCTAssertEqual(result, [])
    }

    func testTwoProjectsNeverSeeEachOthersProgress() {
        MailScanCache.record(projectID: "project-a", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        let result = MailScanCache.unreviewed(projectID: "project-b", account: "Alice", messageIDs: ["a@x"])
        XCTAssertEqual(result, ["a@x"], "project-b's own view of a@x must be unaffected by project-a's verdict")
    }

    func testTwoAccountsWithTheSameMessageIDAreKeptSeparate() {
        // Message-ID is not guaranteed globally unique, so it is not the
        // whole key.
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "dup@x", verdict: "junk", note: nil)
        let result = MailScanCache.unreviewed(projectID: "p1", account: "Bob", messageIDs: ["dup@x"])
        XCTAssertEqual(result, ["dup@x"])
    }

    func testRecordingTwiceUpdatesRatherThanDuplicating() {
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "not_junk", note: "reconsidered")
        XCTAssertEqual(MailScanCache.clear(projectID: "p1", account: "Alice", messageID: nil, olderThanDays: nil), 1)
    }

    func testClearByMessageIDRemovesOnlyThatEntry() {
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "b@x", verdict: "junk", note: nil)
        XCTAssertEqual(MailScanCache.clear(projectID: "p1", account: nil, messageID: "a@x", olderThanDays: nil), 1)
        XCTAssertEqual(MailScanCache.unreviewed(projectID: "p1", account: "Alice", messageIDs: ["a@x", "b@x"]), ["a@x"])
    }

    func testClearByAccountRemovesOnlyThatAccountsEntries() {
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        MailScanCache.record(projectID: "p1", account: "Bob", messageID: "b@x", verdict: "junk", note: nil)
        XCTAssertEqual(MailScanCache.clear(projectID: "p1", account: "Alice", messageID: nil, olderThanDays: nil), 1)
        XCTAssertEqual(MailScanCache.unreviewed(projectID: "p1", account: "Bob", messageIDs: ["b@x"]), [])
    }

    func testClearNeverCrossesAProjectBoundary() {
        MailScanCache.record(projectID: "project-a", account: "Alice", messageID: "a@x", verdict: "junk", note: nil)
        XCTAssertEqual(MailScanCache.clear(projectID: "project-b", account: "Alice", messageID: nil, olderThanDays: nil), 0)
        XCTAssertEqual(MailScanCache.unreviewed(projectID: "project-a", account: "Alice", messageIDs: ["a@x"]), [])
    }

    func testClearByAgeKeepsAFreshEntryUnderAWideWindow() {
        MailScanCache.record(projectID: "p1", account: "Alice", messageID: "fresh@x", verdict: "junk", note: nil)
        // A freshly-recorded entry is not older than 3650 days, so a wide
        // window must not remove it.
        XCTAssertEqual(MailScanCache.clear(projectID: "p1", account: nil, messageID: nil, olderThanDays: 3650), 0)
        XCTAssertEqual(MailScanCache.unreviewed(projectID: "p1", account: "Alice", messageIDs: ["fresh@x"]), [])
    }
}
