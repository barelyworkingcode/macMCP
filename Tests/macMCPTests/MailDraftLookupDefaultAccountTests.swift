import XCTest
@testable import macmcp

/// Cover for `mail_create_draft` finding the draft it just saved when the
/// caller named neither `account` nor `from`.
///
/// `savedDraftLookupJXA` walks the accounts and admits one only when its name
/// matches `account`, or one of its addresses matches `from`. With both nil,
/// `match` can never become true, every account is skipped, and the lookup
/// returns null — so `mail_create_draft` answers `{"status": "draft created",
/// "draft": null}` and, because `body_check` is keyed off `draft`, says nothing
/// at all about whether Mail actually rendered the body.
///
/// That is the default path: a caller with one account passes neither argument,
/// and it is the one path with no handle to the draft and no check on it. The
/// draft really is written — Mail files it in the account it composed from —
/// and its `text/plain` part really can come back empty, which is precisely
/// what `body_check` exists to report.
///
/// These run the generated lookup through the stub, because which account the
/// JavaScript agrees to look in is not visible from Swift.
final class MailDraftLookupDefaultAccountTests: XCTestCase {
    private func lookup(
        _ stub: String,
        account: String? = nil,
        from: String? = nil,
        subject: String = "Quarterly numbers"
    ) throws -> [String: Any]? {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(stub)
        \(MailService.savedDraftLookupJXA(account: account, from: from, subject: subject))
        JSON.stringify({draft: savedDraft});
        """)
        if payload["draft"] is NSNull { return nil }
        return payload["draft"] as? [String: Any]
    }

    /// One account, which is what a caller who passes no `account` has.
    private static let singleAccount = """
    var mail = makeMail({accounts: [{name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
        {name: 'INBOX', messages: [{id: 700, subject: 'unrelated'}]},
        {name: 'Drafts', messages: [
            {id: 900, subject: 'Older draft', messageId: 'older@relaytest.local'},
            {id: 901, subject: 'Quarterly numbers', messageId: 'quarterly@relaytest.local'}
        ]}
    ]}]});
    """

    /// Two accounts, with the draft in the second. A lookup that simply took
    /// the first account would pass the single-account test and still be wrong.
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Alice', emailAddresses: ['alice@relaytest.local'], mailboxes: [
            {name: 'Drafts', messages: [{id: 800, subject: 'Something else'}]}
        ]},
        {name: 'Bob', emailAddresses: ['bob@relaytest.local'], mailboxes: [
            {name: 'Drafts', messages: [
                {id: 901, subject: 'Quarterly numbers', messageId: 'quarterly@relaytest.local'}
            ]}
        ]}
    ]});
    """

    // MARK: - The defect

    func testADraftSavedWithoutNamingAnAccountIsStillFoundAfterwards() throws {
        // The default call: `mail_create_draft {to, subject, body}`. The draft
        // is in the only account there is, so there is nothing ambiguous about
        // where to look — and returning null here costs the caller both the
        // draft's id and `body_check`.
        let draft = try lookup(Self.singleAccount)
        XCTAssertNotNil(draft, "the saved draft was not found, so mail_create_draft reports draft: null and no body_check")
        XCTAssertEqual(draft?["message_id"] as? String, "901")
        XCTAssertEqual(draft?["rfc_message_id"] as? String, "quarterly@relaytest.local")
        XCTAssertEqual(draft?["account"] as? String, "Alice")
        XCTAssertEqual(draft?["mailbox"] as? String, "Drafts")
    }

    func testTheDraftIsFoundInWhicheverAccountHoldsItWhenNoAccountWasNamed() throws {
        // With more than one account the lookup has to find the one holding a
        // draft with this subject rather than settle on whichever Mail lists
        // first — the same collision that put a moved message in the wrong
        // account's Archive.
        let draft = try lookup(Self.twoAccounts)
        XCTAssertNotNil(draft, "the saved draft was not found in either account")
        XCTAssertEqual(draft?["account"] as? String, "Bob")
        XCTAssertEqual(draft?["message_id"] as? String, "901")
    }

    // MARK: - Controls that already pass, so a failure above is the defect

    func testNamingTheAccountFindsTheDraft() throws {
        let draft = try lookup(Self.singleAccount, account: "Alice")
        XCTAssertEqual(draft?["message_id"] as? String, "901")
    }

    func testNamingTheSenderAddressFindsTheDraft() throws {
        let draft = try lookup(Self.twoAccounts, from: "bob@relaytest.local")
        XCTAssertEqual(draft?["account"] as? String, "Bob")
        XCTAssertEqual(draft?["message_id"] as? String, "901")
    }

    func testASubjectNoDraftCarriesIsStillNotFound() throws {
        // The fallback must not turn "no such draft" into some other draft.
        XCTAssertNil(try lookup(Self.singleAccount, subject: "Never written"))
    }
}
