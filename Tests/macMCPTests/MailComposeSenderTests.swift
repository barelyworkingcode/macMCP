import XCTest
@testable import macmcp

/// Cover for the identity a message goes out as.
///
/// `mail_send` used to hand `from` straight to `msg.sender` with no check.
/// Mail does not reject an address no account owns — it sends from the default
/// account instead — so a send asking to go out as `nosuch@relaytest.local`
/// returned `{"status": "sent"}` and left as
/// `From: Alice Tester <alice@relaytest.local>`, Return-Path `alice@`, filed in
/// Alice's Sent. A caller asking to send as one identity sent as another, with
/// nothing in the response saying so and the message already gone. The
/// pre-send guard could not catch it either: it read back the recipients and
/// the subject and never the sender.
///
/// Two independent things are pinned here, because either alone leaves the
/// hole open:
///
/// * `senderJXA` refuses an unowned address **before** `mail.OutgoingMessage`
///   exists, so a rejected sender composes nothing at all — no message, and
///   therefore no draft for Mail to autosave.
/// * `preSendGuardJXA` reads `msg.sender()` back off the message and aborts on
///   a mismatch, exactly as it does for a recipient. Validating up front is
///   the request; reading back is the evidence.
///
/// The tests run the generated JavaScript, because which of the two the
/// request survives is not visible from Swift. The message stub is
/// hand-rolled here rather than added to `MailStubJS`: `OutgoingMessage` is
/// the one part of Mail's graph the shared stub does not model, and this is
/// the only suite that needs it.
final class MailComposeSenderTests: XCTestCase {
    /// Two accounts, four addresses between them, matching the fixture plus an
    /// alias so that "an account can send as more than one address" is covered.
    private static let accounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', emailAddresses: ['alice@relaytest.local', 'a.tester@relaytest.local'], mailboxes: [
            {name: 'Drafts'}
        ]},
        {name: 'Bob', emailAddresses: ['bob@relaytest.local'], mailboxes: [
            {name: 'Drafts'}
        ]}
    ]});
    """

    /// A stand-in for the message Mail is composing. `sender` is settable and
    /// readable, as Mail's is, and `answersSender` is what Mail will *report*
    /// however it was set — which is the whole point: a sender that does not
    /// take is indistinguishable from one that did until it is read back.
    private static func outgoing(
        answersSender: String,
        to: [String] = ["bob@relaytest.local"],
        subject: String = "Quarterly numbers"
    ) -> String {
        let recipients = to.map { "{address: function() { return '\($0)'; }}" }.joined(separator: ", ")
        return """
        var sent = [];
        var closed = [];
        var msg = {
            _sender: null,
            sender: function() { return '\(answersSender)'; },
            subject: function() { return '\(subject)'; },
            toRecipients: function() { return [\(recipients)]; },
            ccRecipients: function() { return []; },
            bccRecipients: function() { return []; },
            send: function() { sent.push(true); },
            close: function() { closed.push(true); }
        };
        """
    }

    private func runSender(from: String?, account: String?) throws -> [String: Any] {
        let snippet = MailService.senderJXA(from: from, account: account)
        return try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.accounts)
        var out = {};
        try {
            \(snippet.lines)
            out.senderAddr = senderAddr;
        } catch (e) {
            out.threw = '' + e;
        }
        JSON.stringify(out);
        """)
    }

    private func runGuard(
        answersSender: String,
        from: String?,
        account: String?,
        to: [String] = ["bob@relaytest.local"],
        expectTo: [String] = ["bob@relaytest.local"],
        subject: String = "Quarterly numbers",
        expectSubject: String = "Quarterly numbers"
    ) throws -> [String: Any] {
        // `senderAddr` is what `senderJXA` would have left in scope for the
        // `account` form; the guard reads it to know what to expect.
        let senderAddr = account == nil ? "null" : "'alice@relaytest.local'"
        return try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.accounts)
        \(Self.outgoing(answersSender: answersSender, to: to, subject: subject))
        var senderAddr = \(senderAddr);
        var out = {};
        try {
            \(MailService.preSendGuardJXA(
                to: expectTo, cc: [], bcc: [], subject: expectSubject,
                from: from, account: account
            ))
            msg.send();
            out.passed = true;
        } catch (e) {
            out.threw = '' + e;
        }
        out.sent = sent.length;
        out.closed = closed.length;
        JSON.stringify(out);
        """)
    }

    // MARK: - The defect: a `from` no account owns

    func testAFromNoAccountOwnsIsRefusedBeforeAnythingIsComposed() throws {
        let out = try runSender(from: "nosuch@relaytest.local", account: nil)
        let threw = try XCTUnwrap(
            out["threw"] as? String,
            "the sender was accepted, so Mail would have sent this from its default account instead"
        )
        XCTAssertTrue(threw.contains("nosuch@relaytest.local"), threw)
        XCTAssertNil(out["senderAddr"], "nothing should have been resolved")
    }

    func testTheRefusalNamesTheAddressesThatWouldHaveWorked() throws {
        // A caller who guessed wrong can only fix it if the answer is in the
        // refusal; "not found" on its own sends them back to guessing.
        let threw = try XCTUnwrap(runSender(from: "nosuch@relaytest.local", account: nil)["threw"] as? String)
        XCTAssertTrue(threw.contains("alice@relaytest.local"), threw)
        XCTAssertTrue(threw.contains("bob@relaytest.local"), threw)
    }

    func testAnAliasOfAnAccountIsAccepted() throws {
        // `emailAddresses` is every address an account can send as, so an
        // alias must not be refused as if it belonged to nobody.
        let out = try runSender(from: "a.tester@relaytest.local", account: nil)
        XCTAssertNil(out["threw"] as? String)
        XCTAssertEqual(out["senderAddr"] as? String, "a.tester@relaytest.local")
    }

    func testADisplayNameIsMatchedOnTheAddressAndPassedThroughWhole() throws {
        // Mail wants `Name <addr>`, so the whole string is what gets assigned;
        // the address is what gets checked.
        let out = try runSender(from: "Alice Tester <alice@relaytest.local>", account: nil)
        XCTAssertNil(out["threw"] as? String)
        XCTAssertEqual(out["senderAddr"] as? String, "Alice Tester <alice@relaytest.local>")
    }

    func testTheCaseOfTheAddressDoesNotDecideWhetherItIsRefused() throws {
        let out = try runSender(from: "ALICE@RelayTest.Local", account: nil)
        XCTAssertNil(out["threw"] as? String, "an address differing only in case is the same address")
    }

    // MARK: - The defect: the guard never looked at the sender

    func testTheGuardRefusesWhenMailWouldSendFromSomebodyElse() throws {
        // The message asks to go out as Bob and Mail answers Alice — which is
        // exactly what Mail does with an unowned sender, and what used to
        // reach the recipient as `{"status": "sent"}`.
        let out = try runGuard(
            answersSender: "Alice Tester <alice@relaytest.local>",
            from: "bob@relaytest.local",
            account: nil
        )
        let threw = try XCTUnwrap(out["threw"] as? String, "the guard let a message through addressed from the wrong identity")
        XCTAssertTrue(threw.contains("alice@relaytest.local"), threw)
        XCTAssertTrue(threw.contains("bob@relaytest.local"), threw)
        XCTAssertEqual(out["sent"] as? Int, 0, "the message was sent anyway")
        XCTAssertEqual(out["closed"] as? Int, 1, "the compose message was left open")
    }

    func testTheGuardChecksTheSenderResolvedFromAnAccountToo() throws {
        // The `account` form resolves to an address at run time; the guard
        // reads that back the same way.
        let out = try runGuard(
            answersSender: "bob@relaytest.local",
            from: nil,
            account: "Alice"
        )
        let threw = try XCTUnwrap(out["threw"] as? String, "a message composed for Alice would have gone out as Bob")
        XCTAssertTrue(threw.contains("bob@relaytest.local"), threw)
        XCTAssertEqual(out["sent"] as? Int, 0)
    }

    func testAMessageThatMatchesTheRequestedSenderGoesThrough() throws {
        let out = try runGuard(
            answersSender: "Bob <bob@relaytest.local>",
            from: "bob@relaytest.local",
            account: nil
        )
        XCTAssertNil(out["threw"] as? String)
        XCTAssertEqual(out["sent"] as? Int, 1)
    }

    func testNamingNoSenderLeavesNothingToCheck() throws {
        // Mail's default account is a correct answer to a request that
        // expressed no preference, so this must not become a new refusal.
        let out = try runGuard(answersSender: "alice@relaytest.local", from: nil, account: nil)
        XCTAssertNil(out["threw"] as? String)
        XCTAssertEqual(out["sent"] as? Int, 1)
    }

    // MARK: - The abort names the field that differed

    func testASubjectMismatchIsReportedAsASubjectMismatch() throws {
        // Mail normalises a CR in a subject to a space, which trips the guard
        // correctly. The abort used to render the two recipient lists whatever
        // the mismatch was, so this came out as two *identical* recipient
        // lists printed side by side — reading like a recipient-tampering
        // alarm, the scariest false positive this guard can raise.
        let out = try runGuard(
            answersSender: "alice@relaytest.local",
            from: nil,
            account: nil,
            subject: "Quarterly numbers second line",
            expectSubject: "Quarterly numbers\rsecond line"
        )
        let threw = try XCTUnwrap(out["threw"] as? String)
        XCTAssertTrue(threw.contains("subject"), threw)
        XCTAssertFalse(
            threw.contains("addressed to"),
            "the recipients matched exactly, so nothing should have been said about them: \(threw)"
        )
        XCTAssertEqual(out["sent"] as? Int, 0)
    }

    func testARecipientMismatchIsStillReportedAsARecipientMismatch() throws {
        let out = try runGuard(
            answersSender: "alice@relaytest.local",
            from: nil,
            account: nil,
            to: ["stranger@relaytest.local"],
            expectTo: ["bob@relaytest.local"]
        )
        let threw = try XCTUnwrap(out["threw"] as? String)
        XCTAssertTrue(threw.contains("addressed to"), threw)
        XCTAssertTrue(threw.contains("stranger@relaytest.local"), threw)
        XCTAssertFalse(threw.contains("subject as"), "the subject matched: \(threw)")
        XCTAssertEqual(out["sent"] as? Int, 0)
    }

    func testEveryFieldThatDifferedIsNamed() throws {
        // Two things wrong at once must not hide one behind the other.
        let out = try runGuard(
            answersSender: "alice@relaytest.local",
            from: "bob@relaytest.local",
            account: nil,
            to: ["stranger@relaytest.local"],
            expectTo: ["bob@relaytest.local"],
            subject: "changed",
            expectSubject: "Quarterly numbers"
        )
        let threw = try XCTUnwrap(out["threw"] as? String)
        XCTAssertTrue(threw.contains("addressed to"), threw)
        XCTAssertTrue(threw.contains("subject as"), threw)
        XCTAssertTrue(threw.contains("send it from"), threw)
    }

    // MARK: - Control

    func testAnAccountThatDoesNotExistIsStillRefused() throws {
        let out = try runSender(from: nil, account: "Nope")
        XCTAssertTrue((out["threw"] as? String ?? "").contains("account not found"), "\(out)")
    }
}
