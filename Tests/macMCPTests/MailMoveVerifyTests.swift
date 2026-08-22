import XCTest
@testable import macmcp

/// What `mail_move` spends confirming that the message reached the mailbox it
/// was sent to.
///
/// `moved` on its own says nothing about the destination, so the move is read
/// back — and the read-back used to be one shape only: fetch the destination's
/// entire `messageId()` column and scan it. That column costs 555ms on Alice's
/// 11,808-message INBOX, and it was fetched on **every one of up to twelve
/// attempts**, so a move whose result was slow to appear spent ~9.4s of Apple
/// Events inside a 120s script, all of it re-reading a mailbox the caller was
/// not asking about.
///
/// Two things bound it now. A cheap probe — `messages.byId(n)` plus a check of
/// where that message says it is — is tried first, and answers in ~15-35ms
/// without touching the column. And the column itself is fetched a **fixed**
/// number of times rather than once per attempt, front-loaded, so the later
/// attempts spend wall clock rather than Apple Events.
///
/// The cheap probe only works while Mail's numeric id survives the move, and
/// measured against the fixture it does **not** survive one: moving message
/// 133106 from Alice's INBOX to Alice's Archive produced 133107 there, because
/// an IMAP re-file is a new UID even inside one account. Making it the only
/// verification — which is what R5-F11 proposed — turned a 0.55s move into
/// 3.69s: twelve failed probes and their delays before the column scan that was
/// always going to be the answer. So it is a fast path and the column stays.
final class MailMoveVerifyTests: XCTestCase {
    private static let oneAccount = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'probe@relaytest.local'}]},
            {name: 'Archive', messages: [
                {id: 300, messageId: 'a@relaytest.local'},
                {id: 301, messageId: 'b@relaytest.local'}
            ]}
        ]}
    ]});
    """

    /// Counts the bulk column fetches on one mailbox, and optionally makes it
    /// answer as though the move has not arrived — which is what a slow server
    /// looks like, and the only condition under which the retry loop runs at
    /// all.
    private static func watchDestination(hide: Bool) -> String {
        """
        var COLUMNS = {messageId: 0, id: 0};
        (function() {
            var boxes = mail.accounts()[0].mailboxes();
            var box = null;
            for (var i = 0; i < boxes.length; i++) if (boxes[i]._path === 'Archive') box = boxes[i];
            var real = Object.getOwnPropertyDescriptor(box, 'messages').get;
            Object.defineProperty(box, 'messages', {
                get: function() {
                    var spec = real.call(box);
                    var mids = spec.messageId, ids = spec.id, byId = spec.byId;
                    spec.messageId = function() { COLUMNS.messageId++; return \(hide ? "[]" : "mids()"); };
                    spec.id = function() { COLUMNS.id++; return \(hide ? "[]" : "ids()"); };
                    \(hide ? "spec.byId = function(n) { return {exists: function() { return false; }}; };" : "")
                    return spec;
                },
                configurable: true
            });
        })();
        """
    }

    private func move(hide: Bool) throws -> (result: [String: Any], columns: [String: Any]) {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.oneAccount)
        \(Self.watchDestination(hide: hide))
        \(MailService.moveScriptJXA(
            messageId: "200",
            sourceMailbox: "INBOX",
            targetMailbox: "Archive",
            account: "Alice",
            targetAccount: nil
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), columns: COLUMNS});
        """)
        return (
            payload["result"] as? [String: Any] ?? [:],
            payload["columns"] as? [String: Any] ?? [:]
        )
    }

    func testAMoveWhoseIdSurvivesIsVerifiedWithoutReadingTheDestination() throws {
        let (result, columns) = try move(hide: false)
        XCTAssertEqual(result["verified"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["mailbox"] as? String, "Archive")
        XCTAssertEqual(
            columns["messageId"] as? Int, 0,
            "the whole Message-ID column of the destination was fetched to find a message that could be asked for by name"
        )
        XCTAssertEqual(columns["id"] as? Int, 0, "\(columns)")
    }

    func testTheColumnIsFetchedABoundedNumberOfTimesWhenTheMoveCannotBeSeen() throws {
        // The worst case, and the only one the retry loop is for. Twelve
        // attempts used to mean twelve whole-mailbox reads.
        let (result, columns) = try move(hide: true)
        XCTAssertEqual(result["verified"] as? Bool, false, "the destination was hiding the message: \(result)")
        let fetched = columns["messageId"] as? Int ?? -1
        XCTAssertLessThanOrEqual(
            fetched, 5,
            "the destination's whole Message-ID column was fetched \(fetched) times for one move"
        )
        XCTAssertGreaterThan(fetched, 0, "it has to be fetched at least once, or nothing was verified")
    }

    func testAnUnverifiedMoveStillReportsWhatItDid() throws {
        // `verified: false` is an answer; losing the move's identifiers with it
        // would not be.
        let (result, _) = try move(hide: true)
        XCTAssertEqual(result["status"] as? String, "moved")
        XCTAssertEqual(result["rfc_message_id"] as? String, "probe@relaytest.local")
        XCTAssertEqual(result["cross_account"] as? Bool, false)
    }
}
