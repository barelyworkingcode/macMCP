import Foundation
import XCTest
@testable import macmcp

/// What the resource scope actually *does*, at the five seams ADR-011 names.
///
/// `MailScopeTests` covers the representation and the Swift-side
/// reconciliation rule. This covers the half that lives in generated
/// JavaScript, where most of what `MailService` does happens, by running the
/// real generated scripts against `MailStubJS` — two accounts, so the
/// interesting negative (Alice's INBOX against Bob's INBOX, which have the
/// same leaf name) is expressible.
///
/// **The negatives are the point.** A scope that admits what it should admit
/// and also everything else passes every positive test there is.
final class MailScopeEnforcementTests: XCTestCase {
    /// Two accounts, both with an `INBOX` and an `Archive`, plus a nested
    /// `Projects/Archive` for Bob so a leaf name is not enough to identify a
    /// mailbox and the tests can say so.
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', emailAddresses: ['alice@relaytest.local', 'a.tester@relaytest.local'], mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'alice-inbox@relaytest.local', subject: 'Alice one', date: 3000}]},
            {name: 'Archive', messages: [{id: 201, messageId: 'alice-archive@relaytest.local', subject: 'Alice two', date: 2000}]},
            {name: 'Trash', messages: [{id: 202, messageId: 'alice-trash@relaytest.local', subject: 'Alice three', date: 1000}]}
        ]},
        {name: 'Bob', emailAddresses: ['bob@relaytest.local'], mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local', subject: 'Bob one', date: 3500}]},
            {name: 'Archive', messages: [{id: 101, messageId: 'bob-archive@relaytest.local', subject: 'Bob two', date: 2500}]},
            {name: 'Projects'},
            {name: 'Archive', container: 'Projects', messages: [{id: 102, messageId: 'bob-nested@relaytest.local', subject: 'Bob nested', date: 1500}]}
        ]}
    ]});
    """

    // MARK: - Seam 2: the scan reads only mailboxes in scope

    private func scan(
        account: String,
        mailbox: String,
        scopeMailboxes: [String]?
    ) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.scanScriptJXA(
            account: account,
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeMailboxes: scopeMailboxes
        ))
        """)
    }

    private func mailboxesIn(_ payload: [String: Any]) -> [String] {
        (payload["rows"] as? [[String: Any]] ?? []).compactMap { $0["mailbox"] as? String }
    }

    func testAnUnscopedScanStillReadsEverything() throws {
        // The control. Every call macMCP has ever served over a bare stdio
        // pipe is this one, and it must not have changed.
        let payload = try scan(account: "Bob", mailbox: "all", scopeMailboxes: nil)
        XCTAssertEqual(Set(mailboxesIn(payload)), ["INBOX", "Archive", "Projects/Archive"])
    }

    func testAScopedAllReadsOnlyTheMailboxesInScope() throws {
        // `mailbox: "all"` means "everything I am allowed to see" and resolves
        // to the scope. It does not error, and it does not read Archive.
        let payload = try scan(account: "Bob", mailbox: "all", scopeMailboxes: ["INBOX"])
        XCTAssertEqual(mailboxesIn(payload), ["INBOX"])
        XCTAssertEqual(payload["total"] as? Int, 1)
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:INBOX"])
    }

    func testAMailboxOutOfScopeIsNotEvenScanned() throws {
        // Not "filtered out of the rows": `scanned` is the list of mailboxes
        // whose columns were actually fetched, so this is the assertion that
        // the confinement happened before a single subject was read rather
        // than after.
        let payload = try scan(account: "Bob", mailbox: "all", scopeMailboxes: ["Archive"])
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Archive"])
        XCTAssertEqual(payload["messages_scanned"] as? Int, 1)
    }

    func testTheScopeIsAPathAndNotALeafName() throws {
        // Bob holds two mailboxes whose leaf name is `Archive`. A scope naming
        // the nested one must reach the nested one and nothing else — matching
        // on the leaf name would have returned both, and `Projects/Archive`
        // sorted before the top-level one in Mail's own enumeration, so "the
        // first match" would have been wrong in both directions.
        let nested = try scan(account: "Bob", mailbox: "all", scopeMailboxes: ["Projects/Archive"])
        XCTAssertEqual(nested["scanned"] as? [String] ?? [], ["Bob:Projects/Archive"])
        XCTAssertEqual((nested["rows"] as? [[String: Any]])?.first?["id"] as? String, "102")

        let top = try scan(account: "Bob", mailbox: "all", scopeMailboxes: ["Archive"])
        XCTAssertEqual(top["scanned"] as? [String] ?? [], ["Bob:Archive"])
        XCTAssertEqual((top["rows"] as? [[String: Any]])?.first?["id"] as? String, "101")
    }

    func testANamedMailboxResolvesInsideTheScopeRatherThanAroundIt() throws {
        // The two rules compose in this order: the scope narrows the mailbox
        // list, and then the caller's own name is resolved against what is
        // left. So within a scope of `Projects/Archive`, the leaf name
        // `Archive` reaches the one mailbox this client may read — and never
        // the top-level `Archive`, which resolving first would have picked.
        let payload = try scan(account: "Bob", mailbox: "Archive", scopeMailboxes: ["Projects/Archive"])
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Projects/Archive"])
    }

    func testANamedMailboxOutOfScopeReadsNothing() throws {
        // The Swift side refuses this before the script runs (see
        // MailScopeTests); if it ever did not, the script must still not read
        // the mailbox.
        let payload = try scan(account: "Bob", mailbox: "INBOX", scopeMailboxes: ["Archive"])
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], [])
        XCTAssertEqual((payload["rows"] as? [[String: Any]] ?? []).count, 0)
    }

    func testAScopedAllDoesNotSubtractTrashFromTheOperatorsEnumeration() throws {
        // Unscoped, `all` excludes the account's own Trash/Junk/Drafts/Outbox.
        // Scoped, `all` is exactly the scope: a profile that names Trash was
        // given it deliberately, since there is no other way to express it,
        // and subtracting it would overrule the enumeration an operator typed.
        let unscoped = try scan(account: "Alice", mailbox: "all", scopeMailboxes: nil)
        XCTAssertFalse(mailboxesIn(unscoped).contains("Trash"))
        XCTAssertEqual(unscoped["excluded"] as? [String] ?? [], ["Alice:Trash"])

        let scoped = try scan(account: "Alice", mailbox: "all", scopeMailboxes: ["Trash"])
        XCTAssertEqual(mailboxesIn(scoped), ["Trash"])
        XCTAssertEqual(scoped["excluded"] as? [String] ?? [], [])
    }

    // MARK: - Seam 3: findMessageJXA checks where the message really is

    private func find(
        messageId: String,
        account: String? = nil,
        mailbox: String = "INBOX",
        scopeAccounts: [String]?,
        scopeMailboxes: [String]?
    ) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.findMessageJXA(
            account: account,
            mailbox: mailbox,
            messageId: messageId,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes
        ))
        JSON.stringify({
            bound: found === null ? null : ('' + found.id()),
            account: foundAccount,
            mailbox: foundMailbox,
            outOfScope: FM_OUT_OF_SCOPE
        });
        """)
    }

    func testAMessageInScopeIsBoundAsItAlwaysWas() throws {
        let hit = try find(messageId: "100", scopeAccounts: ["Bob"], scopeMailboxes: ["INBOX"])
        XCTAssertEqual(hit["bound"] as? String, "100")
        XCTAssertEqual(hit["account"] as? String, "Bob")
        XCTAssertEqual(hit["mailbox"] as? String, "INBOX")
        XCTAssertEqual(hit["outOfScope"] as? Bool, false)
    }

    func testAMessageInAnotherAccountIsRefusedRatherThanBound() throws {
        // `messages.byId` resolves globally — an id from Bob's INBOX resolves
        // through Alice's and through `mail.inbox` — so the check is
        // necessarily post-hoc, off the message. This is what makes it real.
        let miss = try find(messageId: "200", scopeAccounts: ["Bob"], scopeMailboxes: ["INBOX"])
        XCTAssertNil(miss["bound"] as? String)
        XCTAssertEqual(miss["outOfScope"] as? Bool, true)
    }

    func testTheMailboxNameAloneIsNotTheCheck() throws {
        // Every account has an INBOX. A scope of `Bob` + `INBOX` matched
        // against the mailbox NAME alone admits Alice's INBOX, which is
        // verbatim the bug that shipped here once before: a message that moved
        // Alice:INBOX -> Bob:INBOX passed a name-only check and had its body
        // returned under a row saying `"account": "Alice"`.
        let alicesInbox = try find(messageId: "200", scopeAccounts: ["Bob"], scopeMailboxes: ["INBOX"])
        XCTAssertNil(alicesInbox["bound"] as? String)
        // ...and the account alone is not the check either.
        let bobsArchive = try find(messageId: "101", scopeAccounts: ["Bob"], scopeMailboxes: ["INBOX"])
        XCTAssertNil(bobsArchive["bound"] as? String)
        XCTAssertEqual(bobsArchive["outOfScope"] as? Bool, true)
    }

    func testAMessageThatDoesNotExistIsNotReportedAsAScopeViolation() throws {
        // The two answers have to stay apart: "nothing carries this id" is a
        // fact about the message, and reporting it as a refusal would tell a
        // caller a message exists when it does not.
        let miss = try find(messageId: "99999", scopeAccounts: ["Bob"], scopeMailboxes: ["INBOX"])
        XCTAssertNil(miss["bound"] as? String)
        XCTAssertEqual(miss["outOfScope"] as? Bool, false)
    }

    func testAnRFCLookupDoesNotReadColumnsOutOfMailboxesItMayNotReach() throws {
        // The by-Message-ID path is the one that really does read a column out
        // of every mailbox it searches, so for it the scope is a question
        // about where it may LOOK. A Message-ID that exists only in Alice's
        // Archive must come back as nothing at all for a Bob-scoped call —
        // and, because the mailbox was never searched, as "not found" rather
        // than as a refusal: nothing here learned that the message exists.
        let miss = try find(
            messageId: "<alice-archive@relaytest.local>",
            mailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Archive"]
        )
        XCTAssertNil(miss["bound"] as? String)
        XCTAssertEqual(miss["outOfScope"] as? Bool, false)

        let hit = try find(
            messageId: "<bob-archive@relaytest.local>",
            mailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Archive"]
        )
        XCTAssertEqual(hit["bound"] as? String, "101")
        XCTAssertEqual(hit["account"] as? String, "Bob")
    }

    func testTheCallersOwnAccountArgumentStillNarrowsInsideTheScope() throws {
        // The relay scope is ANDed with the caller's own `account`, not a
        // replacement for it: a caller narrowing further inside its own scope
        // is ordinary use, and the two answer different questions.
        let miss = try find(
            messageId: "100",
            account: "Alice",
            scopeAccounts: ["Alice", "Bob"],
            scopeMailboxes: ["INBOX"]
        )
        XCTAssertNil(miss["bound"] as? String)
        // The caller's own filter is not a scope violation — it is the caller
        // getting what it asked for.
        XCTAssertEqual(miss["outOfScope"] as? Bool, false)
    }

    // MARK: - Seam 4: mail_move checks both ends, before it mutates

    private func move(
        messageId: String,
        targetMailbox: String,
        sourceMailbox: String = "INBOX",
        account: String? = nil,
        targetAccount: String? = nil,
        scopeAccounts: [String]?,
        scopeMailboxes: [String]?
    ) throws -> (result: [String: Any], moves: [[String: Any]]) {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.moveScriptJXA(
            messageId: messageId,
            sourceMailbox: sourceMailbox,
            targetMailbox: targetMailbox,
            account: account,
            targetAccount: targetAccount,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), moves: mail.log.moves});
        """)
        return (
            payload["result"] as? [String: Any] ?? [:],
            payload["moves"] as? [[String: Any]] ?? []
        )
    }

    /// The error a script reported, with the sentinel taken off and whether it
    /// was there — exactly what `MailService.mailError` does before it decides
    /// whether to set `_meta.scope_violation`.
    private func refusal(_ result: [String: Any]) -> (message: String, violation: Bool) {
        MailScopeRefusal.split(result["error"] as? String ?? "")
    }

    func testAMoveInsideTheScopeStillWorks() throws {
        let (result, moves) = try move(
            messageId: "100",
            targetMailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Archive"]
        )
        XCTAssertEqual(result["status"] as? String, "moved")
        XCTAssertEqual(result["account"] as? String, "Bob")
        XCTAssertEqual(result["mailbox"] as? String, "Archive")
        XCTAssertEqual(moves.count, 1)
    }

    func testAMoveIntoAMailboxOutOfScopeMovesNothing() throws {
        // Checked against the RESOLVED destination — account and full path —
        // at the last moment before `found.mailbox = destMbox`, which is where
        // the existing pre-move refusal already lives. `moves` empty is the
        // assertion that matters: the refusal is not a report about something
        // that already happened.
        let (result, moves) = try move(
            messageId: "100",
            targetMailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX"]
        )
        XCTAssertEqual(moves.count, 0, "nothing may have been moved")
        let (message, violation) = refusal(result)
        XCTAssertTrue(violation, "a scope refusal has to be distinguishable from any other error")
        XCTAssertTrue(message.contains("Bob:Archive"), message)
        XCTAssertTrue(message.contains("nothing was moved"), message)
    }

    func testAMoveOfAMessageOutOfScopeMovesNothing() throws {
        // The other end. The source is checked off the message itself, which
        // is the only thing that knows where it is.
        let (result, moves) = try move(
            messageId: "200",
            targetMailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Archive"]
        )
        XCTAssertEqual(moves.count, 0, "nothing may have been moved")
        let (message, violation) = refusal(result)
        XCTAssertTrue(violation)
        XCTAssertTrue(message.contains("outside the accounts and mailboxes"), message)
        XCTAssertFalse(message.contains("Alice"), "a refusal must not say where the message really is: \(message)")
    }

    func testACrossAccountMoveOutOfScopeMovesNothing() throws {
        // `target_account` is the only way to cross an account boundary, so
        // it is the only way to leave the scope by crossing one.
        let (result, moves) = try move(
            messageId: "100",
            targetMailbox: "Archive",
            targetAccount: "Alice",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Archive"]
        )
        XCTAssertEqual(moves.count, 0, "nothing may have been moved")
        let (message, violation) = refusal(result)
        XCTAssertTrue(violation)
        XCTAssertTrue(message.contains("Alice:Archive"), message)
    }

    func testALeafNameCannotReachAMailboxOutOfScope() throws {
        // Bob holds `Archive` and `Projects/Archive`. Scoped to the nested
        // one, the bare name `Archive` is an exact path match for the
        // top-level mailbox — which resolves, and is then refused by identity
        // rather than quietly filed into the one the client may reach. Filing
        // into a mailbox the caller did not name is the failure this whole
        // path-based resolution exists to prevent; so is filing into one they
        // may not touch.
        let (result, moves) = try move(
            messageId: "100",
            targetMailbox: "Archive",
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Projects/Archive"]
        )
        XCTAssertEqual(moves.count, 0, "nothing may have been moved")
        XCTAssertTrue(refusal(result).violation)
        XCTAssertTrue(refusal(result).message.contains("Bob:Archive"), refusal(result).message)
    }

    func testAMailboxListingInAFailedMoveNamesOnlyWhatIsInScope() throws {
        // A target that matches nothing throws, and the sentence names what
        // the account does have — which would otherwise hand a confined client
        // the whole folder tree of the account it may read, from a tool call
        // that failed. `mail_list_mailboxes` is scoped for the same reason.
        XCTAssertThrowsError(
            try move(
                messageId: "100",
                targetMailbox: "Nowhere",
                scopeAccounts: ["Bob"],
                scopeMailboxes: ["INBOX"]
            )
        ) { error in
            guard let failure = error as? JXA.Failure,
                  let reported = MailService.scriptErrorMessage(failure.stderr) else {
                return XCTFail("expected a thrown refusal, got \(error)")
            }
            XCTAssertTrue(reported.contains("it has: INBOX"), reported)
            XCTAssertFalse(reported.contains("Projects/Archive"), reported)
        }
    }

    // MARK: - Seam 5: senderJXA refuses an identity out of scope

    private func sender(from: String?, account: String?, scopeAccounts: [String]?) throws -> String {
        let snippet = MailService.senderJXA(from: from, account: account, scopeAccounts: scopeAccounts)
        return try JXA.run("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(snippet.lines)
        JSON.stringify(senderAddr);
        """)
    }

    func testAnAddressInScopeIsAccepted() throws {
        let addr = try sender(from: "bob@relaytest.local", account: nil, scopeAccounts: ["Bob"])
        XCTAssertEqual(addr, "\"bob@relaytest.local\"")
    }

    func testAnAddressMailOwnsButTheScopeDoesNotIsRefused() throws {
        // Ownership and scope are different questions and both are asked. Mail
        // owns `alice@` perfectly well; this client may not be Alice.
        XCTAssertThrowsError(
            try sender(from: "alice@relaytest.local", account: nil, scopeAccounts: ["Bob"])
        ) { error in
            guard let failure = error as? JXA.Failure,
                  let reported = MailService.scriptErrorMessage(failure.stderr) else {
                return XCTFail("expected a thrown refusal, got \(error)")
            }
            let (message, violation) = MailScopeRefusal.split(reported)
            XCTAssertTrue(violation, "refused for scope, so it must be marked as such")
            XCTAssertTrue(message.contains("outside the mail accounts this client may reach"), message)
            // The addresses named as alternatives are the ones this client
            // could actually have used. Listing Alice's would be a disclosure
            // dressed up as help.
            XCTAssertTrue(message.contains("bob@relaytest.local"), message)
            XCTAssertFalse(message.contains("a.tester@relaytest.local"), message)
        }
    }

    func testAnAccountArgumentOutOfScopeIsRefused() throws {
        XCTAssertThrowsError(try sender(from: nil, account: "Alice", scopeAccounts: ["Bob"])) { error in
            guard let failure = error as? JXA.Failure,
                  let reported = MailService.scriptErrorMessage(failure.stderr) else {
                return XCTFail("expected a thrown refusal, got \(error)")
            }
            let (message, violation) = MailScopeRefusal.split(reported)
            XCTAssertTrue(violation)
            XCTAssertTrue(message.contains("nothing was composed"), message)
        }
    }

    func testNamingNeitherResolvesToTheScopeRatherThanToMailsDefault() throws {
        // The case that had to change most. With no `from` and no `account`,
        // Mail sends from its own default account, which has nothing to do
        // with what this client may reach — so a Bob-scoped profile would have
        // sent as Alice, `{"status": "sent"}`, message gone.
        let addr = try sender(from: nil, account: nil, scopeAccounts: ["Bob"])
        XCTAssertEqual(addr, "\"bob@relaytest.local\"")
    }

    func testNamingNeitherWithSeveralAllowedAccountsRefusesRatherThanPicking() throws {
        // Picking one would be macMCP choosing an identity on the caller's
        // behalf, which is the substitution "a `from` no account owns is
        // refused, not substituted" exists to rule out.
        XCTAssertThrowsError(
            try sender(from: nil, account: nil, scopeAccounts: ["Alice", "Bob"])
        ) { error in
            guard let failure = error as? JXA.Failure,
                  let reported = MailService.scriptErrorMessage(failure.stderr) else {
                return XCTFail("expected a thrown refusal, got \(error)")
            }
            let (message, violation) = MailScopeRefusal.split(reported)
            XCTAssertTrue(violation)
            XCTAssertTrue(message.contains("named neither"), message)
            XCTAssertTrue(message.contains("nothing was composed"), message)
        }
    }

    func testAnUnscopedComposeStillLetsMailChoose() throws {
        // The control: unscoped, naming neither leaves `senderAddr` null and
        // Mail's default account is a correct answer to a request that
        // expressed no preference.
        XCTAssertEqual(try sender(from: nil, account: nil, scopeAccounts: nil), "null")
    }

    // MARK: - Task 2: the enumerators report only what is in scope

    private func listMailboxes(account: String?, scopeAccounts: [String]?, scopeMailboxes: [String]?) throws -> String {
        try JXA.run("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.listMailboxesScriptJXA(
            account: account,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes
        ))
        """)
    }

    func testTheMailboxListingIsFilteredAtBothLevels() throws {
        let output = try listMailboxes(
            account: nil,
            scopeAccounts: ["Bob"],
            scopeMailboxes: ["INBOX", "Projects/Archive"]
        )
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return XCTFail("not a listing: \(output)")
        }
        XCTAssertEqual(rows.compactMap { $0["account"] as? String }, ["Bob"])
        XCTAssertEqual(rows.first?["mailboxes"] as? [String] ?? [], ["INBOX", "Projects/Archive"])
        // This is the discovery tool: every `mailbox` a caller passes anywhere
        // else is a string they got from here, so an unfiltered listing is
        // both a disclosure and the map a confined client would plan around.
        XCTAssertFalse(output.contains("Alice"), output)
        XCTAssertFalse(output.contains("\"Archive\""), output)
    }

    func testOnMyMacIsSubjectToTheAccountScopeLikeAnyOtherName() throws {
        // It is an account name every mail tool accepts (#54), so it is
        // scopable — and a scope that does not name it does not reach Mail's
        // app-level mailboxes.
        XCTAssertFalse(
            try listMailboxes(account: nil, scopeAccounts: ["Bob"], scopeMailboxes: nil).contains("On My Mac")
        )
        XCTAssertTrue(
            try listMailboxes(account: nil, scopeAccounts: ["Bob", "On My Mac"], scopeMailboxes: nil)
                .contains("On My Mac")
        )
    }

    func testAnUnscopedListingIsUnchanged() throws {
        let output = try listMailboxes(account: nil, scopeAccounts: nil, scopeMailboxes: nil)
        XCTAssertTrue(output.contains("Alice"))
        XCTAssertTrue(output.contains("Bob"))
        XCTAssertTrue(output.contains("On My Mac"))
        XCTAssertTrue(output.contains("Projects/Archive"))
    }

    // MARK: - The refusal a caller is handed

    func testAScopeRefusalIsReportedAsOneAndNothingElseIs() throws {
        // The whole of what relay reads: `isError` with `_meta.scope_violation`
        // beside it, and the sentinel gone from the text.
        let refused = MailService.mailError(MailScopeRefusal.mark("nope"))
        XCTAssertEqual(refused.isError, true)
        XCTAssertEqual(refused.meta?["scope_violation"], .bool(true))
        XCTAssertEqual(refused.content.first?.text, "nope")

        let ordinary = MailService.mailError("Mail timed out evaluating the request (-1712)")
        XCTAssertEqual(ordinary.isError, true)
        XCTAssertNil(ordinary.meta, "an ordinary failure must not be reported as a boundary being probed")
        XCTAssertEqual(ordinary.content.first?.text, "Mail timed out evaluating the request (-1712)")
    }
}
