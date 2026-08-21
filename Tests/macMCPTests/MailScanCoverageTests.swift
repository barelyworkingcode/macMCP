import XCTest
@testable import macmcp

/// What a scan says when it could not read everything it was asked about
/// (issue #52).
///
/// The scan gives up on a mailbox that keeps changing under it and names it in
/// `unstable_mailboxes` rather than returning rows it cannot stand behind —
/// that trade is right, and the condition is transient. What was wrong is that
/// the non-answer was not legible as one:
///
/// ```json
/// {"messages":[], "messages_scanned":0, "total_messages":0, "truncated":false,
///  "unstable_mailboxes":["Alice:INBOX"]}
/// ```
///
/// with `isError: false`. `total_messages: 0` is an affirmative claim of
/// emptiness, and the mailbox it fired on held thousands of messages. A caller
/// who does not know to read `unstable_mailboxes` cannot tell "I could not read
/// this" from "there is nothing here".
final class MailScanCoverageTests: XCTestCase {
    private func outcome(
        scanned: [String] = [],
        unstable: [String] = [],
        skipped: [String] = [],
        failed: [String] = [],
        total: Int = 0
    ) -> MailService.ScanOutcome {
        var out = MailService.ScanOutcome()
        out.scanned = scanned
        out.unstable = unstable
        out.skipped = skipped
        out.failed = failed
        out.total = total
        out.matchedMailbox = true
        return out
    }

    private func text(_ result: MCPCallResult?) -> String {
        result?.content.first?.text ?? ""
    }

    func testAScanThatReadNothingBecauseEverythingWasUnstableIsAnError() throws {
        let result = MailService.scanFailure(
            outcome(unstable: ["Alice:INBOX"]),
            targets: ["Alice"],
            mailbox: "INBOX"
        )
        XCTAssertEqual(result?.isError, true, "an empty result would claim the mailbox is empty")
        let message = text(result)
        XCTAssertTrue(message.contains("Alice:INBOX"), "the caller is not told which mailbox: \(message)")
        XCTAssertTrue(
            message.range(of: "transient", options: .caseInsensitive) != nil,
            "a retryable condition has to say so: \(message)"
        )
    }

    func testAScanThatReadSomethingIsStillAnAnswer() throws {
        // One of two mailboxes came back. The rows that were read are worth
        // having, and refusing them would be a worse answer than the partial
        // one -- so this is not an error, and `scanComplete` is what says the
        // count is short.
        let partial = outcome(scanned: ["Alice:Archive"], unstable: ["Alice:INBOX"], total: 4)
        XCTAssertNil(MailService.scanFailure(partial, targets: ["Alice"], mailbox: "all"))
        XCTAssertFalse(partial.scanComplete)
        XCTAssertNotNil(partial.incompleteNote)
        XCTAssertTrue(partial.incompleteNote?.contains("Alice:INBOX") == true)
    }

    func testAnEmptyMailboxIsStillAllowedToBeEmpty() throws {
        // The control, and the reason this cannot simply refuse every empty
        // result: a mailbox that really is empty scanned cleanly, and saying so
        // is the right answer.
        let empty = outcome(scanned: ["Alice:INBOX"])
        XCTAssertNil(MailService.scanFailure(empty, targets: ["Alice"], mailbox: "INBOX"))
        XCTAssertTrue(empty.scanComplete)
        XCTAssertNil(empty.incompleteNote)
    }

    func testCoverageIsReportedWhateverWentWrong() throws {
        // `scan_complete` is not only about unstable mailboxes: a mailbox that
        // raised, or an account whose scan failed, leaves the counts just as
        // short, and each has to be named.
        let raised = outcome(scanned: ["Alice:INBOX"], skipped: ["Alice:Junk"])
        XCTAssertFalse(raised.scanComplete)
        XCTAssertTrue(raised.incompleteNote?.contains("Alice:Junk") == true)

        let wedged = outcome(scanned: ["Alice:INBOX"], failed: ["Bob: Mail timed out"])
        XCTAssertFalse(wedged.scanComplete)
        XCTAssertTrue(wedged.incompleteNote?.contains("Bob: Mail timed out") == true)
    }

    func testEveryAccountFailingIsStillTheErrorItWas() throws {
        let result = MailService.scanFailure(
            outcome(failed: ["Alice: timed out", "Bob: timed out"]),
            targets: ["Alice", "Bob"],
            mailbox: "INBOX"
        )
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(text(result).contains("scan failed for every account"))
    }
}
