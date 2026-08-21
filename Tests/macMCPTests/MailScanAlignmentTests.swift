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

    /// Three settled messages, and a change that lands once `after` reads of the
    /// mailbox's `messages` specifier have been served. One read is one Apple
    /// Event, and the scan makes six of them per attempt: id, subject, sender,
    /// dateReceived, readStatus, then id again.
    ///
    /// `after` therefore has to be **2**, not 1, for an arrival to shift
    /// anything. The stub applies the change before it builds the column, so at
    /// 1 the id column already contains the new message and every later column
    /// agrees with it -- there is no misalignment to catch, and the tests that
    /// used to pass 1 could not fail for the property they named. A sweep of the
    /// stub confirms it: 1 -> 0 mispairs, 2 -> 3, 3 through 6 -> 0.
    private func stub(arrivalAfter after: Int, repeats: Bool = false) -> String {
        stub(change: """
            arrival: {
                after: \(after), at: 0, repeat: \(repeats),
                message: {id: 'new', subject: 'just arrived', sender: 'x@y.z', date: 4000}
            }
        """)
    }

    /// The same three messages, and a change that takes one out as it puts
    /// another in.
    ///
    /// This is the shape an arrival cannot produce: the collection is three
    /// messages long before and after, so every column comes back the same
    /// length and `sameLength` sees nothing. Only re-reading the id column and
    /// requiring it to come back identical catches it -- which is the half of
    /// the #48 fix that arrivals leave untested.
    private func stub(mutationAfter after: Int, repeats: Bool = false) -> String {
        stub(change: """
            mutation: {
                after: \(after), removeAt: 0, insertAt: 0, repeat: \(repeats),
                message: {id: 'new', subject: 'just arrived', sender: 'x@y.z', date: 4000}
            }
        """)
    }

    /// A message that arrives between two columns and is filed away again
    /// before the id column is re-read.
    ///
    /// The id column comes back identical, so `unchanged` sees nothing; the four
    /// columns read while the message was there are one longer than the two id
    /// columns either side of them, which is what `sameLength` is for.
    private func stubTransientArrival() -> String {
        stub(change: """
            arrival: {
                after: 2, at: 0, repeat: false,
                message: {id: 'new', subject: 'just arrived', sender: 'x@y.z', date: 4000}
            },
            departure: {after: 6, at: 0, repeat: false}
        """)
    }

    private func stub(change: String) -> String {
        """
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {
                name: 'INBOX',
                messages: [
                    {id: 1, subject: 'first', sender: 'a@b.c', date: 1000},
                    {id: 2, subject: 'second', sender: 'd@e.f', date: 2000},
                    {id: 3, subject: 'third', sender: 'g@h.i', date: 3000}
                ],
        \(change)
            },
            {name: 'Archive'}
        ]}]});
        """
    }

    /// What each id's subject really is, so a misalignment is visible rather
    /// than merely counted. Ids the stub invents for a message it splices in
    /// carry the read count, so they never collide with these.
    private let truth = ["1": "first", "2": "second", "3": "third"]

    /// Every row's id paired with the subject it came back under, checked
    /// against `truth`. A spliced-in message may legitimately appear -- it is in
    /// the mailbox by the time a retry reads it -- but only under its own
    /// subject.
    private func assertEveryRowCarriesItsOwnSubject(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in rows(payload) {
            let id = row["id"] as? String ?? ""
            let subject = row["subject"] as? String ?? ""
            if let expected = truth[id] {
                XCTAssertEqual(subject, expected, "id \(id) came back under another message's subject", file: file, line: line)
            } else {
                XCTAssertEqual(subject, "just arrived", "an unknown id: \(row)", file: file, line: line)
            }
        }
    }

    private func rows(_ payload: [String: Any]) -> [[String: Any]] {
        payload["rows"] as? [[String: Any]] ?? []
    }

    // MARK: - The defect

    func testAMessageArrivingBetweenTwoColumnFetchesDoesNotShiftTheRows() throws {
        // The arrival lands after the id column has been read, so the subject
        // column that follows describes a different mailbox. Every row from
        // index 0 on would carry the wrong subject. Removing `sameLength` from
        // the guard makes this fail with id 1 under "just arrived".
        let payload = try scan(stub: stub(arrivalAfter: 2))

        assertEveryRowCarriesItsOwnSubject(payload)
        XCTAssertEqual((payload["unstable"] as? [String])?.count ?? 0, 0, "one arrival is not a reason to give up on the mailbox")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX"])
    }

    func testAMessageLeavingAsAnotherArrivesIsCaughtThoughEveryColumnIsTheSameLength() throws {
        // The change an arrival cannot model. Three messages before, three
        // after, so every column comes back three long and counting them proves
        // nothing -- but the mailbox the subject column describes is not the one
        // the id column did. Only the re-read of the id column can tell.
        //
        // Removing `unchanged(ids, mb.messages.id())` makes this fail with id 1
        // under "just arrived"; removing `sameLength` leaves it passing, which
        // is why it is a separate test rather than another assertion above.
        let payload = try scan(stub: stub(mutationAfter: 2))

        assertEveryRowCarriesItsOwnSubject(payload)
        XCTAssertFalse(
            rows(payload).contains { $0["id"] as? String == "1" },
            "id 1 left the mailbox before the subject column was read; it cannot be in the result"
        )
        XCTAssertEqual((payload["unstable"] as? [String])?.count ?? 0, 0, "one change is not a reason to give up on the mailbox")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX"])
    }

    func testAMessageThatArrivesAndLeavesAgainBeforeTheIdColumnIsRereadIsCaughtByTheColumnLengths() throws {
        // The arrival is gone by the time the id column is read the second time,
        // so `unchanged` compares two identical columns and is satisfied -- while
        // the subject, sender, date and read columns in between were all read
        // from a four-message mailbox. Removing `sameLength` makes this fail with
        // id 1 under "just arrived"; removing `unchanged` leaves it passing.
        let payload = try scan(stub: stubTransientArrival())

        assertEveryRowCarriesItsOwnSubject(payload)
        XCTAssertEqual((payload["unstable"] as? [String])?.count ?? 0, 0, "one arrival is not a reason to give up on the mailbox")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX"])
    }

    func testAMailboxMutatingOnEveryReadIsReportedRatherThanGuessedAt() throws {
        // Same-length churn on every read: no column count ever disagrees, so
        // this is `unchanged` alone standing between the caller and a row that
        // pairs one message's id with another's subject.
        let payload = try scan(stub: stub(mutationAfter: 2, repeats: true))
        XCTAssertEqual(payload["unstable"] as? [String] ?? [], ["Alice:INBOX"])
        XCTAssertEqual(rows(payload).count, 0)
        XCTAssertEqual(payload["messages_scanned"] as? Int, 0, "nothing was scanned that could be trusted")
    }

    func testAMailboxThatWillNotHoldStillIsReportedRatherThanGuessedAt() throws {
        // A mailbox changing on every read: three attempts, then it is named in
        // `unstable` and contributes nothing. Reporting a mailbox as unread is a
        // smaller wrong than reporting a message under another message's id.
        let payload = try scan(stub: stub(arrivalAfter: 2, repeats: true))
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
        let payload = try scan(stub: stub(arrivalAfter: 2), query: "second")
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
