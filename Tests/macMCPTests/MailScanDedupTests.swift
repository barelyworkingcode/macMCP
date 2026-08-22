import XCTest
@testable import macmcp

/// A message filed in two mailboxes at once must survive the first of them
/// being discarded.
///
/// A scan walks the mailboxes in scope in order and keeps a `seen` set so a
/// message filed in two of them -- which is the normal shape of a Gmail
/// account, where everything in `INBOX` is also in `All Mail` -- comes back
/// once rather than twice. The ids were recorded as the rows were built, i.e.
/// *before* the alignment check decided whether this mailbox's rows could be
/// stood behind. A mailbox that was then discarded had already claimed them:
/// the counts were rolled back, the mailbox was named in `skipped_mailboxes`,
/// and the message went on to be dropped from the clean mailbox that also
/// holds it. It appeared in no row and was counted in no total, under a
/// `total_messages` that looked like an answer.
///
/// Run through real `osascript` against the stub, because the dedup is in the
/// generated JavaScript.
final class MailScanDedupTests: XCTestCase {
    /// Alice files message 7 in both mailboxes, as Gmail does. `INBOX` churns
    /// on every read, so its columns can never be paired; `All Mail` is settled.
    private let bothMailboxes = """
    var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
        {
            name: 'INBOX',
            messages: [{id: 7, subject: 'shared', sender: 'a@b.c', date: 1000}],
            mutation: {
                after: 2, removeAt: 0, insertAt: 0, repeat: true,
                message: {id: 'churn', subject: 'churn', sender: 'x@y.z', date: 4000}
            }
        },
        {name: 'All Mail', messages: [{id: 7, subject: 'shared', sender: 'a@b.c', date: 1000}]}
    ]}]});
    """

    private func scan(reverifySeconds: TimeInterval) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(bothMailboxes)
        \(MailService.scanScriptJXA(
            account: "Alice",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 10,
            reverifySeconds: reverifySeconds
        ))
        """)
    }

    private func rows(_ payload: [String: Any]) -> [[String: Any]] {
        payload["rows"] as? [[String: Any]] ?? []
    }

    func testAMessageIsNotLostBecauseAnotherMailboxHoldingItWasDiscarded() throws {
        // The budget is gone before the first row, so `INBOX` is skipped whole:
        // it contributes nothing and must therefore claim nothing. `All Mail`
        // was read without incident and holds the same message.
        let payload = try scan(reverifySeconds: -1)

        let ids = rows(payload).map { $0["id"] as? String ?? "" }
        XCTAssertEqual(ids, ["7"], "the message is in a mailbox that was read cleanly: \(payload)")
        XCTAssertEqual(rows(payload).first?["mailbox"] as? String, "All Mail")
        XCTAssertEqual(payload["total"] as? Int, 1, "a message nobody returned was still counted out of the total")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:All Mail"])
        XCTAssertEqual((payload["skipped"] as? [String])?.count, 1, "\(payload)")
    }

    func testAMessageThatLeftTheChangedMailboxIsCountedAndReturnedWhereItActuallyIs() throws {
        // The same loss by a different route, and the one the budget does not
        // reach: `INBOX` is read and kept, but its one row is let go by the
        // re-read because the message is no longer there. A mailbox that ends
        // up saying nothing about a message must not be what removes it from
        // the answer -- nor leave it counted as one of its own matches.
        let payload = try scan(reverifySeconds: 20)

        XCTAssertEqual(rows(payload).map { $0["id"] as? String ?? "" }, ["7"], "\(payload)")
        XCTAssertEqual(rows(payload).first?["mailbox"] as? String, "All Mail")
        XCTAssertEqual(payload["total"] as? Int, 1, "counted once, in the mailbox that has it")
        XCTAssertEqual(payload["dropped"] as? Int, 1)
        XCTAssertEqual(payload["changed"] as? [String] ?? [], ["Alice:INBOX"])
        XCTAssertEqual(payload["skipped"] as? [String] ?? [], [])
    }

    func testAMessageInTwoMailboxesStillComesBackOnce() throws {
        // The property `seen` exists for, which none of the above may cost:
        // both mailboxes are settled and both hold message 7, so the first to
        // be read answers for it and the second adds neither a row nor a count.
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 7, subject: 'shared', sender: 'a@b.c', date: 1000}]},
            {name: 'All Mail', messages: [{id: 7, subject: 'shared', sender: 'a@b.c', date: 1000}]}
        ]}]});
        \(MailService.scanScriptJXA(
            account: "Alice",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 10
        ))
        """)

        XCTAssertEqual(rows(payload).map { $0["id"] as? String ?? "" }, ["7"])
        XCTAssertEqual(rows(payload).first?["mailbox"] as? String, "INBOX")
        XCTAssertEqual(payload["total"] as? Int, 1)
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Alice:INBOX", "Alice:All Mail"])
    }
}
