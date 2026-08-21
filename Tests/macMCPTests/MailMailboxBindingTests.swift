import XCTest
@testable import macmcp

/// Cover for how a mailbox is bound once it has been named (part of issue #50).
///
/// The same defect as the message binding, one level up: `boxes[i]` is a
/// positional specifier that JXA re-resolves on every access, so the mailbox a
/// script scans stops being the one whose name it read the moment the account's
/// mailbox list changes. Binding by name fixes that — but only where the name
/// identifies the mailbox, and in Mail it often does not.
///
/// Mail flattens an account's mailbox tree and reports leaf names, both measured
/// against the fixture after creating `Projects/Archive` and `Archive/Sub` over
/// IMAP:
///
/// * an account can hold **two** mailboxes called `Archive`, and they are two
///   different mailboxes with different messages in them;
/// * `mailboxes.byName('Sub')` for `Archive/Sub` gives a specifier whose
///   `exists()` is false, while the same mailbox reads fine by position.
///
/// So a name is used only when it is unique *and* resolves; anything else keeps
/// the positional specifier it came from. These pin both, because getting it
/// wrong silently drops a mailbox from every scan or merges two into one.
final class MailMailboxBindingTests: XCTestCase {
    private func scan(_ stub: String, mailbox: String) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.scanScriptJXA(
            account: "Bob",
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: 10
        ))
        """)
    }

    /// Bob as the fixture has him once the nested folders sync: two `Archive`s,
    /// and a `Sub` that `byName` cannot reach.
    private static let nested = """
    var mail = makeMail({accounts: [{name: 'Bob', mailboxes: [
        {name: 'Archive', messages: [{id: 10, subject: 'NESTED-ARCHIVE', date: 2000}]},
        {name: 'Projects', messages: []},
        {name: 'Sub', byNameHidden: true, messages: [{id: 11, subject: 'in the nested box', date: 3000}]},
        {name: 'Archive', messages: [{id: 12, subject: 'Decommission plan', date: 1000}]},
        {name: 'INBOX', messages: [{id: 13, subject: 'hello', date: 4000}]}
    ]}]});
    """

    func testAMailboxThatCannotBeReachedByItsNameIsStillScanned() throws {
        // `byName` answers with a specifier that does not exist. Using it would
        // drop the mailbox out of every scan, and the caller would be told an
        // empty mailbox rather than an unreadable one.
        let payload = try scan(Self.nested, mailbox: "Sub")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Sub"])
        XCTAssertEqual(payload["skipped"] as? [String] ?? [], [])
        let subjects = (payload["rows"] as? [[String: Any]] ?? []).map { $0["subject"] as? String ?? "" }
        XCTAssertEqual(subjects, ["in the nested box"])
    }

    func testTwoMailboxesOfTheSameNameAreReadAsTwo() throws {
        // Binding both by name would resolve both to whichever one `byName`
        // picks, so one mailbox's messages would be reported twice and the
        // other's not at all.
        let payload = try scan(Self.nested, mailbox: "Archive")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:Archive", "Bob:Archive"])
        let subjects = (payload["rows"] as? [[String: Any]] ?? [])
            .compactMap { $0["subject"] as? String }
            .sorted()
        XCTAssertEqual(subjects, ["Decommission plan", "NESTED-ARCHIVE"])
        XCTAssertEqual(payload["total"] as? Int, 2)
    }

    func testAnOrdinaryMailboxIsStillFoundAndScanned() throws {
        // The control: a unique name that does resolve, which is every mailbox
        // in an account with no nested folders.
        let payload = try scan(Self.nested, mailbox: "INBOX")
        XCTAssertEqual(payload["scanned"] as? [String] ?? [], ["Bob:INBOX"])
        XCTAssertEqual((payload["rows"] as? [[String: Any]] ?? []).count, 1)
    }
}
