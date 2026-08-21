import XCTest
@testable import macmcp

/// Cover for Mail's app-level mailboxes being scanned but never named
/// (issue #54).
///
/// `mail_list_mailboxes` enumerated `mail.accounts()` and nothing else, while
/// `mail.mailboxes()` on the same machine held `Recovered Messages (Alice)`,
/// `SendLater`, `Outbox` and `Deleted Messages`. The scan covers those and
/// labels their rows `On My Mac:<mailbox>` — so a caller could be handed a row
/// from a mailbox the only enumeration tool said did not exist, and could not
/// ask for it by name.
///
/// Naming them is only half of it. `account: "On My Mac"` reached
/// `resolveTargets`, which passed the string through to a scope lookup that
/// walks `mail.accounts()`, so scoping to those mailboxes threw `account not
/// found`. That matters beyond the cosmetic gap: relay's resource scoping
/// cannot scope what the enumeration does not name, and naming something that
/// then cannot be asked for is worse than not naming it.
final class MailLocalMailboxTests: XCTestCase {
    /// One account and two mailboxes belonging to no account, which is what
    /// Mail looks like on any machine that has ever recovered a message.
    private static let withLocalBoxes = """
    var mail = makeMail({
        accounts: [{name: 'Alice', mailboxes: [
            {name: 'INBOX', messages: [{id: 1, subject: 'from the server', date: 1000}]}
        ]}],
        local: [
            {name: 'SendLater', messages: [{id: 90, subject: 'queued locally', date: 2000}]},
            {name: 'Recovered Messages (Alice)', messages: [{id: 91, subject: 'recovered', date: 3000}]}
        ]
    });
    """

    func testTheNameTheScanUsesIsOneEveryToolAccepts() {
        XCTAssertTrue(MailService.isLocalAccount("On My Mac"))
        XCTAssertTrue(MailService.isLocalAccount("on my mac"), "account names match case-insensitively everywhere else")
        XCTAssertFalse(MailService.isLocalAccount("Alice"))
        XCTAssertEqual(MailService.localAccountName, "On My Mac", "this is the label scanScriptJXA already puts on those rows")
    }

    func testScopingToOnMyMacIsTheLocalPassRatherThanAnAccountLookup() {
        // `nil` is the local pass. Passing the string through instead is what
        // made `account: "On My Mac"` throw `account not found`.
        let (targets, error) = MailService.resolveTargets(account: "On My Mac")
        XCTAssertNil(error)
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(targets[0])

        let (named, namedError) = MailService.resolveTargets(account: "Alice")
        XCTAssertNil(namedError)
        XCTAssertEqual(named, ["Alice"])
    }

    func testAScanScopedToOnMyMacReadsTheLocalMailboxes() throws {
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.withLocalBoxes)
        \(MailService.scanScriptJXA(
            account: MailService.localAccountName,
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 10
        ))
        """)
        XCTAssertEqual(
            (payload["scanned"] as? [String] ?? []).sorted(),
            ["On My Mac:Recovered Messages (Alice)", "On My Mac:SendLater"]
        )
        let subjects = (payload["rows"] as? [[String: Any]] ?? []).compactMap { $0["subject"] as? String }.sorted()
        XCTAssertEqual(subjects, ["queued locally", "recovered"])
    }

    func testAMessageInALocalMailboxIsFoundUnderThatAccountName() throws {
        // The mailbox raises on `.account`, having none, which is how the by-id
        // lookup tells a local mailbox from an account's.
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.withLocalBoxes)
        \(MailService.findMessageJXA(account: MailService.localAccountName, mailbox: "SendLater", messageId: "90"))
        JSON.stringify({account: foundAccount, mailbox: foundMailbox, subject: '' + found.subject()});
        """)
        XCTAssertEqual(payload["account"] as? String, "On My Mac")
        XCTAssertEqual(payload["mailbox"] as? String, "SendLater")
        XCTAssertEqual(payload["subject"] as? String, "queued locally")
    }

    func testOnMyMacStillScopesOutAnAccountsMessages() throws {
        // Naming it must not turn it into "everywhere". Id 1 is Alice's.
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.withLocalBoxes)
        \(MailService.findMessageJXA(account: MailService.localAccountName, mailbox: "INBOX", messageId: "1"))
        JSON.stringify({missed: found === null});
        """)
        XCTAssertEqual(payload["missed"] as? Bool, true)
    }

    func testAnAccountThatReallyIsMissingIsStillReported() throws {
        // The name is accepted because Mail's local boxes exist, not because
        // account checking was dropped.
        XCTAssertThrowsError(
            try JXA.runJSON("""
            \(MailStubJS.source)
            \(Self.withLocalBoxes)
            \(MailService.findMessageJXA(account: "Zed", mailbox: "INBOX", messageId: "1"))
            JSON.stringify({});
            """)
        ) { error in
            XCTAssertEqual(
                MailService.scriptErrorMessage((error as? JXA.Failure)?.stderr ?? ""),
                "account not found: Zed"
            )
        }
    }
}
