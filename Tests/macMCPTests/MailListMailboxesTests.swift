import XCTest
@testable import macmcp

/// `mail_list_mailboxes` is the discovery tool: every other mail tool's
/// `mailbox`, `source_mailbox` and `target_mailbox` argument is a string a
/// caller got from here. One account that will not hold still used to cost all
/// of them.
///
/// `boundByName` gives up on a collection that changes across three attempts,
/// and the listing turned that into a throw out of the enumeration loop -- so a
/// single busy account replaced every other account's mailboxes with
/// `the mailbox list kept changing while it was being read`. Everywhere else in
/// this file the choice is the opposite one: the scan names what it could not
/// read in `skipped_mailboxes` and returns the rest.
///
/// Run through real `osascript` against the stub, because the degrade is in the
/// generated JavaScript.
final class MailListMailboxesTests: XCTestCase {
    /// Bob's mailbox list answers differently on every read, which is what
    /// `boundByName` cannot pair columns across. Alice's and the local boxes are
    /// settled.
    private let oneBusyAccount = """
    var mail = makeMail({
        accounts: [
            {name: 'Alice', mailboxes: [{name: 'INBOX'}, {name: 'Archive'}]},
            {name: 'Bob', mailboxes: [{name: 'INBOX'}, {name: 'Sent'}]}
        ],
        local: [{name: 'Notes'}]
    });
    var reads = 0;
    mail.accounts()[1].mailboxes.name = function() {
        reads++;
        return reads % 2 === 1 ? ['INBOX', 'Sent'] : ['INBOX', 'Sent', 'Later'];
    };
    """

    private func listing(_ stub: String, account: String? = nil) throws -> [[String: Any]] {
        let output = try JXA.run("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.listMailboxesScriptJXA(account: account))
        """)
        let data = try XCTUnwrap(output.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testABusyAccountDoesNotCostTheAccountsThatWereRead() throws {
        let results = try listing(oneBusyAccount)

        XCTAssertEqual(results.map { $0["account"] as? String ?? "" }, ["Alice", "Bob", "On My Mac"])
        XCTAssertEqual(results[0]["mailboxes"] as? [String] ?? [], ["INBOX", "Archive"])
        XCTAssertEqual(results[2]["mailboxes"] as? [String] ?? [], ["Notes"], "the local boxes are read after Bob")
    }

    func testTheAccountThatCouldNotBeReadIsNamedRatherThanShownAsEmpty() throws {
        // An empty list is an answer -- "this account holds no mailboxes" -- and
        // it is not this one. The reason travels with it, as it does for a
        // mailbox in `skipped_mailboxes`.
        let bob = try listing(oneBusyAccount)[1]

        XCTAssertEqual(bob["mailboxes"] as? [String] ?? [], [])
        let unread = bob["unread"] as? String ?? ""
        XCTAssertTrue(unread.contains("kept changing"), "no reason was given: \(bob)")
    }

    func testAnAccountThatWasReadCarriesNoUnreadKey() throws {
        // The key is absent rather than null on a listing that is complete, so
        // its presence is the whole test a caller has to make.
        let alice = try listing(oneBusyAccount)[0]
        XCTAssertNil(alice["unread"])
    }

    func testAskingForOneAccountThatWillNotHoldStillStillRefuses() throws {
        // There is nothing to degrade to when the caller named the one account,
        // and an empty list for it would read as "Bob holds no mailboxes".
        XCTAssertThrowsError(try listing(oneBusyAccount, account: "Bob")) { error in
            XCTAssertTrue("\(error)".contains("kept changing"), "\(error)")
        }
    }
}
