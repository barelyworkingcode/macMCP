import XCTest
@testable import macmcp

/// Regression cover for the cross-account leak in `mail_move` (issue #4).
///
/// With `account` omitted, `target_mailbox` used to be resolved by name across
/// every account, so a message in Bob's INBOX was moved into *Alice's* Archive
/// and the source copy was removed. These run the generated script itself, with
/// `mail` bound to a two-account stub, because which mailbox object the script
/// picks is not something Swift can be asked about.
final class MailMoveTests: XCTestCase {
    /// Alice first, Bob second — the ordering in the issue. Both accounts own an
    /// `Archive`, which is the normal case and the reason the bug bites.
    private static let aliceFirst = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'alice-inbox@relaytest.local'}]},
            {name: 'Archive', messages: [{id: 201, messageId: 'alice-archive@relaytest.local'}]}
        ]},
        {name: 'Bob', mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local'}]},
            {name: 'Archive', messages: [{id: 101, messageId: 'bob-archive@relaytest.local'}]},
            {name: 'Receipts', messages: []}
        ]}
    ]});
    """

    /// The same two accounts with Bob listed first, to prove the fix is not just
    /// "always pick the second account".
    private static let bobFirst = """
    var mail = makeMail({accounts: [
        {name: 'Bob', mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local'}]},
            {name: 'Archive', messages: [{id: 101, messageId: 'bob-archive@relaytest.local'}]}
        ]},
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'alice-inbox@relaytest.local'}]},
            {name: 'Archive', messages: [{id: 201, messageId: 'alice-archive@relaytest.local'}]}
        ]}
    ]});
    """

    private func move(
        mailbox stub: String,
        messageId: String,
        targetMailbox: String = "Archive",
        sourceMailbox: String = "INBOX",
        account: String? = nil,
        targetAccount: String? = nil
    ) throws -> (result: [String: Any], moves: [[String: Any]]) {
        let script = """
        \(MailStubJS.source)
        \(stub)
        \(MailService.moveScriptJXA(
            messageId: messageId,
            sourceMailbox: sourceMailbox,
            targetMailbox: targetMailbox,
            account: account,
            targetAccount: targetAccount
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), moves: mail.log.moves});
        """
        let payload = try JXA.runJSON(script)
        return (
            payload["result"] as? [String: Any] ?? [:],
            payload["moves"] as? [[String: Any]] ?? []
        )
    }

    // MARK: - The reported defect

    func testMessageInBobsInboxGoesToBobsArchiveWhenAccountOmitted() throws {
        let (result, moves) = try move(mailbox: Self.aliceFirst, messageId: "100")
        XCTAssertEqual(result["account"] as? String, "Bob", "destination resolved in the wrong account")
        XCTAssertEqual(result["mailbox"] as? String, "Archive")
        XCTAssertEqual(result["cross_account"] as? Bool, false)
        XCTAssertEqual(moves.count, 1)
        let to = moves[0]["to"] as? [String: Any]
        XCTAssertEqual(to?["account"] as? String, "Bob")
    }

    func testMessageInAlicesInboxGoesToAlicesArchiveWhenAccountOmitted() throws {
        // Same call shape with the account order reversed. Before the fix both
        // of these landed in whichever account Mail listed first.
        let (result, moves) = try move(mailbox: Self.bobFirst, messageId: "200")
        XCTAssertEqual(result["account"] as? String, "Alice")
        let to = moves[0]["to"] as? [String: Any]
        XCTAssertEqual(to?["account"] as? String, "Alice")
    }

    func testTargetNameOwnedByOnlyOneAccountIsNotBorrowedFromIt() throws {
        // "Receipts" exists in Bob's account only. Moving one of Alice's
        // messages there must fail loudly rather than quietly file it in Bob's.
        //
        // This asserts the *sentence the caller is handed*, not two substrings
        // of it. The earlier version accepted anything containing "Alice" and
        // "Receipts", which the raw
        //   execution error: Error: Error: account "Alice" has no mailbox named "Receipts" (-2700)
        // satisfies -- so it passed on precisely the output that was wrong
        // (#19), and pinned nothing about the shape #10 was filed over.
        //
        // The script still throws; that is the natural thing to do from inside
        // an IIFE, and `runJXAData` translates a throw into prose for every
        // script rather than each one wrapping itself. What the harness gets is
        // therefore osascript's stderr, and putting it through the same
        // `scriptErrorMessage` the tool uses is what the caller would see.
        XCTAssertThrowsError(
            try move(mailbox: Self.aliceFirst, messageId: "200", targetMailbox: "Receipts")
        ) { error in
            guard let failure = error as? JXA.Failure else {
                return XCTFail("expected osascript to fail, got \(error)")
            }
            guard let reported = MailService.scriptErrorMessage(failure.stderr) else {
                return XCTFail("osascript's wrapper was not recognised: \(failure.stderr)")
            }
            XCTAssertEqual(
                reported,
                #"account "Alice" has no mailbox named "Receipts"; it has: INBOX, Archive"#
            )
            for leak in ["execution error", "Error: Error", "-2700", "(-"] {
                XCTAssertFalse(reported.contains(leak), "raw osascript error leaked: \(reported)")
            }
        }
    }

    func testMissingMailboxNamesTheMailboxesTheAccountActuallyHas() throws {
        // The list is the actionable part: "no mailbox named X" alone leaves a
        // caller guessing at spelling, at localisation, and at which account
        // owns the folder they meant.
        XCTAssertThrowsError(
            try move(mailbox: Self.bobFirst, messageId: "100", targetMailbox: "Receipts")
        ) { error in
            let reported = MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? "") ?? ""
            XCTAssertEqual(
                reported,
                #"account "Bob" has no mailbox named "Receipts"; it has: INBOX, Archive"#
            )
        }
    }

    func testAnUnknownAccountIsReportedAsProseFromEitherEnd() throws {
        // `account not found` is thrown from two different places -- the search
        // scope (`collectBoxesJXA`, shared with mail_get_email, mail_get_source
        // and mail_mark_read) and the destination lookup -- and both used to
        // reach the caller as `execution error: Error: Error: … (-2700)`.
        for target in [("account", "Zed"), ("target_account", "Zed")] {
            XCTAssertThrowsError(
                try move(
                    mailbox: Self.aliceFirst,
                    messageId: "100",
                    account: target.0 == "account" ? target.1 : nil,
                    targetAccount: target.0 == "target_account" ? target.1 : nil
                )
            ) { error in
                let reported = MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? "")
                XCTAssertEqual(reported, "account not found: Zed", "from \(target.0)")
            }
        }
    }

    // MARK: - Destination reporting and read-back

    func testResultNamesTheDestinationAndConfirmsItByReadingBack() throws {
        let (result, _) = try move(mailbox: Self.aliceFirst, messageId: "100")
        XCTAssertEqual(result["status"] as? String, "moved")
        XCTAssertEqual(result["verified"] as? Bool, true, "the message was not found in its destination")
        let from = result["moved_from"] as? [String: Any]
        XCTAssertEqual(from?["account"] as? String, "Bob")
        XCTAssertEqual(from?["mailbox"] as? String, "INBOX")
    }

    // MARK: - Deliberate cross-account moves, and the control that already worked

    func testTargetAccountMakesACrossAccountMoveExplicit() throws {
        let (result, moves) = try move(
            mailbox: Self.aliceFirst,
            messageId: "100",
            targetAccount: "Alice"
        )
        XCTAssertEqual(result["account"] as? String, "Alice")
        XCTAssertEqual(result["cross_account"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual((moves[0]["to"] as? [String: Any])?["account"] as? String, "Alice")
    }

    func testExplicitAccountStillResolvesInsideThatAccount() throws {
        // The control case from the issue, which passed before and must keep
        // passing: naming the account scopes both the search and the target.
        let (result, _) = try move(mailbox: Self.aliceFirst, messageId: "100", account: "Bob")
        XCTAssertEqual(result["account"] as? String, "Bob")
        XCTAssertEqual(result["cross_account"] as? Bool, false)
    }

    func testMissingMessageReportsNotFoundWithoutTouchingAnyMailbox() throws {
        let (result, moves) = try move(mailbox: Self.aliceFirst, messageId: "99999999")
        XCTAssertEqual(result["error"] as? String, "message not found with id: 99999999")
        XCTAssertTrue(moves.isEmpty, "nothing should have been moved")
    }
}
