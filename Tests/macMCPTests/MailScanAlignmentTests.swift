import XCTest
@testable import macmcp

/// Cover for a scan pairing one message's id with another message's subject
/// (issue #48).
///
/// A mailbox's columns are read one Apple Event at a time — `messages.id()`,
/// then `.subject()`, then `.sender()`, `.dateReceived()`, `.readStatus()` —
/// and walked in lockstep by index. Mail's collection is ordered by date
/// received, so an arriving message is spliced into the middle rather than
/// appended: everything from that index on then pairs an id with the previous
/// message's subject. Demonstrated against the live fixture by moving a message
/// into Alice's INBOX between two column fetches (`ids=9 subjects=10`, the
/// arrival landing at index 8 of 10).
///
/// The id is the handle `mail_move`, `mail_mark_read`, `mail_get_email` and
/// `mail_save_attachment` act on, so this is a caller filing or marking a
/// different message than the one they searched for.
///
/// Run through real `osascript` against a stub, because the guard is in the
/// generated JavaScript. The stub's mailbox changes between column fetches on
/// demand, which is the condition that cannot be arranged on a loopback fixture.
final class MailScanAlignmentTests: XCTestCase {
    private func scan(stub: String, query: String? = nil) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.scanScriptJXA(
            account: "Alice",
            mailbox: "INBOX",
            query: query,
            searchRecipients: false,
            limit: 10
        ))
        """)
    }

    /// Three settled messages, and a fourth that arrives at the top of the
    /// mailbox once `after` column fetches have been served.
    private func stub(arrivalAfter after: Int, repeats: Bool = false) -> String {
        """
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {
                name: 'INBOX',
                messages: [
                    {id: 1, subject: 'first', sender: 'a@b.c', date: 1000},
                    {id: 2, subject: 'second', sender: 'd@e.f', date: 2000},
                    {id: 3, subject: 'third', sender: 'g@h.i', date: 3000}
                ],
                arrival: {
                    after: \(after), at: 0, repeat: \(repeats),
                    message: {id: 'new', subject: 'just arrived', sender: 'x@y.z', date: 4000}
                }
            },
            {name: 'Archive'}
        ]}]});
        """
    }

    /// What each id's subject really is, so a misalignment is visible rather
    /// than merely counted.
    private let truth = ["1": "first", "2": "second", "3": "third"]

    private func rows(_ payload: [String: Any]) -> [[String: Any]] {
        payload["rows"] as? [[String: Any]] ?? []
    }

    // MARK: - The defect

    func testAMessageArrivingBetweenTwoColumnFetchesDoesNotShiftTheRows() throws {
        // The arrival lands after the id column has been read, so the subject
        // column that follows describes a different mailbox. Every row from
        // index 0 on would carry the wrong subject.
        let payload = try scan(stub: stub(arrivalAfter: 1))

        for row in rows(payload) {
            let id = row["id"] as? String ?? ""
            if let expected = truth[id] {
                XCTAssertEqual(row["subject"] as? String, expected, "id \(id) came back under another message's subject")
                continue
            }
            // The new message may legitimately appear -- it is in the mailbox by
            // the time the retry reads it -- but only with its own subject.
            XCTAssertEqual(row["subject"] as? String, "just arrived", "an unknown id: \(row)")
        }
        XCTAssertEqual((payload["unstable"] as? [String])?.count ?? 0, 0, "one arrival is not a reason to give up on the mailbox")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX"])
    }

    func testAMailboxThatWillNotHoldStillIsReportedRatherThanGuessedAt() throws {
        // A mailbox changing on every read: three attempts, then it is named in
        // `unstable` and contributes nothing. Reporting a mailbox as unread is a
        // smaller wrong than reporting a message under another message's id.
        let payload = try scan(stub: stub(arrivalAfter: 1, repeats: true))
        XCTAssertEqual(payload["unstable"] as? [String] ?? [], ["Alice:INBOX"])
        XCTAssertEqual(rows(payload).count, 0)
        XCTAssertFalse((payload["scanned"] as? [String] ?? []).contains("Alice:INBOX"))
        XCTAssertEqual(payload["messages_scanned"] as? Int, 0, "nothing was scanned that could be trusted")
    }

    func testASettledMailboxIsReadStraightThroughAndPairsCorrectly() throws {
        // The common case must not pay for the guard beyond the one extra id
        // column, and the rows have to be right.
        let payload = try scan(stub: stub(arrivalAfter: 99))
        let pairs = rows(payload).map { [$0["id"] as? String ?? "", $0["subject"] as? String ?? ""] }
        XCTAssertEqual(pairs, [["3", "third"], ["2", "second"], ["1", "first"]])
        XCTAssertEqual(payload["messages_scanned"] as? Int, 3)
        XCTAssertNil((payload["unstable"] as? [String])?.first)
    }

    func testAQueryMatchesTheSubjectBelongingToTheIdItReturns() throws {
        // The search path builds its haystack out of the same two columns, so a
        // shifted pairing there returns a message that does not match the query
        // under the id of one that does.
        let payload = try scan(stub: stub(arrivalAfter: 1), query: "second")
        for row in rows(payload) {
            XCTAssertEqual(row["id"] as? String, "2")
            XCTAssertEqual(row["subject"] as? String, "second")
        }
    }

    func testAnEmptyMailboxNeedsNoSecondLook() throws {
        let payload = try scan(stub: """
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [{name: 'INBOX'}, {name: 'Archive'}]}]});
        """)
        XCTAssertEqual(rows(payload).count, 0)
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX"])
        XCTAssertEqual(payload["unstable"] as? [String] ?? [], [])
    }
}
