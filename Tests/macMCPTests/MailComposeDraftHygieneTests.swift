import XCTest
@testable import macmcp

/// Cover for the draft Mail writes behind a compose message's back.
///
/// Mail autosaves whatever it is composing. A message typed by hand has that
/// copy removed when its window closes; `visible: false` plus a scripted
/// `send()` meant the close never happened, so every send left a permanent
/// full copy — body, recipients, subject, `X-Apple-Auto-Saved: 1` — in the
/// sending account's Drafts. Three copies on disk per send instead of two,
/// and in a folder `mailbox: "all"` excludes, so no tool here would have shown
/// a caller it happened. The abort path was worse: it already called
/// `close({saving: 'no'})` and told the caller "Nothing was sent or saved"
/// while the draft — carrying the very recipient the guard had just refused —
/// sat on the server.
///
/// What is pinned here is the accounting, which is where every wrong answer
/// came from. Measured behaviour that the accounting rests on, and that no
/// hermetic test can establish, is recorded at `composeDraftHygieneJXA`:
/// closing stops Mail writing further copies, and deleting the copy of a
/// message Mail still holds makes Mail write another. What these tests hold
/// still is that the code only ever removes a draft it has established is
/// Mail's own and new, that it never removes one when Mail may still be
/// holding the message, and that what it reports is what it did.
final class MailComposeDraftHygieneTests: XCTestCase {
    /// Runs the hygiene block with a snapshot taken, then whatever the test
    /// wants to happen to Drafts, then a sweep — which is the shape of every
    /// compose script.
    ///
    /// `mail` and `msg` come from the caller so that a test can decide what
    /// Mail was holding and what it answers for the message being composed.
    private func sweep(
        subject: String = "Quarterly numbers",
        mail stub: String,
        senderAnswers: String = "alice@relaytest.local",
        subjectAnswers: String? = nil,
        thenInDrafts: String = "",
        mayRemove: Bool
    ) throws -> [String: Any] {
        let answersSubject = subjectAnswers ?? subject
        return try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        var msg = {
            sender: function() { return '\(senderAnswers)'; },
            subject: function() { return '\(answersSubject)'; }
        };
        \(MailService.boundByNameJXA)
        \(MailService.composeDraftHygieneJXA(subject: subject))
        composeObserve();
        \(thenInDrafts)
        var report = composeSweepDrafts(COMPOSE_SENDER.account, \(mayRemove));
        JSON.stringify({
            report: report,
            deleted: mail.log.deleted,
            drafts: (function() {
                var out = [];
                var boxes = mail.accounts()[0].mailboxes();
                for (var i = 0; i < boxes.length; i++) {
                    if (boxes[i].name() !== 'Drafts') continue;
                    var subs = boxes[i].messages.subject();
                    for (var k = 0; k < subs.length; k++) out.push('' + subs[k]);
                }
                return out;
            })()
        });
        """)
    }

    /// One account with an empty Drafts, plus a second account so that a sweep
    /// that simply took `accounts[0]` would be visible.
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
            {name: 'INBOX'},
            {name: 'Drafts', messages: [{id: 500, subject: 'Something the user wrote'}]}
        ]},
        {name: 'Bob', emailAddresses: ['bob@relaytest.local'], mailboxes: [
            {name: 'Drafts'}
        ]}
    ]});
    """

    /// Mail autosaving the message that is being composed, after the snapshot
    /// was taken. `arrivesInDrafts` is what the compose script's window looks
    /// like from the outside.
    private static func arrivesInDrafts(
        account: String = "Alice",
        id: Int = 900,
        subject: String = "Quarterly numbers",
        autoSaved: Bool = true
    ) -> String {
        """
        (function() {
            var accts = mail.accounts();
            for (var i = 0; i < accts.length; i++) {
                if (accts[i].name() !== '\(account)') continue;
                var boxes = accts[i].mailboxes();
                for (var b = 0; b < boxes.length; b++) {
                    if (boxes[b].name() !== 'Drafts') continue;
                    boxes[b]._msgs.push(makeMessageInto(boxes[b], {
                        id: \(id), subject: '\(subject)', autoSaved: \(autoSaved)
                    }));
                }
            }
        })();
        """
    }

    /// The stub builds its messages inside `makeMail`, so a test that needs
    /// one to arrive later has to build it the same way. This reaches the same
    /// constructor through a mailbox that already exists.
    private static let makeMessageInto = """
    function makeMessageInto(box, spec) {
        var built = makeMail({accounts: [{name: 'scratch', mailboxes: [
            {name: 'Drafts', messages: [spec]}
        ]}]});
        var m = built.accounts()[0].mailboxes()[0]._msgs[0];
        m._box = box;
        return m;
    }
    """

    private func report(_ payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(payload["report"] as? [String: Any])
    }

    // MARK: - The defect: the copy was never accounted for at all

    func testTheAutosavedCopyIsFound() throws {
        // The whole of R4-2: something has to notice it exists. Every send
        // used to leave one and report nothing.
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(),
            mayRemove: false
        )
        let report = try report(out)
        XCTAssertEqual(report["checked"] as? Bool, true, "the sweep did not manage to look: \(report)")
        XCTAssertEqual(report["found"] as? Int, 1, "the autosaved copy was not found: \(report)")
        XCTAssertEqual(report["account"] as? String, "Alice")
    }

    func testFindingNothingIsReportedAsFindingNothing() throws {
        // Reported unconditionally: a leaked draft is invisible to every other
        // tool here, so "there was none" and "nobody looked" have to be told
        // apart in the result rather than inferred from a missing field.
        let out = try sweep(mail: Self.makeMessageInto + Self.twoAccounts, mayRemove: true)
        let report = try report(out)
        XCTAssertEqual(report["checked"] as? Bool, true)
        XCTAssertEqual(report["found"] as? Int, 0)
        XCTAssertEqual(report["removed"] as? Int, 0)
    }

    // MARK: - What may be removed, and when

    func testTheCopyIsRemovedOnceMailHasLetGoOfTheMessage() throws {
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(),
            mayRemove: true
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 1)
        XCTAssertEqual(report["removed"] as? Int, 1)
        XCTAssertEqual(out["drafts"] as? [String], ["Something the user wrote"])
    }

    func testTheCopyIsLeftAloneWhileMailMayStillBeHoldingTheMessage() throws {
        // Not an oversight and not timidity: Mail re-creates the autosaved
        // copy of a message it still holds, so deleting it leaves one in Trash
        // *and* one back in Drafts — measured — where doing nothing leaves
        // exactly one. And an abort is the worst moment to delete on the
        // strength of having identified something, since the guard fired
        // because the identification did not hold.
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(),
            mayRemove: false
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 1)
        XCTAssertEqual(report["removed"] as? Int, 0)
        XCTAssertEqual(report["left_in_drafts"] as? [String], ["900"], "the caller is not told which draft is there")
        XCTAssertEqual((out["deleted"] as? [Any])?.count, 0, "something was deleted anyway")
        XCTAssertEqual(
            (out["drafts"] as? [String])?.sorted(),
            ["Quarterly numbers", "Something the user wrote"]
        )
    }

    // MARK: - What must never be removed

    func testADraftSavedOnPurposeIsNotRemoved() throws {
        // `mail_create_draft`'s own draft is new since the snapshot and
        // carries the same subject; the only thing separating it from the
        // leak is that Mail did not write it, which the header says.
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(autoSaved: false),
            mayRemove: true
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 0, "the draft the caller asked for was treated as a leak: \(report)")
        XCTAssertEqual((out["deleted"] as? [Any])?.count, 0)
        XCTAssertEqual(
            (out["drafts"] as? [String])?.sorted(),
            ["Quarterly numbers", "Something the user wrote"]
        )
    }

    func testADraftThatWasAlreadyThereIsNotRemovedEvenWithTheSameSubject() throws {
        // A user with an open compose window of their own, on the same
        // subject, autosaved before this call started. The snapshot is the
        // only thing that separates it from ours, which is why it is taken
        // before the compose message exists.
        let stub = Self.makeMessageInto + """
        var mail = makeMail({accounts: [
            {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
                {name: 'Drafts', messages: [
                    {id: 500, subject: 'Quarterly numbers', autoSaved: true}
                ]}
            ]}
        ]});
        """
        let out = try sweep(mail: stub, mayRemove: true)
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 0, "a draft that predates this call was treated as its leak: \(report)")
        XCTAssertEqual(out["drafts"] as? [String], ["Quarterly numbers"])
    }

    func testADraftWithADifferentSubjectIsNotRemoved() throws {
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(subject: "A different message"),
            mayRemove: true
        )
        XCTAssertEqual(try report(out)["found"] as? Int, 0)
        XCTAssertEqual((out["deleted"] as? [Any])?.count, 0)
    }

    func testAnotherAccountsDraftsAreNotTouched() throws {
        // The sweep looks in the account Mail said it was sending from, read
        // off the message. Sweeping every account would put a copy of this
        // message's subject in every mailbox's line of fire.
        let out = try sweep(
            mail: Self.makeMessageInto + Self.twoAccounts,
            thenInDrafts: Self.arrivesInDrafts(account: "Bob"),
            mayRemove: true
        )
        let report = try report(out)
        XCTAssertEqual(report["account"] as? String, "Alice")
        XCTAssertEqual(report["found"] as? Int, 0)
        XCTAssertEqual((out["deleted"] as? [Any])?.count, 0)
    }

    // MARK: - The subject the copy carries is Mail's, not the request's

    func testACopyIsFoundUnderTheSubjectMailNormalisedItTo() throws {
        // Mail turns a CR in a subject into a space, and the autosaved copy
        // carries *Mail's* subject. Matching only on what was asked for found
        // nothing and reported a leak as a clean abort — measured, 19 -> 20
        // drafts under "Nothing was sent or saved".
        let out = try sweep(
            subject: "Quarterly numbers\rsecond line",
            mail: Self.makeMessageInto + Self.twoAccounts,
            subjectAnswers: "Quarterly numbers second line",
            thenInDrafts: Self.arrivesInDrafts(subject: "Quarterly numbers second line"),
            mayRemove: false
        )
        XCTAssertEqual(try report(out)["found"] as? Int, 1, "the copy Mail left was not recognised as this message's")
    }

    // MARK: - What the abort sentence says

    func testTheAbortNeverClaimsNoCopyWillBeLeft() throws {
        // An abort hands the message to Mail neither by sending it nor by
        // saving it, so Mail keeps the compose message and autosaves it when
        // its timer next comes round — under a second on a Mail that has been
        // running a while, and 30 seconds on one just relaunched, which is
        // long enough for this check to look, find nothing, and be overtaken.
        // So finding nothing is reported as finding nothing, not as a promise.
        let sentence = try leftBehind(thenInDrafts: "")
        XCTAssertTrue(sentence.hasPrefix("Nothing was sent"), sentence)
        XCTAssertTrue(sentence.contains("None was there when this was checked"), sentence)
        XCTAssertTrue(sentence.contains("may still appear"), sentence)
    }

    func testTheAbortSaysWhatWasLeftBehindAndWhere() throws {
        // The claim that used to be made here was false every time it was
        // made, and it is load-bearing: the guard fires because the message
        // may be addressed to someone the caller never named, and that is
        // exactly what the leaked draft carries.
        let sentence = try leftBehind(thenInDrafts: Self.arrivesInDrafts())
        XCTAssertFalse(sentence.contains("Nothing was sent or saved"), sentence)
        XCTAssertTrue(sentence.contains("Alice"), sentence)
        XCTAssertTrue(sentence.contains("900"), "the draft that was left is not identified: \(sentence)")
    }

    func testTheAbortDoesNotClaimToHaveCheckedWhenItCouldNot() throws {
        // No account matches the sender Mail reported, so there is no Drafts
        // to look in. Saying "nothing was saved" here would be a guess wearing
        // the same words as an answer.
        let sentence = try leftBehind(thenInDrafts: "", senderAnswers: "someone@elsewhere.test")
        XCTAssertFalse(sentence.contains("Nothing was sent or saved"), sentence)
        XCTAssertTrue(sentence.contains("could not be checked"), sentence)
    }

    private func leftBehind(
        thenInDrafts: String,
        senderAnswers: String = "alice@relaytest.local"
    ) throws -> String {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.makeMessageInto)
        \(Self.twoAccounts)
        var msg = {
            sender: function() { return '\(senderAnswers)'; },
            subject: function() { return 'Quarterly numbers'; }
        };
        \(MailService.boundByNameJXA)
        \(MailService.composeDraftHygieneJXA(subject: "Quarterly numbers"))
        composeObserve();
        \(thenInDrafts)
        JSON.stringify({sentence: composeLeftBehind(), deleted: mail.log.deleted});
        """)
        XCTAssertEqual((payload["deleted"] as? [Any])?.count, 0, "the abort path deleted something")
        return try XCTUnwrap(payload["sentence"] as? String)
    }

    // MARK: - Finding the Drafts mailbox

    func testANestedFolderCalledDraftsIsNotMistakenForTheAccountsDrafts() throws {
        // A bare name is a path with one component, so the account's own
        // Drafts is the one at the root. Sweeping `Projects/Drafts` instead
        // would delete out of a user folder while leaving the leak in place.
        let stub = Self.makeMessageInto + """
        var mail = makeMail({accounts: [
            {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
                {name: 'Drafts', container: 'Projects'},
                {name: 'Projects'},
                {name: 'Drafts'}
            ]}
        ]});
        """
        let out = try sweep(
            mail: stub,
            thenInDrafts: """
            (function() {
                var boxes = mail.accounts()[0].mailboxes();
                for (var b = 0; b < boxes.length; b++) {
                    if (boxes[b]._path !== 'Drafts') continue;
                    boxes[b]._msgs.push(makeMessageInto(boxes[b], {id: 900, subject: 'Quarterly numbers', autoSaved: true}));
                }
            })();
            """,
            mayRemove: true
        )
        let report = try report(out)
        XCTAssertEqual(report["found"] as? Int, 1, "the account's own Drafts was not the one that was checked: \(report)")
        let deleted = try XCTUnwrap(out["deleted"] as? [[String: Any]])
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?["id"] as? Int, 900)
    }

    func testAnAccountWhoseDraftsCannotBeReachedByNameIsStillSwept() throws {
        // `byName` is the cheap path, not the only one. An account that will
        // not answer to it falls back to the full path build rather than
        // reporting an account with no Drafts, which would read as "no copy
        // was left".
        let stub = Self.makeMessageInto + """
        var mail = makeMail({accounts: [
            {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
                {name: 'Drafts', byNameHidden: true}
            ]}
        ]});
        """
        let out = try sweep(
            mail: stub,
            thenInDrafts: Self.arrivesInDrafts(),
            mayRemove: true
        )
        let report = try report(out)
        XCTAssertEqual(report["checked"] as? Bool, true, "\(report)")
        XCTAssertEqual(report["found"] as? Int, 1, "\(report)")
    }

    func testAnAccountWithNoDraftsMailboxSaysSoRatherThanSayingNothingWasLeft() throws {
        let stub = Self.makeMessageInto + """
        var mail = makeMail({accounts: [
            {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [{name: 'INBOX'}]}
        ]});
        """
        let report = try report(try sweep(mail: stub, mayRemove: true))
        XCTAssertEqual(report["checked"] as? Bool, false)
        XCTAssertNotNil(report["detail"] as? String)
    }
}
