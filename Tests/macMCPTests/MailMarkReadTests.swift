import XCTest
@testable import macmcp

/// What `mail_mark_read` reports, and where it gets it from.
///
/// It used to set `readStatus` and return the sentence "marked read" — a claim
/// about Mail assembled entirely out of what the caller had asked for. Nothing
/// was read back, so a flag Mail declined to set came out as a success; and the
/// sentence named neither the message it had happened to nor the mailbox it had
/// been found in, which for a call whose `message_id` may be an RFC Message-ID
/// resolved across every account is the whole of what a caller needs to know.
///
/// `found` is already bound by id, so asking it for its own read state costs
/// one Apple Event. These pin that the answer comes from there.
final class MailMarkReadTests: XCTestCase {
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'alice@relaytest.local', read: false}]}
        ]},
        {name: 'Bob', mailboxes: [
            {name: 'Archive', container: 'Projects'},
            {name: 'Projects'},
            {name: 'INBOX', messages: [{id: 100, messageId: 'bob@relaytest.local', read: false}]}
        ]}
    ]});
    """

    /// Runs the generated script, with an optional wrapper that makes the
    /// message refuse to take the flag.
    private func mark(
        messageId: String,
        read: Bool,
        account: String? = nil,
        mailbox: String = "INBOX",
        stub: String = twoAccounts,
        beforeRun: String = ""
    ) throws -> [String: Any] {
        return try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(beforeRun)
        \(MailService.markReadScriptJXA(
            account: account, mailbox: mailbox, messageId: messageId, read: read
        ))
        """)
    }

    func testTheReadStateComesBackOffTheMessage() throws {
        let out = try mark(messageId: "100", read: true)
        XCTAssertEqual(out["read"] as? Bool, true, "nothing was read back: \(out)")
        XCTAssertEqual(out["requested"] as? Bool, true)
    }

    func testTheMessageAndWhereItWasFoundAreNamed() throws {
        // The id can be an RFC Message-ID resolved across every account, so
        // which message this happened to, and where, is not something the
        // caller already knows.
        let out = try mark(messageId: "bob@relaytest.local", read: true, mailbox: "INBOX")
        XCTAssertEqual(out["message_id"] as? String, "100", "\(out)")
        XCTAssertEqual(out["rfc_message_id"] as? String, "bob@relaytest.local")
        XCTAssertEqual(out["account"] as? String, "Bob", "\(out)")
        XCTAssertEqual(out["mailbox"] as? String, "INBOX")
    }

    func testAFlagMailDeclinedToSetIsVisible() throws {
        // The read-back is the only thing between this and reporting a success
        // for a message whose state did not change.
        let out = try mark(
            messageId: "100",
            read: true,
            beforeRun: """
            (function() {
                var boxes = mail.accounts()[1].mailboxes();
                for (var i = 0; i < boxes.length; i++) {
                    if (boxes[i]._path !== 'INBOX') continue;
                    var m = boxes[i]._msgs[0];
                    Object.defineProperty(m, '_read', {get: function() { return false; }, set: function() {}});
                }
            })();
            """
        )
        XCTAssertEqual(out["requested"] as? Bool, true)
        XCTAssertEqual(out["read"] as? Bool, false, "Mail did not take the flag and the result did not say so: \(out)")
    }

    func testUnreadIsReadBackTheSameWay() throws {
        let out = try mark(messageId: "100", read: false)
        XCTAssertEqual(out["read"] as? Bool, false)
        XCTAssertEqual(out["requested"] as? Bool, false)
    }

    func testAMissIsStillAMiss() throws {
        let out = try mark(messageId: "999", read: true)
        XCTAssertNotNil(out["error"] as? String, "\(out)")
    }
}
