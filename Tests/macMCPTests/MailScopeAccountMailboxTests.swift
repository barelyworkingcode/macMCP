import Foundation
import XCTest
@testable import macmcp

/// Tests for account-qualified `Account/Mailbox` entries in `mail_mailboxes`
/// and slash-ambiguity resolution against mailbox paths that themselves contain
/// `/` (such as `[Gmail]/All Mail`).
final class MailScopeAccountMailboxTests: XCTestCase {
    /// Two accounts (`Personal` and `Work`) with overlapping mailbox names
    /// (`INBOX`, `Work`, `[Gmail]/All Mail`) plus `Work:Archive`.
    private static let twoAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Personal', emailAddresses: ['me@personal.example'], mailboxes: [
            {name: 'INBOX', messages: [{id: 200, messageId: 'personal-inbox@example', subject: 'Personal inbox', date: 4000}]},
            {name: 'Work', messages: [{id: 201, messageId: 'personal-work@example', subject: 'Personal work folder', date: 3000}]},
            {name: '[Gmail]'},
            {name: 'All Mail', container: '[Gmail]', messages: [{id: 202, messageId: 'personal-all@example', subject: 'Personal all mail', date: 2000}]}
        ]},
        {name: 'Work', emailAddresses: ['me@work.example'], mailboxes: [
            {name: 'INBOX', messages: [{id: 100, messageId: 'work-inbox@example', subject: 'Work inbox', date: 4500}]},
            {name: 'Work', messages: [{id: 101, messageId: 'work-folder@example', subject: 'Work folder', date: 3500}]},
            {name: '[Gmail]'},
            {name: 'All Mail', container: '[Gmail]', messages: [{id: 102, messageId: 'work-all@example', subject: 'Work all mail', date: 2500}]},
            {name: 'Archive', messages: [{id: 103, messageId: 'work-archive@example', subject: 'Work archive', date: 1500}]}
        ]}
    ]});
    """

    private static let acceptanceAccounts = ["Personal", "Work"]
    private static let acceptanceMailboxes = ["Work", "Work/INBOX", "Work/[Gmail]/All Mail"]

    // MARK: - Pure parsing & slash ambiguity

    func testParseSplitsAtFirstSlashOnlyWhenPrefixMatchesAllowedAccount() {
        let rules = MailScope.parseMailboxRules(
            ["Work", "Work/INBOX", "Work/[Gmail]/All Mail", "[Gmail]/All Mail", "Other/INBOX", "Work/"],
            allowedAccounts: ["Personal", "Work"]
        )
        XCTAssertEqual(rules, [
            MailScope.MailMailboxRule(account: nil, mailbox: "Work"),
            MailScope.MailMailboxRule(account: "Work", mailbox: "INBOX"),
            MailScope.MailMailboxRule(account: "Work", mailbox: "[Gmail]/All Mail"),
            MailScope.MailMailboxRule(account: nil, mailbox: "[Gmail]/All Mail"),
            MailScope.MailMailboxRule(account: nil, mailbox: "Other/INBOX"),
            MailScope.MailMailboxRule(account: nil, mailbox: "Work/")
        ])
    }

    func testParseFoldsCaseAndUnicodeWhenMatchingAccountPrefix() {
        // NFC account name in mail_accounts, NFD lowercase prefix in mail_mailboxes.
        let rules = MailScope.parseMailboxRules(
            ["cafe\u{0301}/INBOX", "work/[Gmail]/All Mail"],
            allowedAccounts: ["Caf\u{00E9}", "Work"]
        )
        XCTAssertEqual(rules, [
            MailScope.MailMailboxRule(account: "cafe\u{0301}", mailbox: "INBOX"),
            MailScope.MailMailboxRule(account: "work", mailbox: "[Gmail]/All Mail")
        ])
    }

    func testParseDoesNotSplitWhenAllowedAccountsIsNil() {
        // Under mail_accounts: ["*"], there is no concrete list of allowed account names.
        let rules = MailScope.parseMailboxRules(["Work/INBOX", "[Gmail]/All Mail"], allowedAccounts: nil)
        XCTAssertEqual(rules, [
            MailScope.MailMailboxRule(account: nil, mailbox: "Work/INBOX"),
            MailScope.MailMailboxRule(account: nil, mailbox: "[Gmail]/All Mail")
        ])
    }

    func testStarStaysTheOnlyWildcard() {
        let scope = MailScope.parse([
            "mail_accounts": .array([.string("Personal"), .string("Work")]),
            "mail_mailboxes": .array([.string("Work/*")])
        ])
        XCTAssertEqual(scope.mailboxesAccess, .allowed(["Work/*"]))
        guard case .refuse = scope.mailboxTargets(requested: "INBOX", account: "Work") else {
            return XCTFail("Work/* must not act as a wildcard")
        }
    }

    // MARK: - Swift reconciliation

    func testMailboxTargetsRespectsAccountQualifiedEntries() {
        let scope = MailScope.parse([
            "mail_accounts": .array(Self.acceptanceAccounts.map(JSONValue.string)),
            "mail_mailboxes": .array(Self.acceptanceMailboxes.map(JSONValue.string))
        ])

        // Personal/INBOX and Personal/[Gmail]/All Mail are refused.
        guard case .refuse = scope.mailboxTargets(requested: "INBOX", account: "Personal") else {
            return XCTFail("Personal/INBOX must be refused")
        }
        guard case .refuse = scope.mailboxTargets(requested: "[Gmail]/All Mail", account: "Personal") else {
            return XCTFail("Personal/[Gmail]/All Mail must be refused")
        }

        // Plain entry "Work" still matches Personal.
        XCTAssertEqual(
            scope.mailboxTargets(requested: "Work", account: "Personal"),
            .use(Self.acceptanceMailboxes)
        )

        // Work/INBOX, Work/[Gmail]/All Mail, and leaf fallback "All Mail" are allowed on Work.
        XCTAssertEqual(
            scope.mailboxTargets(requested: "INBOX", account: "Work"),
            .use(Self.acceptanceMailboxes)
        )
        XCTAssertEqual(
            scope.mailboxTargets(requested: "[Gmail]/All Mail", account: "Work"),
            .use(Self.acceptanceMailboxes)
        )
        XCTAssertEqual(
            scope.mailboxTargets(requested: "All Mail", account: "Work"),
            .use(Self.acceptanceMailboxes)
        )

        // With account omitted, INBOX is reachable (on Work); per-account filtering happens in JXA.
        XCTAssertEqual(
            scope.mailboxTargets(requested: "INBOX", account: nil),
            .use(Self.acceptanceMailboxes)
        )
    }

    func testScopeRefusalPairsMailboxArgumentWithItsAccount() {
        let call = MailCall.forArguments(nil, default: 30, meta: [
            "mail_accounts": .array(Self.acceptanceAccounts.map(JSONValue.string)),
            "mail_mailboxes": .array(Self.acceptanceMailboxes.map(JSONValue.string))
        ])

        let refusedGet = MailService.scopeRefusal(
            for: MCPCallContext(
                arguments: ["account": .string("Personal"), "mailbox": .string("INBOX")],
                toolName: "mail_get_emails"
            ),
            call: call
        )
        XCTAssertEqual(refusedGet?.meta?["scope_violation"], .bool(true))

        let allowedGet = MailService.scopeRefusal(
            for: MCPCallContext(
                arguments: ["account": .string("Work"), "mailbox": .string("INBOX")],
                toolName: "mail_get_emails"
            ),
            call: call
        )
        XCTAssertNil(allowedGet)

        let refusedMove = MailService.scopeRefusal(
            for: MCPCallContext(
                arguments: [
                    "message_id": .int(100),
                    "target_account": .string("Personal"),
                    "target_mailbox": .string("INBOX")
                ],
                toolName: "mail_move"
            ),
            call: call,
            accountKeys: ["account", "target_account"],
            mailboxKeys: ["source_mailbox", "target_mailbox"]
        )
        XCTAssertEqual(refusedMove?.meta?["scope_violation"], .bool(true))
    }

    func testDraftDestinationRefusalRespectsAccountQualifiedDrafts() {
        let call = MailCall(budget: 30, scope: MailScope.parse([
            "mail_accounts": .array([.string("Personal"), .string("Work")]),
            "mail_mailboxes": .array([.string("Work/Drafts")])
        ]))
        XCTAssertNil(MailService.draftDestinationRefusal(call: call, account: "Work"))
        let refused = MailService.draftDestinationRefusal(call: call, account: "Personal")
        XCTAssertEqual(refused?.meta?["scope_violation"], .bool(true))
    }

    // MARK: - JXA enforcement: scanScriptJXA

    private func scan(
        account: String,
        mailbox: String,
        scopeAccounts: [String]?,
        scopeMailboxes: [String]?
    ) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.scanScriptJXA(
            account: account,
            mailbox: mailbox,
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes
        ))
        """)
    }

    func testScanAcceptsWorkInboxAndRefusesPersonalInbox() throws {
        let personalAll = try scan(
            account: "Personal",
            mailbox: "all",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(personalAll["scanned"] as? [String] ?? [], ["Personal:Work"])

        let personalInbox = try scan(
            account: "Personal",
            mailbox: "INBOX",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(personalInbox["scanned"] as? [String] ?? [], [])

        let workAll = try scan(
            account: "Work",
            mailbox: "all",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(
            Set(workAll["scanned"] as? [String] ?? []),
            ["Work:INBOX", "Work:Work", "Work:[Gmail]/All Mail"]
        )

        let workAllMail = try scan(
            account: "Work",
            mailbox: "[Gmail]/All Mail",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(workAllMail["scanned"] as? [String] ?? [], ["Work:[Gmail]/All Mail"])
    }

    func testScanPlainEntriesKeepCrossProductBehaviour() throws {
        let personal = try scan(
            account: "Personal",
            mailbox: "all",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: ["INBOX", "[Gmail]/All Mail"]
        )
        XCTAssertEqual(
            Set(personal["scanned"] as? [String] ?? []),
            ["Personal:INBOX", "Personal:[Gmail]/All Mail"]
        )

        let work = try scan(
            account: "Work",
            mailbox: "all",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: ["INBOX", "[Gmail]/All Mail"]
        )
        XCTAssertEqual(
            Set(work["scanned"] as? [String] ?? []),
            ["Work:INBOX", "Work:[Gmail]/All Mail"]
        )
    }

    // MARK: - JXA enforcement: findMessageJXA

    private func find(
        messageId: String,
        mailbox: String = "INBOX",
        scopeAccounts: [String]?,
        scopeMailboxes: [String]?
    ) throws -> [String: Any] {
        try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.findMessageJXA(
            account: nil,
            mailbox: mailbox,
            messageId: messageId,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes
        ))
        JSON.stringify({
            bound: found === null ? null : ('' + found.id()),
            account: foundAccount,
            mailbox: foundMailbox,
            outOfScope: FM_OUT_OF_SCOPE
        });
        """)
    }

    func testFindMessageRefusesPersonalInboxAndAllowsWorkInboxAndAllMail() throws {
        let personalInbox = try find(
            messageId: "200",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertNil(personalInbox["bound"] as? String)
        XCTAssertEqual(personalInbox["outOfScope"] as? Bool, true)

        let personalWork = try find(
            messageId: "201",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(personalWork["bound"] as? String, "201")
        XCTAssertEqual(personalWork["account"] as? String, "Personal")
        XCTAssertEqual(personalWork["mailbox"] as? String, "Work")

        let workInbox = try find(
            messageId: "100",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(workInbox["bound"] as? String, "100")
        XCTAssertEqual(workInbox["account"] as? String, "Work")
        XCTAssertEqual(workInbox["mailbox"] as? String, "INBOX")

        let workAllMail = try find(
            messageId: "102",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(workAllMail["bound"] as? String, "102")
        XCTAssertEqual(workAllMail["account"] as? String, "Work")
        XCTAssertEqual(workAllMail["mailbox"] as? String, "[Gmail]/All Mail")

        // RFC Message-ID search never touches Personal:INBOX, but finds Work:INBOX.
        let rfcPersonal = try find(
            messageId: "<personal-inbox@example>",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertNil(rfcPersonal["bound"] as? String)
        XCTAssertEqual(rfcPersonal["outOfScope"] as? Bool, false)

        let rfcWork = try find(
            messageId: "<work-inbox@example>",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        )
        XCTAssertEqual(rfcWork["bound"] as? String, "100")
    }

    // MARK: - JXA enforcement: listMailboxesScriptJXA

    func testListMailboxesFiltersPerAccount() throws {
        let allPayload = try JXA.run("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.listMailboxesScriptJXA(
            account: nil,
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        ))
        """)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(allPayload.utf8)) as? [[String: Any]]
        )
        let byAccount = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String])? in
            guard let acct = row["account"] as? String,
                  let boxes = row["mailboxes"] as? [String] else { return nil }
            return (acct, boxes)
        })
        XCTAssertEqual(byAccount["Personal"], ["Work"])
        XCTAssertEqual(Set(byAccount["Work"] ?? []), ["INBOX", "Work", "[Gmail]/All Mail"])

        let personalOnly = try JXA.run("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.listMailboxesScriptJXA(
            account: "Personal",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        ))
        """)
        let personalBoxes = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(personalOnly.utf8)) as? [String]
        )
        XCTAssertEqual(personalBoxes, ["Work"])
    }

    // MARK: - JXA enforcement: moveScriptJXA

    func testMoveRefusesCrossAccountMoveIntoUnqualifiedAccountInbox() throws {
        let refusedPayload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.moveScriptJXA(
            messageId: "100",
            sourceMailbox: "INBOX",
            targetMailbox: "INBOX",
            account: "Work",
            targetAccount: "Personal",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), moves: mail.log.moves});
        """)
        let refusedResult = refusedPayload["result"] as? [String: Any] ?? [:]
        let refusedMoves = refusedPayload["moves"] as? [[String: Any]] ?? []
        XCTAssertEqual(refusedMoves.count, 0)
        let split = MailScopeRefusal.split(refusedResult["error"] as? String ?? "")
        XCTAssertTrue(split.violation, split.message)
        XCTAssertTrue(split.message.contains("Personal:INBOX"), split.message)

        // Moving into Personal:Work (plain entry) succeeds.
        let allowedPayload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(MailService.moveScriptJXA(
            messageId: "100",
            sourceMailbox: "INBOX",
            targetMailbox: "Work",
            account: "Work",
            targetAccount: "Personal",
            scopeAccounts: Self.acceptanceAccounts,
            scopeMailboxes: Self.acceptanceMailboxes
        ))
        JSON.stringify({result: JSON.parse(JSON.stringify(moveResult)), moves: mail.log.moves});
        """)
        let allowedResult = allowedPayload["result"] as? [String: Any] ?? [:]
        let allowedMoves = allowedPayload["moves"] as? [[String: Any]] ?? []
        XCTAssertEqual(allowedMoves.count, 1)
        XCTAssertEqual(allowedResult["status"] as? String, "moved")
        XCTAssertEqual(allowedResult["account"] as? String, "Personal")
        XCTAssertEqual(allowedResult["mailbox"] as? String, "Work")
    }
}
