import XCTest
@testable import macmcp

/// Cover for `findMessageJXA` binding a message by position (issue #50).
///
/// `found = subset[i].mbox.messages[k]` is an index into a bulk id column. JXA
/// re-resolves a specifier on **every** property access rather than snapshotting
/// the object behind it, so that binding meant "whatever is at position k right
/// now": each read off `found` could answer for a different message than the
/// last one did, silently and with no error.
///
/// Measured on the fixture at ~3,000 messages under continuous delivery,
/// `mail_get_email` was wrong in 26 of 60 calls — and in 18 of those it returned
/// the right id, the right subject and the right `rfc_message_id` beside another
/// message's body, which nothing in the response lets a caller detect.
///
/// These run the generated script for real against a stub whose mailbox changes
/// *between* two reads of the message the script bound. That interleaving is the
/// whole test and cannot be arranged against a live mailbox.
final class MailFindMessageTests: XCTestCase {
    /// Two accounts, each owning an `INBOX` and an `Archive`. Bodies carry their
    /// own id so a body taken from the wrong message is self-evident.
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [
                {id: 401, messageId: 'a1@relaytest.local', subject: 'first',  content: 'BODY 401'},
                {id: 402, messageId: 'a2@relaytest.local', subject: 'second', content: 'BODY 402'},
                {id: 403, messageId: 'a3@relaytest.local', subject: 'third',  content: 'BODY 403'}
            ]},
            {name: 'Archive', messages: [
                {id: 404, messageId: 'a4@relaytest.local', subject: 'filed', content: 'BODY 404'}
            ]}
        ]},
        {name: 'Bob', mailboxes: [
            {name: 'INBOX', messages: [
                {id: 501, messageId: 'b1@relaytest.local', subject: 'bobs', content: 'BODY 501'}
            ]},
            {name: 'Archive', messages: []}
        ]}
    ]});
    """

    private func find(
        id: String,
        account: String? = nil,
        mailbox: String = "INBOX",
        then: String
    ) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.findMessageJXA(account: account, mailbox: mailbox, messageId: id))
        \(then)
        """)
    }

    /// Reads the identifying properties twice, with one message taken out of the
    /// mailbox in between. `402` sits at index 1; once `401` leaves it sits at
    /// index 0, and index 1 is `403`.
    private static let readTwiceAcrossAChange = """
    function snapshot() {
        try { return {id: '' + found.id(), subject: '' + found.subject(), body: '' + found.content()}; }
        catch (e) { return {raised: '' + e}; }
    }
    var before = snapshot();
    var removed = mail.takeOut('Alice', 'INBOX', 0);
    var after = snapshot();
    JSON.stringify({
        before: before, after: after, removed: '' + removed,
        account: foundAccount, mailbox: foundMailbox
    });
    """

    // MARK: - The defect

    func testAMessageBoundByItsNumericIdSurvivesTheMailboxChangingUnderIt() throws {
        let payload = try find(id: "402", then: Self.readTwiceAcrossAChange)
        XCTAssertEqual(payload["removed"] as? String, "401", "the mailbox did not actually change")
        let expected = ["id": "402", "subject": "second", "body": "BODY 402"]
        XCTAssertEqual(payload["before"] as? [String: String], expected)
        XCTAssertEqual(
            payload["after"] as? [String: String], expected,
            "the second read answered for a different message than the first"
        )
    }

    func testAMessageBoundByItsMessageIdSurvivesTheMailboxChangingUnderIt() throws {
        // The by-Message-ID path reads a column to translate the header value
        // into a numeric id, so it has the shift to contend with as well; what
        // it binds has to be no more positional than the numeric path.
        let payload = try find(id: "<a2@relaytest.local>", then: Self.readTwiceAcrossAChange)
        XCTAssertEqual(payload["removed"] as? String, "401")
        let expected = ["id": "402", "subject": "second", "body": "BODY 402"]
        XCTAssertEqual(payload["before"] as? [String: String], expected)
        XCTAssertEqual(payload["after"] as? [String: String], expected)
    }

    func testAMessageThatLeavesEntirelyRaisesRatherThanAnsweringForItsNeighbour() throws {
        // The other half of binding by identity: when the message really has
        // gone, the specifier says so. Bound by position it would have gone on
        // answering, for whoever had taken its place.
        let payload = try find(id: "402", then: """
        var removed = mail.takeOut('Alice', 'INBOX', 1);
        var after;
        try { after = {id: '' + found.id()}; } catch (e) { after = {raised: true}; }
        JSON.stringify({removed: '' + removed, after: after});
        """)
        XCTAssertEqual(payload["removed"] as? String, "402")
        XCTAssertEqual((payload["after"] as? [String: Any])?["raised"] as? Bool, true)
    }

    // MARK: - Where the message is, and whose it is

    func testTheMailboxReportedIsTheOneTheMessageIsInNotTheOneAskedFor() throws {
        // `mailbox` is a hint about where to look, and Mail's ids are unique
        // across every account, so the answer has to come off the message.
        let payload = try find(id: "404", mailbox: "INBOX", then: """
        JSON.stringify({account: foundAccount, mailbox: foundMailbox, subject: '' + found.subject()});
        """)
        XCTAssertEqual(payload["account"] as? String, "Alice")
        XCTAssertEqual(payload["mailbox"] as? String, "Archive")
        XCTAssertEqual(payload["subject"] as? String, "filed")
    }

    func testAnIdInAnotherAccountIsNotReturnedWhenAnAccountWasNamed() throws {
        // `byId` resolves across every account, so scoping is no longer a
        // property of what was searched and has to be checked on the answer.
        let payload = try find(id: "501", account: "Alice", then: """
        JSON.stringify({found: found === null, account: foundAccount});
        """)
        XCTAssertEqual(payload["found"] as? Bool, true, "Bob's message was returned for an Alice-scoped lookup")

        let unscoped = try find(id: "501", then: """
        JSON.stringify({account: foundAccount, mailbox: foundMailbox});
        """)
        XCTAssertEqual(unscoped["account"] as? String, "Bob", "and it is still reachable without the scope")
    }

    func testAnAccountThatDoesNotExistIsSaidSoRatherThanReportedAsAMiss() throws {
        // The numeric path no longer walks the accounts to build a search scope,
        // so this is the throw it has to make on its own account. "not found"
        // for a misspelt account name is a different, less useful answer.
        XCTAssertThrowsError(
            try find(id: "402", account: "Zed", then: "JSON.stringify({});")
        ) { error in
            let reported = MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? "")
            XCTAssertEqual(reported, "account not found: Zed")
        }
    }

    func testAnIdentifierNoMessageCanCarryIsAMissWithoutAsingleAppleEvent() throws {
        // Neither an integer nor something with an `@` in it. The old code
        // compared it against the numeric id column, which could never match,
        // so this is the same answer without the search.
        XCTAssertEqual(MailService.messageHandle("not-an-id"), .unmatchable)
        XCTAssertEqual(MailService.messageHandle("0123"), .unmatchable, "a non-round-tripping integer is not one")
        XCTAssertEqual(MailService.messageHandle("402"), .numeric(402))
        XCTAssertEqual(MailService.messageHandle("<a2@relaytest.local>"), .rfc("a2@relaytest.local"))
        XCTAssertEqual(MailService.messageHandle("a2@relaytest.local"), .rfc("a2@relaytest.local"))

        let payload = try find(id: "not-an-id", then: "JSON.stringify({found: found === null});")
        XCTAssertEqual(payload["found"] as? Bool, true)
    }

    // MARK: - The saved-draft find-back, which had the same binding

    func testTheDraftNamedAfterSavingIsTheOneCarryingTheSubjectItWasSavedUnder() throws {
        // `mail_create_draft` finds the draft it just saved by subject in the
        // account's Drafts mailbox. It used to zip the id, subject and
        // Message-ID columns -- three Apple Events -- by index, so a mailbox
        // that changed between two of them named a different message. That name
        // is what `body_check` then fetches a source for, so it would report on
        // the wrong draft's body.
        //
        // Here one draft leaves as another arrives, in the other order: the
        // mailbox is two long before and after, so nothing about its length
        // gives it away, but "Report" moves from index 1 to index 0. Zipped by
        // index that names id 900, whose subject is "Other".
        let stub = """
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {
                name: 'Drafts',
                messages: [
                    {id: 900, subject: 'Other',  messageId: 'other@relaytest.local'},
                    {id: 901, subject: 'Report', messageId: 'report@relaytest.local'}
                ],
                mutation: {
                    after: 2, removeAt: 0, insertAt: 1,
                    message: {id: 800, subject: 'Other'}
                }
            },
            {name: 'INBOX'}
        ]}]});
        """
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.savedDraftLookupJXA(account: "Alice", from: nil, subject: "Report"))
        JSON.stringify(savedDraft);
        """)
        XCTAssertNil(payload["lookup_error"], "\(payload)")
        XCTAssertEqual(payload["message_id"] as? String, "901", "the draft named is not the one with that subject")
        XCTAssertEqual(payload["rfc_message_id"] as? String, "report@relaytest.local")
        XCTAssertEqual(payload["mailbox"] as? String, "Drafts")
        XCTAssertEqual(payload["account"] as? String, "Alice")
    }

    // MARK: - The body-scan pass, which had the same binding

    func testEachBodyComesBackUnderTheIdOfTheMessageItWasReadFrom() throws {
        // `mail_search_emails`' second pass used to read the id column and then
        // take `mb.messages[i].content()` at the matching index. This mailbox
        // gains a message on every read, so every index is stale by the time it
        // is used; each body still has to arrive under its own id.
        let stub = """
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {
                name: 'INBOX',
                messages: [
                    {id: 401, subject: 'first',  content: 'BODY 401'},
                    {id: 402, subject: 'second', content: 'BODY 402'},
                    {id: 403, subject: 'third',  content: 'BODY 403'}
                ],
                arrival: {
                    after: 1, at: 0, repeat: true,
                    message: {id: 'new', subject: 'just arrived'}
                }
            }
        ]}]});
        """
        let output = try JXA.run("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.bodyFetchScriptJXA(account: "Alice", mailbox: "INBOX", ids: ["401", "402", "403"]))
        """)
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return XCTFail("not a JSON array: \(output)")
        }
        XCTAssertEqual(rows.count, 3, "every id asked for should have come back")
        for row in rows {
            XCTAssertEqual(row["body"], "BODY \(row["id"] ?? "")", "a body arrived under another message's id")
        }
    }

    func testABodyIsNotReturnedForAMessageThatHasMovedToAnotherAccount() throws {
        // The body pass re-binds by id, which is right, and then checked only
        // the mailbox **name** the message reports. Every account has an INBOX,
        // so a message that moved `Alice:INBOX` -> `Bob:INBOX` between the
        // metadata scan and this pass passed that check and had its body
        // returned under a row saying `"account": "Alice"` — the same class of
        // wrong answer as a body under another message's id, one level up.
        //
        // `findMessageJXA` has always checked the account here (`fmInScope`);
        // this path enforced a weaker invariant than the one beside it.
        let stub = """
        var mail = makeMail({accounts: [
            {name: 'Alice', mailboxes: [
                {name: 'INBOX', messages: [
                    {id: 401, subject: 'first',  content: 'BODY 401'},
                    {id: 402, subject: 'second', content: 'BODY 402'}
                ]}
            ]},
            {name: 'Bob', mailboxes: [{name: 'INBOX'}]}
        ]});
        // 402 is refiled into Bob's INBOX after the metadata scan stamped its
        // row `Alice:INBOX`. `byId` resolves across accounts, so it still
        // answers, and its mailbox is still called INBOX.
        (function() {
            var alice = mail.accounts()[0].mailboxes()[0];
            var bob = mail.accounts()[1].mailboxes()[0];
            var moved = alice._msgs.splice(1, 1)[0];
            bob._msgs.push(moved);
            moved._box = bob;
        })();
        """
        let output = try JXA.run("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.bodyFetchScriptJXA(account: "Alice", mailbox: "INBOX", ids: ["401", "402"]))
        """)
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return XCTFail("not a JSON array: \(output)")
        }
        XCTAssertEqual(
            rows.map { $0["id"] ?? "" }, ["401"],
            "402 is in Bob's INBOX now; its body cannot come back under a row claiming Alice"
        )
    }
}
