import XCTest
@testable import macmcp

/// The body pass's budget, and the sweep it is spent out of.
///
/// `search_body` is a capped second pass: a sweep over the newest messages in
/// scope, then up to `body_scan_limit` of those messages' bodies fetched one at
/// a time. The sweep used to run at `body_scan_limit` exactly, and then every
/// row already being returned and every row that matched on subject or sender
/// was subtracted from that same set, with nothing put back.
///
/// Two consequences, both measured on the fixture. `body_scan_limit: 5` with a
/// query matching subjects returned `bodies_read: 0, body_matches: 0` — a
/// response indistinguishable from five bodies read and none matching. And a
/// body-only hit at position `body_scan_limit + 1` was unreachable at *every*
/// limit, because raising the limit widened the sweep that ate it by exactly
/// the same amount.
///
/// So the sweep is widened, and what the budget could not be spent on is
/// reported rather than absorbed.
final class MailBodyScanBudgetTests: XCTestCase {
    /// A sweep row, in the shape `scanScriptJXA` produces.
    private func row(_ id: Int, subject: String, sender: String = "someone@example.org") -> [String: Any] {
        ["id": "\(id)", "subject": subject, "sender": sender, "account": "Alice", "mailbox": "INBOX"]
    }

    // MARK: - The sweep is widened, not just filtered

    func testTheSweepAsksForMoreRowsThanTheBudgetOfBodies() throws {
        // The whole defect in one assertion: a sweep the same size as the
        // budget has nothing left in it once the metadata hits come out.
        XCTAssertGreaterThan(
            MailService.bodyScanSweepLimit(bodyScanLimit: 25, metadataMatches: 20),
            25,
            "the sweep is no wider than the number of bodies to be read, so the metadata hits eat the budget"
        )
    }

    func testTheSweepIsWidenedByAsMuchAsTheMetadataScanMatched() throws {
        // The metadata scan's total is the most rows the sweep can lose, so it
        // is what the sweep is padded by.
        XCTAssertEqual(MailService.bodyScanSweepLimit(bodyScanLimit: 25, metadataMatches: 20), 45)
        XCTAssertEqual(MailService.bodyScanSweepLimit(bodyScanLimit: 25, metadataMatches: 0), 25)
    }

    func testTheWideningIsCapped() throws {
        // A query matching thousands of subjects must not ask for thousands of
        // rows to find bodies for messages that have already matched. The cap
        // scales with what the caller asked for, over a floor that keeps a
        // small limit usable.
        XCTAssertEqual(MailService.bodyScanSweepLimit(bodyScanLimit: 200, metadataMatches: 100_000), 1000)
        XCTAssertEqual(MailService.bodyScanSweepLimit(bodyScanLimit: 5, metadataMatches: 100_000), 105)
        XCTAssertEqual(MailService.bodyScanSweepLimit(bodyScanLimit: 0, metadataMatches: 100), 0)
    }

    // MARK: - What comes out of the sweep

    func testTheBudgetIsFilledFromAWiderSweep() throws {
        // The test the seam exists for: 100 rows swept, 20 of them already
        // returned as metadata matches, 25 bodies asked for -> 25 to read.
        let metadata = (0..<20).map { row($0, subject: "Quarterly numbers \($0)") }
        let sweep = metadata + (20..<100).map { row($0, subject: "Something else \($0)") }
        let picked = MailService.bodyScanCandidates(
            sweepRows: sweep,
            metadataRows: metadata,
            query: "quarterly",
            bodyScanLimit: 25
        )
        XCTAssertEqual(picked.candidates.count, 25, "the budget of 25 bodies was not filled")
        XCTAssertEqual(picked.shortfall, 0)
        XCTAssertEqual(picked.eligible, 80)
    }

    func testARowAlreadyBeingReturnedIsNotReadAgain() throws {
        let metadata = [row(1, subject: "Quarterly numbers")]
        let picked = MailService.bodyScanCandidates(
            sweepRows: metadata + [row(2, subject: "Lunch")],
            metadataRows: metadata,
            query: "quarterly",
            bodyScanLimit: 25
        )
        XCTAssertEqual(picked.candidates.map { $0["id"] as? String }, ["2"])
    }

    func testARowThatMatchedOnItsOwnMetadataIsNotReadAgain() throws {
        // Not only the rows being returned: a match the per-mailbox trim left
        // out of `rows` was still counted in `total_matches`, and reading its
        // body would count it twice.
        let picked = MailService.bodyScanCandidates(
            sweepRows: [row(1, subject: "Quarterly numbers"), row(2, subject: "Lunch"),
                        row(3, subject: "x", sender: "quarterly@example.org")],
            metadataRows: [],
            query: "quarterly",
            bodyScanLimit: 25
        )
        XCTAssertEqual(picked.candidates.map { $0["id"] as? String }, ["2"])
    }

    // MARK: - A budget that could not be spent says so

    func testAShortfallIsReported() throws {
        // Three bodies read against twenty-five asked for is a fact about the
        // scope, and it used to be indistinguishable from twenty-five read and
        // none matching.
        let picked = MailService.bodyScanCandidates(
            sweepRows: (0..<3).map { row($0, subject: "Lunch \($0)") },
            metadataRows: [],
            query: "quarterly",
            bodyScanLimit: 25
        )
        XCTAssertEqual(picked.candidates.count, 3)
        XCTAssertEqual(picked.shortfall, 22, "the unspent budget was absorbed rather than reported")
    }

    func testNoShortfallWhenTheBudgetIsFilled() throws {
        let picked = MailService.bodyScanCandidates(
            sweepRows: (0..<40).map { row($0, subject: "Lunch \($0)") },
            metadataRows: [],
            query: "quarterly",
            bodyScanLimit: 25
        )
        XCTAssertEqual(picked.shortfall, 0)
    }

    // MARK: - A body-only hit past the budget is reachable

    func testABodyOnlyHitBehindTheMetadataMatchesIsStillPickedUp() throws {
        // The live shape: six messages whose subjects match, and behind them
        // one whose body does. At a sweep of `body_scan_limit` it is out of
        // reach at every limit, because raising the limit widens the sweep by
        // the same amount and the six stay in front of it.
        let metadata = (0..<6).map { row($0, subject: "Quarterly numbers \($0)") }
        let plain = row(99, subject: "Notes from the meeting")
        let sweepLimit = MailService.bodyScanSweepLimit(bodyScanLimit: 5, metadataMatches: 6)
        // Newest first: the six matches, then the message whose body carries
        // the query, then older mail.
        let inScope = metadata + [plain] + (100..<200).map { row($0, subject: "Older \($0)") }
        let swept = Array(inScope.prefix(sweepLimit))
        let picked = MailService.bodyScanCandidates(
            sweepRows: swept,
            metadataRows: metadata,
            query: "quarterly",
            bodyScanLimit: 5
        )
        XCTAssertTrue(
            picked.candidates.contains { $0["id"] as? String == "99" },
            "the body-only message was never a candidate, so no limit could reach it: \(picked.candidates.map { $0["id"] as? String ?? "?" })"
        )
        XCTAssertEqual(picked.candidates.count, 5, "the budget was not filled")
    }
}
