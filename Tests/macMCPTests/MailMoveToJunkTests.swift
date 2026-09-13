import XCTest
@testable import macmcp

/// `mail_move_to_junk` is deliberately narrower than `mail_move`: the
/// destination is always the found account's own root-level `Junk` mailbox,
/// never a caller-supplied string, and it is resolved without regard to
/// `mail_mailboxes` -- that field bounds where a client may read and write,
/// and requiring Junk in it would hand a read-only triage profile a write
/// grant it never asked for. These run the generated script itself, with
/// `mail` bound to a stub, for the same reason `MailMoveTests` does: which
/// mailbox object gets picked is not visible from Swift.
final class MailMoveToJunkTests: XCTestCase {
    private static let aliceWithJunk = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'alice-inbox-1@relaytest.local'}]},
            {name: 'Archive', messages: []},
            {name: 'Junk', messages: []}
        ]},
        {name: 'Bob', mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'bob-inbox-1@relaytest.local'}]},
            {name: 'Junk', messages: []}
        ]}
    ]});
    """

    private static let aliceWithoutJunk = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'alice-inbox-1@relaytest.local'}]},
            {name: 'Archive', messages: []}
        ]}
    ]});
    """

    private func moveToJunk(
        mailbox stub: String,
        messageId: String,
        sourceMailbox: String = "INBOX",
        account: String? = nil,
        scopeMailboxes: [String]? = nil
    ) throws -> (result: [String: Any], moves: [[String: Any]]) {
        let script = """
        \(MailStubJS.source)
        \(stub)
        \(MailService.moveToJunkScriptJXA(
            messageId: messageId,
            sourceMailbox: sourceMailbox,
            account: account,
            scopeMailboxes: scopeMailboxes
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), moves: mail.log.moves});
        """
        let payload = try JXA.runJSON(script)
        return (
            payload["result"] as? [String: Any] ?? [:],
            payload["moves"] as? [[String: Any]] ?? []
        )
    }

    func testMovesToTheFoundAccountsOwnJunkMailbox() throws {
        let (result, moves) = try moveToJunk(mailbox: Self.aliceWithJunk, messageId: "100")
        XCTAssertEqual(result["status"] as? String, "moved")
        XCTAssertEqual(result["account"] as? String, "Alice")
        XCTAssertEqual(result["mailbox"] as? String, "Junk")
        XCTAssertEqual(result["cross_account"] as? Bool, false)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual((moves[0]["to"] as? [String: Any])?["account"] as? String, "Alice")
    }

    func testNeverCrossesAnAccountBoundaryEvenWhenAnotherAccountIsListedFirst() throws {
        // Bob's message must land in Bob's own Junk, never Alice's, and there
        // is no target_account argument to get this wrong with.
        let (result, _) = try moveToJunk(mailbox: Self.aliceWithJunk, messageId: "200")
        XCTAssertEqual(result["account"] as? String, "Bob")
        XCTAssertEqual(result["mailbox"] as? String, "Junk")
    }

    func testResolvesJunkRegardlessOfMailMailboxesScope() throws {
        // The security-relevant case: a triage profile scoped to read INBOX
        // only (Junk is NOT in mail_mailboxes) must still be able to move a
        // message there. Requiring Junk in that field would grant write
        // access to every other mailbox the field also names.
        let (result, _) = try moveToJunk(
            mailbox: Self.aliceWithJunk,
            messageId: "100",
            scopeMailboxes: ["INBOX"]
        )
        XCTAssertEqual(result["status"] as? String, "moved")
        XCTAssertEqual(result["mailbox"] as? String, "Junk")
    }

    func testSourceMailboxMustStillBeInScope() throws {
        // The source end is not exempt: a client scoped to Archive only
        // cannot pull a message out of an INBOX it may not read, even to
        // move it to Junk.
        let (result, moves) = try moveToJunk(
            mailbox: Self.aliceWithJunk,
            messageId: "100",
            scopeMailboxes: ["Archive"]
        )
        XCTAssertNil(result["status"])
        let error = result["error"] as? String ?? ""
        XCTAssertTrue(error.contains(MailScopeRefusal.sentinel), "expected a scope refusal, got: \(error)")
        XCTAssertTrue(moves.isEmpty)
    }

    func testAnAccountWithNoJunkMailboxIsRefusedRatherThanFallingBackToTrash() throws {
        XCTAssertThrowsError(try moveToJunk(mailbox: Self.aliceWithoutJunk, messageId: "100")) { error in
            let reported = MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? "") ?? ""
            XCTAssertTrue(reported.contains("no mailbox named \"Junk\""), "got: \(reported)")
        }
    }

    func testMissingMessageReportsNotFoundWithoutTouchingAnyMailbox() throws {
        let (result, moves) = try moveToJunk(mailbox: Self.aliceWithJunk, messageId: "99999999")
        XCTAssertEqual(result["error"] as? String, "message not found with id: 99999999")
        XCTAssertTrue(moves.isEmpty)
    }
}
