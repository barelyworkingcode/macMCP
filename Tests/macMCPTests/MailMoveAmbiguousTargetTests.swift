import XCTest
@testable import macmcp

/// Cover for `mail_move` filing into a *nested* mailbox that happens to share a
/// leaf name with the one the caller meant.
///
/// Mail flattens an account's mailbox tree and reports leaf names, so an account
/// with `Projects/Archive` beside a top-level `Archive` enumerates **two**
/// mailboxes called `Archive`. `boundByName` deliberately keeps them distinct —
/// that is what `MailMailboxBindingTests` pins — but the destination lookup then
/// collapses them again: it walks the bound list and returns the first whose
/// name matches. Mail enumerates children before parents and the special
/// mailboxes last, so the first match is systematically the nested one.
///
/// Measured against the fixture on Bob, who has both: `Archive` at index 0 is
/// `Projects/Archive`, `Archive` at index 22 is the top-level one. A move to
/// `"Archive"` landed in `.Projects.Archive/`, and a move to `"Trash"` landed in
/// `.Projects.Trash/` — a "delete this" that leaves the message undeleted in a
/// user folder. Both came back `{"mailbox": "...", "verified": true}`: the
/// read-back looks in the same specifier the pick chose, so it confirms *where
/// the message was put*, never *where the caller asked for it*.
///
/// These run the generated script against a stub, because which mailbox object
/// the JavaScript picks is not visible from Swift, and check the destination
/// against the stub's own arrays rather than against what the script reported.
final class MailMoveAmbiguousTargetTests: XCTestCase {
    /// One move, plus the ground truth the result is checked against.
    private struct Outcome {
        /// The message the script threw, if it refused.
        let thrown: String?
        /// `moveResult`, if the script produced one.
        let result: [String: Any]?
        /// Every `found.mailbox = ...` assignment the stub saw.
        let moves: [[String: Any]]
        /// Index in the account's mailbox array that now holds the message, or
        /// -1. The stub's arrays are the only thing here that can tell two
        /// mailboxes called `Archive` apart.
        let landedAt: Int
        /// The ids of the messages already sitting in that mailbox, which name
        /// it without relying on anything the script said.
        let landedBeside: [String]
    }

    private func move(
        _ stub: String,
        messageId: String = "100",
        targetMailbox: String = "Archive"
    ) throws -> Outcome {
        // The move script is wrapped so that a refusal still leaves the stub's
        // ground truth reachable: a test that only saw the throw could not say
        // whether anything had been filed before it.
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        function whereIs(id) {
            var boxes = mail.accounts()[0].mailboxes();
            for (var i = 0; i < boxes.length; i++) {
                for (var j = 0; j < boxes[i]._msgs.length; j++) {
                    if (('' + boxes[i]._msgs[j]._id) === ('' + id)) return i;
                }
            }
            return -1;
        }
        function siblingsOf(index, id) {
            if (index < 0) return [];
            var out = [];
            var box = mail.accounts()[0].mailboxes()[index];
            for (var j = 0; j < box._msgs.length; j++) {
                if (('' + box._msgs[j]._id) !== ('' + id)) out.push('' + box._msgs[j]._id);
            }
            return out;
        }
        var thrown = null;
        var moveResult = null;
        try {
        \(MailService.moveScriptJXA(
            messageId: messageId,
            sourceMailbox: "INBOX",
            targetMailbox: targetMailbox,
            account: nil,
            targetAccount: nil
        ))
        } catch (e) { thrown = '' + e; }
        var at = whereIs(\(messageId));
        JSON.stringify({
            thrown: thrown,
            result: moveResult === null ? null : JSON.parse(JSON.stringify(moveResult)),
            moves: mail.log.moves,
            landed_at: at,
            landed_beside: siblingsOf(at, \(messageId))
        });
        """)
        return Outcome(
            thrown: payload["thrown"] as? String,
            result: payload["result"] as? [String: Any],
            moves: payload["moves"] as? [[String: Any]] ?? [],
            landedAt: payload["landed_at"] as? Int ?? -1,
            landedBeside: (payload["landed_beside"] as? [String]) ?? []
        )
    }

    /// Bob as the fixture has him: the nested `Projects/Archive` enumerated
    /// first, the top-level `Archive` after it. Each Archive holds one message
    /// of its own, which is what identifies it afterwards.
    private static let nestedFirst = """
    var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
        {name: 'Archive', messages: [{id: 10, messageId: 'in-projects-archive@relaytest.local'}]},
        {name: 'Projects', messages: []},
        {name: 'Archive', messages: [{id: 12, messageId: 'in-top-level-archive@relaytest.local'}]},
        {name: 'Receipts', messages: []},
        {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local'}]}
    ]}]});
    """

    /// The same account with the two Archives the other way round, so a tool
    /// that simply took the first match cannot pass by landing on the mailbox a
    /// user would probably have meant.
    private static let topLevelFirst = """
    var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
        {name: 'Archive', messages: [{id: 12, messageId: 'in-top-level-archive@relaytest.local'}]},
        {name: 'Projects', messages: []},
        {name: 'Archive', messages: [{id: 10, messageId: 'in-projects-archive@relaytest.local'}]},
        {name: 'Receipts', messages: []},
        {name: 'INBOX', messages: [{id: 100, messageId: 'bob-inbox@relaytest.local'}]}
    ]}]});
    """

    // MARK: - The defect

    func testATargetNameSharedByTwoMailboxesIsRefusedRatherThanResolvedToTheFirst() throws {
        // Two mailboxes answer to "Archive" and nothing in the request says
        // which. Filing into either one is a guess, and the caller is given no
        // way to tell which way it went, so the only answer that is not
        // confidently wrong is to refuse and name both.
        let outcome = try move(Self.nestedFirst)

        XCTAssertEqual(outcome.moves.count, 0, "the message was filed into one of two mailboxes called Archive")
        XCTAssertEqual(outcome.landedAt, 4, "the message should still be in INBOX")
        XCTAssertNotNil(
            outcome.thrown ?? outcome.result?["error"] as? String,
            "the ambiguity was resolved silently: \(outcome.result ?? [:])"
        )
    }

    func testTheSameTargetNameIsRefusedRegardlessOfWhichMailboxMailListsFirst() throws {
        // The mirror image. Taking the first match happens to land on the
        // top-level Archive here, which is what a caller probably meant — so a
        // test run only in this order would report the tool as sound.
        let outcome = try move(Self.topLevelFirst)

        XCTAssertEqual(outcome.moves.count, 0, "the message was filed into one of two mailboxes called Archive")
        XCTAssertEqual(outcome.landedAt, 4, "the message should still be in INBOX")
        XCTAssertNotNil(
            outcome.thrown ?? outcome.result?["error"] as? String,
            "the ambiguity was resolved silently: \(outcome.result ?? [:])"
        )
    }

    func testAMoveResultDistinguishesTheTwoMailboxesThatShareItsName() throws {
        // The half of this that verification cannot reach. Both orderings file
        // the message into a *different* real mailbox, and both describe it
        // with the same leaf name and the same `verified: true` — so nothing in
        // the response tells the two apart. Whatever a fix does with the
        // ambiguity, a result that claims a destination has to identify it.
        let nested = try move(Self.nestedFirst)
        let topLevel = try move(Self.topLevelFirst)

        guard let a = nested.result, let b = topLevel.result,
              a["error"] == nil, b["error"] == nil else {
            // Refusing is a fine answer: there is then no destination claim to
            // be wrong about.
            return
        }
        XCTAssertNotEqual(
            nested.landedBeside, topLevel.landedBeside,
            "the two runs were expected to file into different mailboxes"
        )
        XCTAssertNotEqual(
            NSDictionary(dictionary: a), NSDictionary(dictionary: b),
            "the message went to two different mailboxes and both results say the same thing: \(a)"
        )
    }

    // MARK: - Controls, which pass today

    func testAnUnambiguousTargetStillMoves() throws {
        let outcome = try move(Self.nestedFirst, targetMailbox: "Receipts")
        XCTAssertNil(outcome.thrown)
        XCTAssertEqual(outcome.result?["status"] as? String, "moved")
        XCTAssertEqual(outcome.result?["mailbox"] as? String, "Receipts")
        XCTAssertEqual(outcome.result?["verified"] as? Bool, true)
        XCTAssertEqual(outcome.landedAt, 3)
    }

    func testATargetNameNoMailboxCarriesIsStillRefused() throws {
        let outcome = try move(Self.nestedFirst, targetMailbox: "Nowhere")
        XCTAssertEqual(outcome.moves.count, 0)
        XCTAssertNotNil(outcome.thrown, "a missing destination has to be refused")
    }
}
