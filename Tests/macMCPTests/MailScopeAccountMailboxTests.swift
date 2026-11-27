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

    // MARK: - Reviewer finding 1: senderJXA enforces draft destination on actual sender account

    private func runSender(
        from: String?,
        account: String?,
        scopeAccounts: [String]?,
        scopeMailboxes: [String]?,
        requiredMailbox: String? = "Drafts"
    ) throws -> (sender: String?, error: String?) {
        let snippet = MailService.senderJXA(
            from: from,
            account: account,
            scopeAccounts: scopeAccounts,
            scopeMailboxes: scopeMailboxes,
            requiredMailbox: requiredMailbox
        )
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        var out;
        try {
            \(snippet.lines)
            out = {sender: senderAddr, error: null};
        } catch (e) {
            out = {sender: null, error: '' + (e && e.message ? e.message : e)};
        }
        JSON.stringify(out);
        """)
        return (payload["sender"] as? String, payload["error"] as? String)
    }

    func testSenderJXARefusesPersonalFromWhenOnlyWorkDraftsGranted() throws {
        // `from` takes precedence over `account`: even when `account: "Work"`
        // is also passed, a Personal `from` resolves to Personal and must be
        // refused before any OutgoingMessage is created.
        let refused = try runSender(
            from: "me@personal.example",
            account: "Work",
            scopeAccounts: ["Personal", "Work"],
            scopeMailboxes: ["Work/Drafts"]
        )
        XCTAssertNil(refused.sender)
        let split = MailScopeRefusal.split(refused.error ?? "")
        XCTAssertTrue(split.violation, split.message)
        XCTAssertTrue(split.message.contains("Personal"), split.message)

        // Work `from` is allowed.
        let allowed = try runSender(
            from: "me@work.example",
            account: nil,
            scopeAccounts: ["Personal", "Work"],
            scopeMailboxes: ["Work/Drafts"]
        )
        XCTAssertNil(allowed.error)
        XCTAssertEqual(allowed.sender, "me@work.example")

        // Wildcard `mail_accounts` with `Work/Drafts`: Personal `from` refused,
        // and omitted `from`/`account` resolves to Work instead of Mail's default.
        let wildcardRefused = try runSender(
            from: "me@personal.example",
            account: nil,
            scopeAccounts: nil,
            scopeMailboxes: ["Work/Drafts"]
        )
        XCTAssertTrue(MailScopeRefusal.split(wildcardRefused.error ?? "").violation)

        let wildcardOmitted = try runSender(
            from: nil,
            account: nil,
            scopeAccounts: nil,
            scopeMailboxes: ["Work/Drafts"]
        )
        XCTAssertNil(wildcardOmitted.error)
        XCTAssertEqual(wildcardOmitted.sender, "me@work.example")
    }

    // MARK: - Reviewer finding 2: wildcard mail_accounts resolves qualifiers against live accounts

    private static let wildcardCollisionAccounts = """
    var mail = makeMail({accounts: [
        {name: 'Personal', emailAddresses: ['me@personal.example'], mailboxes: [
            {name: 'INBOX', messages: [{id: 300, messageId: 'p-inbox@example', subject: 'Personal inbox', date: 4000}]},
            {name: 'Work'},
            {name: 'INBOX', container: 'Work', messages: [{id: 301, messageId: 'p-work-inbox@example', subject: 'Literal Work/INBOX in Personal', date: 3500}]}
        ]},
        {name: 'Work', emailAddresses: ['me@work.example'], mailboxes: [
            {name: 'INBOX', messages: [{id: 400, messageId: 'w-inbox@example', subject: 'Work inbox', date: 4500}]}
        ]}
    ]});
    """

    func testWildcardAccountsResolvesAccountQualifierAgainstLiveAccountsAndBlocksCollision() throws {
        // Under mail_accounts: ["*"] (`scopeAccounts: nil`) and
        // mail_mailboxes: ["Work/INBOX"], `Personal` holds a literal nested
        // mailbox `Work/INBOX` and `Work` holds `INBOX`. `Work/INBOX` must
        // resolve against live account names to Work's INBOX and refuse
        // Personal's literal `Work/INBOX` folder.
        let personalScan = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.wildcardCollisionAccounts)
        \(MailService.scanScriptJXA(
            account: "Personal",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeAccounts: nil,
            scopeMailboxes: ["Work/INBOX"]
        ))
        """)
        XCTAssertEqual(personalScan["scanned"] as? [String] ?? [], [])

        let workScan = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.wildcardCollisionAccounts)
        \(MailService.scanScriptJXA(
            account: "Work",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeAccounts: nil,
            scopeMailboxes: ["Work/INBOX"]
        ))
        """)
        XCTAssertEqual(workScan["scanned"] as? [String] ?? [], ["Work:INBOX"])

        let findPersonalCollision = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.wildcardCollisionAccounts)
        \(MailService.findMessageJXA(
            account: nil,
            mailbox: "Work/INBOX",
            messageId: "301",
            scopeAccounts: nil,
            scopeMailboxes: ["Work/INBOX"]
        ))
        JSON.stringify({bound: found === null ? null : ('' + found.id()), outOfScope: FM_OUT_OF_SCOPE});
        """)
        XCTAssertNil(findPersonalCollision["bound"] as? String)
        XCTAssertEqual(findPersonalCollision["outOfScope"] as? Bool, true)

        let findWorkInbox = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.wildcardCollisionAccounts)
        \(MailService.findMessageJXA(
            account: nil,
            mailbox: "INBOX",
            messageId: "400",
            scopeAccounts: nil,
            scopeMailboxes: ["Work/INBOX"]
        ))
        JSON.stringify({bound: found === null ? null : ('' + found.id()), outOfScope: FM_OUT_OF_SCOPE});
        """)
        XCTAssertEqual(findWorkInbox["bound"] as? String, "400")
        XCTAssertEqual(findWorkInbox["outOfScope"] as? Bool, false)
    }

    // MARK: - Reviewer round-2 findings

    func testThrowingLiveAccountNamesFailsClosedForQualifiedRule() throws {
        // When `mail_accounts` is wildcard (`scopeAccounts: nil`) and
        // `mail.accounts.name()` throws, `Work/INBOX` cannot be disambiguated
        // and must fail closed (matching neither Work:INBOX nor a literal
        // Personal:Work/INBOX).
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.wildcardCollisionAccounts)
        mail.accounts.name = function() { throw new Error('account catalog unavailable'); };
        \(MailService.scopeFoldJXA)
        \(MailService.scopeMailboxAllowsJXA)
        var rules = \(MailService.scopeMailboxRulesJXA(["Work/INBOX"], scopeAccounts: nil));
        JSON.stringify({
            personalLiteral: scopeMailboxAllows(rules, 'Personal', 'Work/INBOX'),
            personalInbox: scopeMailboxAllows(rules, 'Personal', 'INBOX'),
            workInbox: scopeMailboxAllows(rules, 'Work', 'INBOX')
        });
        """)
        XCTAssertEqual(payload["personalLiteral"] as? Bool, false)
        XCTAssertEqual(payload["personalInbox"] as? Bool, false)
        XCTAssertEqual(payload["workInbox"] as? Bool, false)
    }

    func testSharedAliasRefusesQualifiedDraftsWhenOtherOwnerIsNotAllowed() throws {
        let sharedAliasMail = """
        var mail = makeMail({accounts: [
            {name: 'Work', emailAddresses: ['shared@example'], mailboxes: [{name: 'Drafts'}]},
            {name: 'Personal', emailAddresses: ['shared@example'], mailboxes: [{name: 'Drafts'}]}
        ]});
        """
        let snippet = MailService.senderJXA(
            from: "shared@example",
            account: nil,
            scopeAccounts: ["Personal", "Work"],
            scopeMailboxes: ["Work/Drafts"],
            requiredMailbox: "Drafts"
        )
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(sharedAliasMail)
        var out;
        try {
            \(snippet.lines)
            out = {sender: senderAddr, error: null};
        } catch (e) {
            out = {sender: null, error: '' + (e && e.message ? e.message : e)};
        }
        JSON.stringify(out);
        """)
        XCTAssertNil(payload["sender"] as? String)
        let split = MailScopeRefusal.split(payload["error"] as? String ?? "")
        XCTAssertTrue(split.violation, split.message)
        XCTAssertTrue(split.message.contains("ambiguous"), split.message)
        XCTAssertFalse(split.message.contains("Personal"), "refusal must not disclose other account names: \(split.message)")
    }

    func testUnreadExcludedAccountEmailAddressesFailsClosedWithoutDisclosingAccountName() throws {
        let throwingOtherMail = """
        var mail = makeMail({accounts: [
            {name: 'Work', emailAddresses: ['work@example'], mailboxes: [{name: 'Drafts'}]},
            {name: 'Personal', emailAddresses: ['personal@example'], mailboxes: [{name: 'Drafts'}]}
        ]});
        var origAccounts = mail.accounts;
        mail.accounts = function() {
            var list = origAccounts();
            list[1].emailAddresses = function() { throw new Error('account busy'); };
            return list;
        };
        """
        let snippet = MailService.senderJXA(
            from: "work@example",
            account: nil,
            scopeAccounts: ["Personal", "Work"],
            scopeMailboxes: ["Work/Drafts"],
            requiredMailbox: "Drafts"
        )
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(throwingOtherMail)
        var out;
        try {
            \(snippet.lines)
            out = {sender: senderAddr, error: null};
        } catch (e) {
            out = {sender: null, error: '' + (e && e.message ? e.message : e)};
        }
        JSON.stringify(out);
        """)
        XCTAssertNil(payload["sender"] as? String)
        let err = payload["error"] as? String ?? ""
        XCTAssertTrue(err.contains("could not verify"), err)
        XCTAssertFalse(err.contains("Personal"), "error must not disclose excluded account name: \(err)")
    }

    func testWildcardGreekSigmaQualifierMatchesLiveAccountAndBlocksLiteralCollision() throws {
        // Live account `ΟΣ` vs rule `οσ/INBOX` under wildcard `mail_accounts`:
        // JXA must match `ΟΣ:INBOX` and must NOT turn `οσ/INBOX` into a plain
        // grant that admits a literal `Personal:οσ/INBOX` folder.
        let greekCollisionMail = """
        var mail = makeMail({accounts: [
            {name: 'ΟΣ', emailAddresses: ['os@example'], mailboxes: [
                {name: 'INBOX', messages: [{id: 600, messageId: 'os-inbox@example', subject: 'Greek inbox', date: 2000}]}
            ]},
            {name: 'Personal', emailAddresses: ['p@example'], mailboxes: [
                {name: 'οσ'},
                {name: 'INBOX', container: 'οσ', messages: [{id: 601, messageId: 'p-lit@example', subject: 'Literal collision', date: 1000}]}
            ]}
        ]});
        """
        let greekScan = try JXA.runJSON("""
        \(MailStubJS.source)
        \(greekCollisionMail)
        \(MailService.scanScriptJXA(
            account: "ΟΣ",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeAccounts: nil,
            scopeMailboxes: ["οσ/INBOX"]
        ))
        """)
        XCTAssertEqual(greekScan["scanned"] as? [String] ?? [], ["ΟΣ:INBOX"])

        let personalScan = try JXA.runJSON("""
        \(MailStubJS.source)
        \(greekCollisionMail)
        \(MailService.scanScriptJXA(
            account: "Personal",
            mailbox: "all",
            query: nil,
            searchRecipients: false,
            limit: 20,
            scopeAccounts: nil,
            scopeMailboxes: ["οσ/INBOX"]
        ))
        """)
        XCTAssertEqual(personalScan["scanned"] as? [String] ?? [], [])
    }

    func testWildcardAutoSelectedDraftSenderIsEnforcedByPreSendGuard() throws {
        // Under wildcard `mail_accounts` (`scopeAccounts: nil`) and
        // `mail_mailboxes: ["Work/Drafts"]`, `senderJXA` auto-selects Work's
        // address. With `senderResolved: true`, `preSendGuardJXA` must abort if
        // Mail substitutes Personal's sender on the outgoing message.
        let senderSnippet = MailService.senderJXA(
            from: nil,
            account: nil,
            scopeAccounts: nil,
            scopeMailboxes: ["Work/Drafts"],
            requiredMailbox: "Drafts"
        )
        let guardSnippet = MailService.preSendGuardJXA(
            to: ["dest@example"],
            cc: [],
            bcc: [],
            subject: "Test",
            from: nil,
            account: nil,
            senderResolved: true
        )
        let payload = try JXA.runJSON("""
        \(MailStubJS.source)
        \(Self.twoAccounts)
        \(senderSnippet.lines)
        var msg = {
            toRecipients: function() { return [{address: function() { return 'dest@example'; }}]; },
            ccRecipients: function() { return []; },
            bccRecipients: function() { return []; },
            subject: function() { return 'Test'; },
            sender: function() { return 'me@personal.example'; },
            close: function() {}
        };
        var out;
        try {
            \(guardSnippet)
            out = {aborted: false, error: null};
        } catch (e) {
            out = {aborted: true, error: '' + (e && e.message ? e.message : e)};
        }
        JSON.stringify(out);
        """)
        XCTAssertEqual(payload["aborted"] as? Bool, true)
        let err = payload["error"] as? String ?? ""
        XCTAssertTrue(err.contains("me@personal.example"), err)
        XCTAssertTrue(err.contains("me@work.example"), err)
    }

    // MARK: - Reviewer finding 3: scalar slash split

    func testSplitFirstSlashSplitsBeforeCombiningMark() {
        let rules = MailScope.parseMailboxRules(
            ["Work/\u{0301}INBOX"],
            allowedAccounts: ["Work"]
        )
        XCTAssertEqual(rules, [
            MailScope.MailMailboxRule(account: "Work", mailbox: "\u{0301}INBOX")
        ])
    }
}
