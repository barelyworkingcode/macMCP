import XCTest
@testable import macmcp

/// `scanScriptJXA`'s optional RFC Message-ID column, added for
/// `mail_get_emails`' `unreviewed_only` (`MailScanCache`).
///
/// The column has to be threaded through the same alignment invariant every
/// other column obeys (`sameLength`, and the per-row re-read in `reverify`),
/// or it reintroduces exactly the mispairing hazard the rest of this scan is
/// built to catch. Run through real `osascript` against the stub, because
/// that invariant lives in the generated JavaScript.
final class MailScanIncludeMessageIDTests: XCTestCase {
    private static let oneAccount = """
    var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
        {name: 'INBOX', messages: [
            {id: 1, messageId: '<one@relaytest.local>', subject: 'One', sender: 'a@b.c', date: 2000},
            {id: 2, messageId: '<two@relaytest.local>', subject: 'Two', sender: 'a@b.c', date: 1000}
        ]}
    ]}]});
    """

    private func scan(includeMessageID: Bool) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.oneAccount)
        \(MailService.scanScriptJXA(
            account: "Alice",
            mailbox: "INBOX",
            query: nil,
            searchRecipients: false,
            limit: 20,
            includeMessageID: includeMessageID
        ))
        """)
    }

    func testDefaultOmitsTheColumnEntirely() throws {
        let result = try scan(includeMessageID: false)
        let rows = result["rows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(row["rfc_message_id"], "existing callers must see no new key")
        }
    }

    func testIncludingItCarriesTheBareMessageIDOnEveryRow() throws {
        let result = try scan(includeMessageID: true)
        let rows = result["rows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as? String ?? "", $0) })
        XCTAssertEqual(byId["1"]?["rfc_message_id"] as? String, "one@relaytest.local")
        XCTAssertEqual(byId["2"]?["rfc_message_id"] as? String, "two@relaytest.local")
    }

    func testAMessageWithNoMessageIdReportsNullRatherThanCrashing() throws {
        let script = """
        \(MailStubJS.source)
        var mail = makeMail({accounts: [{name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 9, subject: 'No id', sender: 'a@b.c', date: 1000}]}
        ]}]});
        \(MailService.scanScriptJXA(
            account: "Alice",
            mailbox: "INBOX",
            query: nil,
            searchRecipients: false,
            limit: 20,
            includeMessageID: true
        ))
        """
        let result = try JXA.runJSON(script)
        let rows = result["rows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0]["rfc_message_id"] == nil || rows[0]["rfc_message_id"] is NSNull)
    }
}
