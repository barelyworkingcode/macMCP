import XCTest
@testable import macmcp

/// What a scan says when it could not read everything it was asked about
/// (issue #52), and what it says when a mailbox *changed* under it rather than
/// failing.
///
/// The two are different answers and used to be the same one. A mailbox that
/// changed was discarded whole and reported in `unstable_mailboxes`, which
/// produced:
///
/// ```json
/// {"messages":[], "messages_scanned":0, "total_messages":0, "truncated":false,
///  "unstable_mailboxes":["Alice:INBOX"]}
/// ```
///
/// with `isError: false` — `total_messages: 0` being an affirmative claim of
/// emptiness about a mailbox holding thousands of messages. Making that an
/// error was right as far as it went, but the underlying trade was wrong: the
/// rows are recoverable one message at a time, so a changed mailbox now
/// contributes verified rows and a correct count, and only a mailbox that could
/// not be read *at all* is a coverage failure.
final class MailScanCoverageTests: XCTestCase {
    private func outcome(
        scanned: [String] = [],
        skipped: [String] = [],
        changed: [String] = [],
        failed: [String] = [],
        reverified: Int = 0,
        dropped: Int = 0,
        filtered: Bool = false,
        total: Int = 0,
        matched: Bool = true
    ) -> MailService.ScanOutcome {
        var out = MailService.ScanOutcome()
        out.scanned = scanned
        out.skipped = skipped
        out.changed = changed
        out.failed = failed
        out.reverified = reverified
        out.dropped = dropped
        out.filtered = filtered
        out.total = total
        out.matchedMailbox = matched
        return out
    }

    private func text(_ result: MCPCallResult?) -> String {
        result?.content.first?.text ?? ""
    }

    // MARK: - Nothing could be read

    func testAScanThatReadNothingAtAllIsAnError() throws {
        let result = MailService.scanFailure(
            outcome(skipped: ["Alice:INBOX: Mail stopped answering"]),
            targets: ["Alice"],
            mailbox: "INBOX"
        )
        XCTAssertEqual(result?.isError, true, "an empty result would claim the mailbox is empty")
        let message = text(result)
        XCTAssertTrue(message.contains("Alice:INBOX"), "the caller is not told which mailbox: \(message)")
        XCTAssertTrue(message.contains("Mail stopped answering"), "the reason was dropped: \(message)")
    }

    func testAMixedFailureNamesBothHalves() throws {
        // The shape that used to report only one of them: one account timed out
        // and one mailbox could not be read, so neither "every account failed"
        // nor a single-cause sentence describes it. The timeout used to go
        // unmentioned entirely.
        let result = MailService.scanFailure(
            outcome(skipped: ["Bob:INBOX: the mailbox list kept changing"], failed: ["Alice: Mail timed out"]),
            targets: ["Alice", "Bob"],
            mailbox: "INBOX"
        )
        XCTAssertEqual(result?.isError, true)
        let message = text(result)
        XCTAssertTrue(message.contains("Alice: Mail timed out"), "the account that timed out is unmentioned: \(message)")
        XCTAssertTrue(message.contains("Bob:INBOX"), "the mailbox that could not be read is unmentioned: \(message)")
    }

    func testAMissingMailboxBesideAnUnreadAccountIsNotADefinitiveNegative() throws {
        // "no mailbox named X" is a claim about every account in scope. With one
        // of them unread it is a claim built on an account nobody looked in, and
        // it used to be made anyway — flatly, and before the payload, so
        // failed_accounts and note were never emitted either.
        let result = MailService.scanFailure(
            outcome(failed: ["Alice: Mail timed out"], matched: false),
            targets: ["Alice", "Bob"],
            mailbox: "Projects/Q3"
        )
        XCTAssertEqual(result?.isError, true)
        let message = text(result)
        XCTAssertTrue(message.contains("Projects/Q3"), "the name asked for is unmentioned: \(message)")
        XCTAssertTrue(message.contains("Alice: Mail timed out"), "the unread account is unmentioned: \(message)")
        XCTAssertFalse(
            message.hasPrefix("no mailbox named \"Projects/Q3\" found"),
            "a definitive negative built on an account that was never read: \(message)"
        )
    }

    func testAMailboxThatIsNowhereIsStillADefinitiveNegative() throws {
        // The control for the one above: every account was read and none of them
        // has it, so saying so plainly is the right answer.
        let result = MailService.scanFailure(
            outcome(matched: false),
            targets: ["Alice", "Bob"],
            mailbox: "Projects/Q3"
        )
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(text(result).contains("mail_list_mailboxes"))
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

    // MARK: - Something was read

    func testAScanThatReadSomethingIsStillAnAnswer() throws {
        let partial = outcome(scanned: ["Alice:Archive"], skipped: ["Alice:INBOX: raised"], total: 4)
        XCTAssertNil(MailService.scanFailure(partial, targets: ["Alice"], mailbox: "all"))
        XCTAssertFalse(partial.scanComplete)
        XCTAssertTrue(partial.coverageNote?.contains("Alice:INBOX") == true)
    }

    func testAnEmptyMailboxIsStillAllowedToBeEmpty() throws {
        let empty = outcome(scanned: ["Alice:INBOX"])
        XCTAssertNil(MailService.scanFailure(empty, targets: ["Alice"], mailbox: "INBOX"))
        XCTAssertTrue(empty.scanComplete)
        XCTAssertNil(empty.coverageNote)
    }

    func testCoverageIsReportedWhateverWentWrong() throws {
        let raised = outcome(scanned: ["Alice:INBOX"], skipped: ["Alice:Junk: raised"])
        XCTAssertFalse(raised.scanComplete)
        XCTAssertTrue(raised.coverageNote?.contains("Alice:Junk") == true)

        let wedged = outcome(scanned: ["Alice:INBOX"], failed: ["Bob: Mail timed out"])
        XCTAssertFalse(wedged.scanComplete)
        XCTAssertTrue(wedged.coverageNote?.contains("Bob: Mail timed out") == true)
    }

    // MARK: - A mailbox that changed is not a mailbox that failed

    func testAChangedMailboxIsNotACoverageFailure() throws {
        // It was read, and every row returned from it was re-read by id. Calling
        // that incomplete would be false, and it is what made a scan under
        // delivery return nothing at all.
        let churned = outcome(
            scanned: ["Alice:INBOX"],
            changed: ["Alice:INBOX"],
            reverified: 20,
            dropped: 1,
            total: 11807
        )
        XCTAssertNil(MailService.scanFailure(churned, targets: ["Alice"], mailbox: "INBOX"))
        XCTAssertTrue(churned.scanComplete, "the mailbox was read; nothing about it is short")
        let note = churned.coverageNote ?? ""
        XCTAssertTrue(note.contains("Alice:INBOX"), "the mailbox that moved is unnamed: \(note)")
        XCTAssertTrue(note.contains("20"), "the rows re-read are uncounted: \(note)")
        XCTAssertTrue(note.contains("1"), "the rows let go are uncounted: \(note)")
    }

    // MARK: - The body pass's own coverage

    private func sweep(rows: Int, total: Int, skipped: [String] = [], failed: [String] = []) -> MailService.ScanOutcome {
        var out = MailService.ScanOutcome()
        out.rows = (0..<rows).map { ["id": "\($0)"] }
        out.total = total
        out.skipped = skipped
        out.failed = failed
        out.scanned = rows > 0 ? ["Alice:INBOX"] : []
        return out
    }

    func testASweepThatReadNothingIsNotACompleteBodyScan() throws {
        // The exact shape the metadata scan had removed and the sweep never
        // got. The sweep is its own scan of the same scope: a mailbox it could
        // not read contributes no candidates AND nothing to its total, so
        // `rows.count >= total` is 0 >= 0 — satisfied *by* the failure. Every
        // other term is satisfied the same way (no candidates to drop, no
        // bodies to fail to read), and the answer came out
        // `body_scan_complete: true, bodies_read: 0, body_matches: 0`.
        XCTAssertFalse(
            MailService.bodyScanComplete(
                bodiesRead: true,
                candidates: 0,
                eligible: 0,
                sweep: sweep(rows: 0, total: 0, skipped: ["Alice:INBOX: it kept changing while it was being read"])
            ),
            "a sweep that read no mailbox at all cannot be a complete body scan"
        )
    }

    func testASweepWhoseAccountTimedOutIsNotACompleteBodyScan() throws {
        // The other half of the sweep's coverage, discarded in exactly the same
        // way: `sweep.failed` was never read either.
        XCTAssertFalse(
            MailService.bodyScanComplete(
                bodiesRead: true,
                candidates: 3,
                eligible: 3,
                sweep: sweep(rows: 3, total: 3, failed: ["Bob: Mail timed out"])
            ),
            "an account the sweep never reached leaves the body scan short"
        )
    }

    func testASweepThatReadEverythingIsACompleteBodyScan() throws {
        // The control. Nothing above may be achieved by refusing to ever say
        // true.
        XCTAssertTrue(
            MailService.bodyScanComplete(
                bodiesRead: true,
                candidates: 3,
                eligible: 3,
                sweep: sweep(rows: 3, total: 3)
            )
        )
    }

    func testTheOlderWaysOfFallingShortStillCount() throws {
        // Regressions on the three terms that were already there.
        let clean = sweep(rows: 3, total: 3)
        XCTAssertFalse(MailService.bodyScanComplete(bodiesRead: false, candidates: 3, eligible: 3, sweep: clean))
        XCTAssertFalse(MailService.bodyScanComplete(bodiesRead: true, candidates: 2, eligible: 3, sweep: clean))
        XCTAssertFalse(
            MailService.bodyScanComplete(bodiesRead: true, candidates: 3, eligible: 3, sweep: sweep(rows: 3, total: 9)),
            "the sweep's own per-mailbox trim dropped six messages before the body pass saw them"
        )
    }

    func testAChangedMailboxSaysWhetherTheCountItReportsIsExact() throws {
        // Without a query the count is of ids that arrived in one Apple Event,
        // so a change afterwards cannot touch it. With one, the match decision
        // was made against columns that have since been shown not to line up.
        let counted = outcome(scanned: ["Alice:INBOX"], changed: ["Alice:INBOX"], filtered: false)
        XCTAssertTrue(counted.coverageNote?.contains("unaffected") == true, "\(counted.coverageNote ?? "")")

        // A search's match decision is made against the very columns that were
        // shown not to line up, so a message that matches can be passed over
        // under its neighbour's subject. Every row returned is still verified,
        // but the count is a floor -- which is what scan_complete already means.
        let searched = outcome(scanned: ["Alice:INBOX"], changed: ["Alice:INBOX"], filtered: true)
        XCTAssertFalse(searched.scanComplete, "a search's count under a changed mailbox is a floor")
        XCTAssertTrue(
            searched.coverageNote?.contains("floor") == true,
            "and it has to say so: \(searched.coverageNote ?? "")"
        )
    }
}
