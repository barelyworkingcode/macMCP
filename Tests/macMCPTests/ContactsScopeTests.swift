import XCTest
@testable import macmcp

/// What the contacts resource scope actually *does*, at every seam ADR-011
/// names for the ten `contacts_*` tools.
///
/// **The two fields do not bound the same thing, and most of this file is
/// about that.** `contact_accounts` bounds cards -- every card in a named
/// account is reachable, group or no group -- and `contact_groups` bounds
/// groups, governing only the four tools that cannot function without naming
/// one. The first pass gave both `applies_to: ["contacts_*"]`, copying mail's
/// shape, and the enforcement faithfully implemented it: a card was reachable
/// only as a member of a group in scope, which made account-level scoping
/// inexpressible. A message is always in a mailbox; a card need not be in a
/// group.
///
/// **Contacts cannot be driven from a hermetic test.** There is no stub
/// `CNContactStore`, and touching the real one reads the user's own address
/// book -- which is exactly what the rest of this suite refuses to do. So the
/// enforcement is built the way `MailService`'s was: the framework reads
/// (`accountCatalog`, `groupCatalog`, `cards(in:)`, the container probe) do
/// nothing but read, and every decision they feed -- which accounts and groups
/// a scope selects, which handle a
/// caller may act on, what a refusal says, whether it carries
/// `scope_violation` -- is a pure function taking data and returning data.
/// Those are what is tested here.
///
/// **The negatives are the point.** A scope that admits what it should admit
/// and also everything else passes every positive test there is, so each
/// enforcement point is asserted in both directions.
///
/// What no test here can reach, and what a live store is needed for, is listed
/// at the bottom of this file.
final class ContactsScopeTests: XCTestCase {
    /// Two accounts, both holding a group called `Family`, plus a second
    /// `Work` in one of them so a leaf name is not enough to identify a group
    /// and the tests can say so.
    private let catalog: [ContactGroupRef] = [
        ContactGroupRef(account: "iCloud", name: "Family", identifier: "g-icloud-family", containerIdentifier: "c-icloud"),
        ContactGroupRef(account: "iCloud", name: "Work", identifier: "g-icloud-work", containerIdentifier: "c-icloud"),
        ContactGroupRef(account: "On My Mac", name: "Family", identifier: "g-local-family", containerIdentifier: "c-local"),
        ContactGroupRef(account: "Exchange", name: "Team", identifier: "g-exchange-team", containerIdentifier: "c-exchange")
    ]

    /// The containers those groups live in, plus one holding no group at all --
    /// which is the account a card can be in without being in any group, and
    /// therefore the case the old shape could not express.
    private let accounts: [ContactAccountRef] = [
        ContactAccountRef(name: "iCloud", identifier: "c-icloud"),
        ContactAccountRef(name: "On My Mac", identifier: "c-local"),
        ContactAccountRef(name: "Exchange", identifier: "c-exchange"),
        ContactAccountRef(name: "Groupless", identifier: "c-groupless")
    ]

    /// The ten tools this branch had to cover, as `main.swift` registers them.
    private let allTools = [
        "contacts_list", "contacts_get", "contacts_create", "contacts_update", "contacts_delete",
        "contacts_list_groups", "contacts_create_group", "contacts_add_to_group",
        "contacts_remove_from_group", "contacts_search_by_phone"
    ]

    /// The four `contact_groups` governs: they cannot function without naming
    /// a group.
    private let groupTools = [
        "contacts_list_groups", "contacts_create_group",
        "contacts_add_to_group", "contacts_remove_from_group"
    ]

    /// The six bounded by `contact_accounts` alone.
    private let cardTools = [
        "contacts_list", "contacts_get", "contacts_create",
        "contacts_update", "contacts_delete", "contacts_search_by_phone"
    ]

    private func scope(accounts: [String]?, groups: [String]?) -> ResourceScope {
        var meta: JSONObject = ["project_id": .string("prof_test")]
        if let accounts { meta["contact_accounts"] = .array(accounts.map { .string($0) }) }
        if let groups { meta["contact_groups"] = .array(groups.map { .string($0) }) }
        return ResourceScope.parse(meta)
    }

    // MARK: - The cross-product

    /// Both halves must match. A group named in `contact_groups` whose account
    /// is not in `contact_accounts` is **not** selected -- that is what makes
    /// the two fields a cross-product rather than a union, and it is the
    /// direction that narrows.
    func testAGroupIsSelectedOnlyWhenBothItsHalvesAreInScope() {
        let both = ContactScope.select(catalog: catalog, accounts: ["iCloud"], groups: ["iCloud/Family"])
        XCTAssertEqual(both.groups.map(\.identifier), ["g-icloud-family"])
        XCTAssertTrue(both.unknown.isEmpty)

        let accountMissing = ContactScope.select(
            catalog: catalog, accounts: ["Exchange"], groups: ["iCloud/Family"]
        )
        XCTAssertTrue(accountMissing.groups.isEmpty, "a group reached through an account not in scope")
        XCTAssertEqual(accountMissing.unknown, ["iCloud/Family"])
    }

    /// The whole reason the value is a path: two accounts each hold a
    /// `Family`, and naming one must not select the other.
    func testTwoAccountsHoldingOneGroupNameStayTwoGroups() {
        let icloud = ContactScope.select(
            catalog: catalog, accounts: ["iCloud", "On My Mac"], groups: ["iCloud/Family"]
        )
        XCTAssertEqual(icloud.groups.map(\.identifier), ["g-icloud-family"])

        let local = ContactScope.select(
            catalog: catalog, accounts: ["iCloud", "On My Mac"], groups: ["On My Mac/Family"]
        )
        XCTAssertEqual(local.groups.map(\.identifier), ["g-local-family"])
    }

    /// A **scope value** is a path and never a bare name. A hand-typed
    /// `Family` names two groups on this Mac and no path at all, so it selects
    /// nothing and is reported as unknown rather than resolving to whichever
    /// account came first -- which is the mailbox lesson in the one place where
    /// guessing would widen a grant.
    func testABareGroupNameIsNotAScopeValue() {
        let selection = ContactScope.select(
            catalog: catalog, accounts: ["iCloud", "On My Mac"], groups: ["Family"]
        )
        XCTAssertTrue(selection.groups.isEmpty)
        XCTAssertEqual(selection.unknown, ["Family"])
    }

    /// Two groups of one name in one account -- which Contacts.app permits --
    /// make the value a coin toss. It selects **neither**: not the first, which
    /// would be the guess, and not both, which would be a value granting more
    /// than an operator could see it granting.
    func testAValueNamingTwoGroupsSelectsNeitherAndIsReported() {
        let duplicated = catalog + [
            ContactGroupRef(account: "iCloud", name: "Family", identifier: "g-icloud-family-2", containerIdentifier: "c-icloud")
        ]
        let selection = ContactScope.select(
            catalog: duplicated, accounts: ["iCloud"], groups: ["iCloud/Family", "iCloud/Work"]
        )
        XCTAssertEqual(selection.ambiguous, ["iCloud/Family"])
        XCTAssertEqual(selection.groups.map(\.identifier), ["g-icloud-work"], "the ambiguous value contributed a group")
    }

    /// Matched under `ResourceScope.fold` -- the one spelling every scope
    /// comparison in this codebase is made in -- on **both** halves of the
    /// path, so an operator's picked value reaches the group it came from
    /// whatever case or normalisation form it was stored in.
    func testBothHalvesAreMatchedUnderTheSharedFold() {
        let folded = ContactScope.select(
            catalog: catalog, accounts: ["ICLOUD"], groups: ["icloud/family"]
        )
        XCTAssertEqual(folded.groups.map(\.identifier), ["g-icloud-family"])

        let accented = [ContactGroupRef(
            account: "Re\u{0301}union", name: "E\u{0301}quipe", identifier: "g-accented", containerIdentifier: "c-a"
        )]
        let decomposedInCatalog = ContactScope.select(
            catalog: accented, accounts: ["R\u{00E9}union"], groups: ["R\u{00E9}union/\u{00C9}quipe"]
        )
        XCTAssertEqual(decomposedInCatalog.groups.map(\.identifier), ["g-accented"])
    }

    func testOneGroupNamedTwiceIsSelectedOnce() {
        let selection = ContactScope.select(
            catalog: catalog, accounts: ["iCloud"], groups: ["iCloud/Family", "iCloud/Family"]
        )
        XCTAssertEqual(selection.groups.map(\.identifier), ["g-icloud-family"])
    }

    // MARK: - The three states, and a fourth that is not a violation

    /// The control. Nobody mediated, so every contacts tool must behave
    /// exactly as it does on a bare stdio pipe -- and `.unscoped` is the only
    /// thing that says so.
    func testAnUnmediatedCallIsUnscoped() {
        XCTAssertEqual(ResourceScope.none.contactGroupTargets(catalog: catalog), .unscoped)
    }

    /// ADR-011 decision 4: mediated and a field is absent or empty means
    /// **refuse**, never "unrestricted" and never "everything". Each field is
    /// required independently of its sibling.
    func testAMediatedCallMissingEitherFieldRefusesNamingIt() throws {
        let noAccounts = scope(accounts: nil, groups: ["iCloud/Family"])
            .contactGroupTargets(catalog: catalog)
        guard case .refuse(let a) = noAccounts else { return XCTFail("\(noAccounts)") }
        XCTAssertTrue(a.contains("`contact_accounts`"), a)

        let noGroups = scope(accounts: ["iCloud"], groups: nil).contactGroupTargets(catalog: catalog)
        guard case .refuse(let g) = noGroups else { return XCTFail("\(noGroups)") }
        XCTAssertTrue(g.contains("`contact_groups`"), g)

        let emptyGroups = scope(accounts: ["iCloud"], groups: []).contactGroupTargets(catalog: catalog)
        guard case .refuse = emptyGroups else { return XCTFail("an empty list is not a grant: \(emptyGroups)") }
    }

    /// ADR-011 decision 11, the distinction this branch had to get right: a
    /// scope naming a group that is not on this Mac is an **operator
    /// misconfiguration** -- an error, and deliberately **not** a
    /// `scope_violation`, because a violation is a client probing a boundary
    /// and belongs in alerting while a typo belongs in the editor.
    func testAScopeNamingNoGroupOnThisMacIsMisconfiguredRatherThanAViolation() throws {
        let decision = scope(accounts: ["iCloud"], groups: ["iCloud/Nowhere"])
            .contactGroupTargets(catalog: catalog)
        guard case .misconfigured(let message) = decision else {
            return XCTFail("a nonexistent group must not read as a client reaching outside: \(decision)")
        }
        XCTAssertTrue(message.contains("configuration mistake"), message)
        XCTAssertTrue(message.contains("iCloud/Nowhere"), message)
        XCTAssertTrue(message.contains("Nothing was read or written"), message)
    }

    func testAnAmbiguousScopeValueIsMisconfiguredAndNamesIt() throws {
        let duplicated = catalog + [
            ContactGroupRef(account: "iCloud", name: "Family", identifier: "g-2", containerIdentifier: "c-icloud")
        ]
        let decision = scope(accounts: ["iCloud"], groups: ["iCloud/Family"])
            .contactGroupTargets(catalog: duplicated)
        guard case .misconfigured(let message) = decision else { return XCTFail("\(decision)") }
        XCTAssertTrue(message.contains("more than one group"), message)
        XCTAssertTrue(message.contains("iCloud/Family"), message)
    }

    func testAWellFormedScopeYieldsExactlyItsGroups() {
        let decision = scope(accounts: ["iCloud", "Exchange"], groups: ["iCloud/Work", "Exchange/Team"])
            .contactGroupTargets(catalog: catalog)
        XCTAssertEqual(decision, .use([catalog[1], catalog[3]]))
    }

    /// A partly-mistyped scope narrows rather than widening: the values that do
    /// resolve are used and the one that does not contributes nothing. Safe in
    /// the only direction that matters, and the reason it is not an outright
    /// refusal is that one stale entry must not cost a client every group it
    /// was correctly granted.
    func testOneUnknownValueDoesNotWidenOrDestroyTheRest() {
        let decision = scope(accounts: ["iCloud"], groups: ["iCloud/Work", "iCloud/Gone"])
            .contactGroupTargets(catalog: catalog)
        XCTAssertEqual(decision, .use([catalog[1]]))
    }

    // MARK: - Every one of the ten tools is governed

    /// The presence check is driven by macMCP's own declaration, which is what
    /// stops a tool added later from quietly escaping it. **`contact_accounts`
    /// governs all ten**, because it is the field that bounds cards and there
    /// is no contacts tool that does not touch one.
    func testEveryContactsToolRequiresTheAccountField() throws {
        for tool in allTools {
            XCTAssertNil(ResourceScope.none.presenceRefusal(tool: tool), "unmediated \(tool)")
            let groupsOnly = try XCTUnwrap(
                scope(accounts: nil, groups: ["iCloud/Family"]).presenceRefusal(tool: tool),
                "\(tool) is not governed by contact_accounts"
            )
            XCTAssertTrue(groupsOnly.contains("`contact_accounts`"), groupsOnly)
        }
    }

    /// **The rule the declaration got wrong, asserted in both directions.**
    ///
    /// A card need not be in a group, so requiring `contact_groups` on a card
    /// tool does not narrow anything -- it removes account-level scoping from
    /// what an operator can say. The four group tools require it because they
    /// cannot name a group without one; the six card tools must not, or a
    /// profile granting `contact_accounts` alone reaches nothing at all.
    func testOnlyTheGroupToolsRequireTheGroupField() throws {
        let accountsOnly = scope(accounts: ["iCloud"], groups: nil)
        for tool in groupTools {
            let refusal = try XCTUnwrap(
                accountsOnly.presenceRefusal(tool: tool),
                "\(tool) acts on a group and was not governed by contact_groups"
            )
            XCTAssertTrue(refusal.contains("`contact_groups`"), refusal)
        }
        for tool in cardTools {
            XCTAssertNil(
                accountsOnly.presenceRefusal(tool: tool),
                "\(tool) demanded a contact group grant for a card it can reach by account"
            )
        }
    }

    /// A profile holding both fields satisfies every tool, which is the shape
    /// the old declaration could express and this one still can.
    func testAProfileHoldingBothFieldsSatisfiesEveryTool() {
        let complete = scope(accounts: ["iCloud"], groups: ["iCloud/Family"])
        for tool in allTools {
            XCTAssertNil(complete.presenceRefusal(tool: tool), tool)
        }
    }

    /// A mediated call carrying somebody else's scope has been granted nothing
    /// here, and must not read as unscoped. This is the test that is macMCP's
    /// own rather than relay's.
    func testAMailScopeGrantsNothingInContacts() throws {
        let mailOnly = ResourceScope.parse([
            "project_id": .string("p"),
            "mail_accounts": .array([.string("Bob")]),
            "mail_mailboxes": .array([.string("INBOX")])
        ])
        for tool in allTools {
            XCTAssertNotNil(mailOnly.presenceRefusal(tool: tool), tool)
        }
        guard case .refuse = mailOnly.contactAccountTargets(catalog: accounts) else {
            return XCTFail("a mail scope read as a contacts account grant")
        }
        guard case .refuse = mailOnly.contactGroupTargets(catalog: catalog) else {
            return XCTFail("a mail scope read as a contacts group grant")
        }
    }

    // MARK: - The account half: what bounds a card

    /// The cards a call may read are the cards in the accounts it names, and
    /// nothing about groups enters into it. `Groupless` holds no group in the
    /// fixture and is selected all the same.
    func testAnAccountIsSelectedWhetherOrNotItHoldsAnyGroup() {
        let selection = ContactScope.select(containers: accounts, accounts: ["Groupless", "iCloud"])
        XCTAssertEqual(selection.accounts.map(\.identifier), ["c-groupless", "c-icloud"])
        XCTAssertTrue(selection.unknown.isEmpty)
        XCTAssertTrue(selection.ambiguous.isEmpty)
    }

    /// A value naming no container narrows rather than widening, and one
    /// account named twice is one account.
    func testAnUnknownAccountContributesNothingAndADuplicateIsSelectedOnce() {
        let selection = ContactScope.select(
            containers: accounts, accounts: ["iCloud", "Nowhere", "ICLOUD"]
        )
        XCTAssertEqual(selection.accounts.map(\.identifier), ["c-icloud"])
        XCTAssertEqual(selection.unknown, ["Nowhere"])
    }

    /// **Two accounts of one name is reachable, not academic.**
    /// `ContactsService.containerName` falls back to the container's *type*
    /// when `CNContainer.name` is empty, which macOS routinely leaves it -- so
    /// two unnamed CardDAV accounts are both called `CardDAV`. Such a value
    /// selects **neither**: reading one would be a guess, reading both would
    /// grant more than the value says.
    func testAnAccountNameCarriedByTwoContainersSelectsNeither() {
        let duplicated = accounts + [ContactAccountRef(name: "iCloud", identifier: "c-icloud-2")]
        let selection = ContactScope.select(
            containers: duplicated, accounts: ["iCloud", "Exchange"]
        )
        XCTAssertEqual(selection.ambiguous, ["iCloud"])
        XCTAssertEqual(selection.accounts.map(\.identifier), ["c-exchange"])
    }

    func testAnAccountValueIsMatchedUnderTheSharedFold() {
        let selection = ContactScope.select(containers: accounts, accounts: ["ON MY MAC"])
        XCTAssertEqual(selection.accounts.map(\.identifier), ["c-local"])
    }

    /// The decision the account selection feeds, in all four states.
    func testTheAccountDecisionKeepsARefusalApartFromAMisconfiguration() throws {
        XCTAssertEqual(ResourceScope.none.contactAccountTargets(catalog: accounts), .unscoped)

        let missing = scope(accounts: nil, groups: ["iCloud/Family"])
            .contactAccountTargets(catalog: accounts)
        guard case .refuse(let refusal) = missing else { return XCTFail("\(missing)") }
        XCTAssertTrue(refusal.contains("`contact_accounts`"), refusal)

        let empty = scope(accounts: [], groups: nil).contactAccountTargets(catalog: accounts)
        guard case .refuse = empty else { return XCTFail("an empty list is not a grant: \(empty)") }

        let typo = scope(accounts: ["Nowhere"], groups: nil).contactAccountTargets(catalog: accounts)
        guard case .misconfigured(let message) = typo else {
            return XCTFail("an account that is not here read as a client reaching outside: \(typo)")
        }
        XCTAssertTrue(message.contains("Nowhere"), message)
        XCTAssertTrue(message.contains("configuration mistake"), message)

        let ambiguous = scope(accounts: ["iCloud"], groups: nil).contactAccountTargets(
            catalog: accounts + [ContactAccountRef(name: "iCloud", identifier: "c-2")]
        )
        guard case .misconfigured(let both) = ambiguous else { return XCTFail("\(ambiguous)") }
        XCTAssertTrue(both.contains("more than one account"), both)

        XCTAssertEqual(
            scope(accounts: ["Groupless"], groups: nil).contactAccountTargets(catalog: accounts),
            .use([ContactAccountRef(name: "Groupless", identifier: "c-groupless")])
        )
    }

    // MARK: - The two decisions, combined

    /// `bind` is where the account bound and the group bound meet, and the
    /// account one is the outer: its failure is the whole answer, and the group
    /// half is only consulted once the accounts hold.
    func testTheAccountFailureWinsAndTheGroupHalfIsOptional() {
        let account = ContactAccountRef(name: "iCloud", identifier: "c-icloud")
        XCTAssertEqual(
            ContactsService.bind(accounts: .refuse("no accounts"), groups: .use([catalog[0]])),
            .refuse("no accounts")
        )
        XCTAssertEqual(
            ContactsService.bind(accounts: .misconfigured("typo"), groups: .use([catalog[0]])),
            .misconfigured("typo")
        )
        XCTAssertEqual(
            ContactsService.bind(accounts: .use([account]), groups: nil),
            .use(ContactsService.ContactsBound(accounts: [account], groups: nil))
        )
        XCTAssertEqual(
            ContactsService.bind(accounts: .use([account]), groups: .refuse("no groups")),
            .refuse("no groups")
        )
        XCTAssertEqual(
            ContactsService.bind(accounts: .use([account]), groups: .use([catalog[0]])),
            .use(ContactsService.ContactsBound(accounts: [account], groups: [catalog[0]]))
        )
    }

    /// An impossible pair -- one call carries one scope, so a `.use` on the
    /// accounts cannot sit beside an `.unscoped` on the groups -- maps to a
    /// **refusal** rather than to unscoped. The fail-open reading of an
    /// unreachable state is the one that turns a confined call into an
    /// unconfined one.
    func testAnImpossiblePairFailsClosed() {
        let account = ContactAccountRef(name: "iCloud", identifier: "c-icloud")
        guard case .refuse = ContactsService.bind(accounts: .use([account]), groups: .unscoped) else {
            return XCTFail("a confined call was let through unconfined")
        }
    }

    /// Which tools ask the group question is read off the declaration, not off
    /// a list re-typed in the service.
    func testWhichToolsAskTheGroupQuestionComesFromTheDeclaration() {
        for tool in groupTools {
            XCTAssertTrue(ContactsService.governedByGroups(tool: tool), tool)
        }
        for tool in cardTools {
            XCTAssertFalse(ContactsService.governedByGroups(tool: tool), tool)
        }
    }

    // MARK: - The chokepoint itself

    /// How many times the fake catalog was asked. A class because the count has
    /// to survive being read inside a closure the gate calls.
    private final class Counter { var count = 0 }

    /// `gate` takes its two impure steps as arguments so the whole of it is a
    /// decision, and these are what a fake `catalog` is for: **counting whether
    /// it was called at all** is the only way to assert that a call with no
    /// authority is refused before the address book is read.
    private func run(
        meta: JSONObject?,
        tool: String = "contacts_list",
        authorized: Bool = true,
        reads: Counter = Counter(),
        groupReads: Counter = Counter(),
        accounts fakeAccounts: [ContactAccountRef]? = nil,
        catalog fake: [ContactGroupRef]? = nil,
        error: String? = nil,
        groupError: String? = nil
    ) -> ContactsService.ContactsGate {
        ContactsService.gate(
            MCPCallContext(arguments: nil, meta: meta, toolName: tool),
            authorized: { authorized },
            accounts: {
                reads.count += 1
                return (fakeAccounts ?? self.accounts, error)
            },
            groups: {
                groupReads.count += 1
                return (fake ?? self.catalog, groupError)
            }
        )
    }

    /// A mediated call carrying no contacts scope is answered without the
    /// address book being touched. Ordering, not just outcome: the presence
    /// check is a question about the caller's authority, and asking Contacts
    /// anything first would mean a client with no grant could still make this
    /// process read.
    func testAMediatedCallWithNoScopeIsRefusedBeforeAnythingIsRead() throws {
        let reads = Counter()
        let result = run(meta: ["project_id": .string("p")], reads: reads)
        guard case .stop(let stopped) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reads.count, 0, "the address book was read for a call that had been refused")
        XCTAssertEqual(stopped.isError, true)
        XCTAssertEqual(stopped.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(stopped.content.first?.text.contains("contact_accounts") == true)
    }

    /// ...and it is refused whether or not Contacts would have talked to us,
    /// because the answer is about the grant rather than about this Mac.
    func testTheRefusalDoesNotDependOnTheTCCGrant() throws {
        let result = run(meta: ["project_id": .string("p")], authorized: false)
        guard case .stop(let stopped) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(stopped.meta?["scope_violation"], .bool(true))
    }

    /// The control, and the one that must never move: nobody mediated, so
    /// nothing is confined -- and the catalog is not read either, so an
    /// unscoped `contacts_get` costs exactly what it always did and cannot
    /// acquire a new way to fail.
    func testAnUnmediatedCallIsNeitherConfinedNorMadeToReadTheCatalog() {
        let reads = Counter()
        let result = run(meta: nil, reads: reads)
        guard case .unscoped = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reads.count, 0)
    }

    func testAWellFormedScopeReachesTheAccountsItNames() throws {
        let result = run(meta: [
            "contact_accounts": .array([.string("iCloud")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ])
        guard case .scoped(let bound) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(bound.accounts.map(\.name), ["iCloud"])
        XCTAssertNil(bound.groups, "a card tool read the group catalog it has no use for")
    }

    /// **What was not expressible before.** An access profile naming an account
    /// and no group reaches that account's cards, including the ones filed in
    /// no group at all -- `Groupless` holds no group in the fixture, and under
    /// the old shape (`contact_groups` governing `contacts_*`, a card reachable
    /// only as a member) this profile was refused outright by the presence
    /// check and, had it got past that, would have selected no group and so no
    /// card.
    func testAnAccountOnlyProfileReachesTheCardsInThatAccount() throws {
        let result = run(meta: [
            "project_id": .string("p"),
            "contact_accounts": .array([.string("Groupless")])
        ])
        guard case .scoped(let bound) = result else {
            return XCTFail("an account-scoped profile was not admitted: \(result)")
        }
        XCTAssertEqual(bound.accounts, [ContactAccountRef(name: "Groupless", identifier: "c-groupless")])
        XCTAssertNil(bound.groups)
    }

    /// ...and every card tool admits it, which is the half that says the
    /// confinement is usable rather than merely permitted.
    func testEveryCardToolAdmitsAnAccountOnlyProfileAndEveryGroupToolRefusesIt() throws {
        let accountOnly: JSONObject = [
            "project_id": .string("p"),
            "contact_accounts": .array([.string("iCloud")])
        ]
        for tool in cardTools {
            guard case .scoped(let bound) = run(meta: accountOnly, tool: tool) else {
                return XCTFail("\(tool) refused an account-scoped profile")
            }
            XCTAssertEqual(bound.accounts.map(\.name), ["iCloud"], tool)
            XCTAssertNil(bound.groups, tool)
        }
        for tool in groupTools {
            guard case .stop(let stopped) = run(meta: accountOnly, tool: tool) else {
                return XCTFail("\(tool) acted on groups without a contact group grant")
            }
            XCTAssertEqual(stopped.meta?["scope_violation"], .bool(true), tool)
            XCTAssertTrue(stopped.content.first?.text.contains("contact_groups") == true, tool)
        }
    }

    /// The group catalog is read for the four tools that need it and for no
    /// others -- a framework read a card tool has no use for, on a store that
    /// may not answer, is a new way for `contacts_get` to fail.
    func testTheGroupCatalogIsReadOnlyForTheToolsGroupsGovern() {
        let complete: JSONObject = [
            "contact_accounts": .array([.string("iCloud")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ]
        for tool in cardTools {
            let groupReads = Counter()
            _ = run(meta: complete, tool: tool, groupReads: groupReads)
            XCTAssertEqual(groupReads.count, 0, "\(tool) read the group catalog")
        }
        for tool in groupTools {
            let groupReads = Counter()
            _ = run(meta: complete, tool: tool, groupReads: groupReads)
            XCTAssertEqual(groupReads.count, 1, "\(tool) did not read the group catalog")
        }
    }

    /// A scope that names no account on this Mac is answered without the group
    /// catalog being read: the account bound is the outer one and its failure
    /// is the whole answer.
    func testAnAccountScopeThatResolvesToNothingIsAnsweredBeforeTheGroupsAreRead() throws {
        let groupReads = Counter()
        let result = run(meta: [
            "contact_accounts": .array([.string("Nowhere")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ], tool: "contacts_list_groups", groupReads: groupReads)
        guard case .stop(let stopped) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(groupReads.count, 0)
        XCTAssertNil(stopped.meta?["scope_violation"], "an operator's typo was reported as a probe")
        XCTAssertTrue(stopped.content.first?.text.contains("Nowhere") == true)
    }

    /// Every one of the ten, through the real chokepoint rather than through
    /// the presence check alone.
    func testEveryContactsToolIsConfinedByTheSameGate() throws {
        for tool in allTools {
            let confined = run(meta: [
                "contact_accounts": .array([.string("iCloud")]),
                "contact_groups": .array([.string("iCloud/Work")])
            ], tool: tool)
            guard case .scoped(let bound) = confined else { return XCTFail(tool) }
            XCTAssertEqual(bound.accounts.map(\.name), ["iCloud"], tool)
            if groupTools.contains(tool) {
                XCTAssertEqual(bound.groups?.map(\.path), ["iCloud/Work"], tool)
            } else {
                XCTAssertNil(bound.groups, tool)
            }

            let ungranted = run(meta: ["project_id": .string("p")], tool: tool)
            guard case .stop(let stopped) = ungranted else { return XCTFail(tool) }
            XCTAssertEqual(stopped.meta?["scope_violation"], .bool(true), tool)
        }
    }

    /// A catalog that could not be read is a failure to answer, not a
    /// confinement to nothing: `.stop` with the error and no violation marker,
    /// rather than a `.scoped([])` that would read to every tool as "this
    /// client may reach no group" and answer an empty list.
    func testACatalogThatCouldNotBeReadStopsTheCallRatherThanConfiningItToNothing() throws {
        let result = run(meta: [
            "contact_accounts": .array([.string("iCloud")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ], accounts: [], error: "the store would not answer")
        guard case .stop(let stopped) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(stopped.isError, true)
        XCTAssertNil(stopped.meta?["scope_violation"])
        XCTAssertEqual(stopped.content.first?.text, "the store would not answer")

        let groups = run(meta: [
            "contact_accounts": .array([.string("iCloud")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ], tool: "contacts_list_groups", catalog: [], groupError: "the groups would not answer")
        guard case .stop(let groupStop) = groups else { return XCTFail("\(groups)") }
        XCTAssertNil(groupStop.meta?["scope_violation"])
        XCTAssertEqual(groupStop.content.first?.text, "the groups would not answer")
    }

    // MARK: - A caller's own argument, reconciled

    /// ADR-011's reconciliation rule on `contacts_create`'s `group`: an absent
    /// argument resolves **to the scope**, which is unambiguous when the scope
    /// names one group.
    func testAnAbsentGroupArgumentResolvesToTheScope() {
        XCTAssertEqual(
            ContactScope.choose(group: nil, from: [catalog[0]]),
            .chosen(catalog[0])
        )
    }

    /// ...and is under-specified, not a violation, when the scope names
    /// several. The caller reached outside nothing; it simply did not say
    /// which of the groups it holds it meant, and naming them costs no
    /// disclosure because they are its own grant.
    func testAnAbsentGroupArgumentWithSeveralInScopeIsUnderSpecifiedRatherThanAGuess() {
        XCTAssertEqual(
            ContactScope.choose(group: nil, from: [catalog[0], catalog[1]]),
            .underSpecified(["iCloud/Family", "iCloud/Work"])
        )
    }

    /// An **explicit** argument outside the scope is an error, never a silent
    /// narrowing to something in scope.
    func testAnExplicitGroupOutsideTheScopeIsRefused() {
        XCTAssertEqual(
            ContactScope.choose(group: "On My Mac/Family", from: [catalog[0], catalog[1]]),
            .outside("On My Mac/Family")
        )
    }

    /// A leaf name is a fallback and only when exactly one group in scope
    /// carries it -- the mailbox rule, one level down. Two carriers is refused
    /// rather than resolved, because filing into one of two is a guess the
    /// response cannot show.
    func testALeafNameReachesOneGroupAndRefusesTwo() {
        XCTAssertEqual(ContactScope.choose(group: "Work", from: [catalog[0], catalog[1]]), .chosen(catalog[1]))
        XCTAssertEqual(
            ContactScope.choose(group: "Family", from: [catalog[0], catalog[2]]),
            .outside("Family"),
            "a leaf name carried by two groups in scope must not pick one"
        )
    }

    func testAGroupArgumentIsMatchedUnderTheSharedFold() {
        XCTAssertEqual(ContactScope.choose(group: "ICLOUD/family", from: [catalog[0]]), .chosen(catalog[0]))
    }

    /// The same rule for `contacts_create`'s `account`, which is what places a
    /// card now that a group no longer has to. A card has to be filed
    /// somewhere, the framework's default container may be outside the scope,
    /// and under account scoping there is no group to take a container from.
    func testAnAccountArgumentResolvesToTheScopeOrAsksWhich() {
        let icloud = ContactAccountRef(name: "iCloud", identifier: "c-icloud")
        let local = ContactAccountRef(name: "On My Mac", identifier: "c-local")
        XCTAssertEqual(ContactScope.choose(account: nil, from: [icloud]), .chosen(icloud))
        XCTAssertEqual(
            ContactScope.choose(account: nil, from: [icloud, local]),
            .underSpecified(["iCloud", "On My Mac"])
        )
        XCTAssertEqual(ContactScope.choose(account: "ICLOUD", from: [icloud, local]), .chosen(icloud))
        XCTAssertEqual(
            ContactScope.choose(account: "Exchange", from: [icloud, local]),
            .outside("Exchange"),
            "a card filed outside the scope is one the client could not read back"
        )
    }

    // MARK: - What a refusal says

    /// The decision-11 shape, in all three directions. A handle in scope
    /// proceeds; one that exists elsewhere is a **violation** that names what
    /// the client may reach and never where the handle actually is; one that
    /// exists nowhere is an ordinary not-found carrying no violation marker,
    /// because it is a fact about the request rather than about a boundary.
    func testAHandleInScopeProceeds() {
        XCTAssertNil(ContactsService.handleRefusal(
            noun: "contact", id: "abc", inScope: true, existsElsewhere: true, reachable: ["iCloud/Family"]
        ))
    }

    func testAnOutOfScopeHandleIsAViolationThatDoesNotSayWhereItIs() throws {
        let refusal = try XCTUnwrap(ContactsService.handleRefusal(
            noun: "contact", id: "abc", inScope: false, existsElsewhere: true, reachable: ["iCloud/Family"]
        ))
        XCTAssertEqual(refusal.isError, true)
        XCTAssertEqual(refusal.meta?["scope_violation"], .bool(true))
        let text = try XCTUnwrap(refusal.content.first?.text)
        XCTAssertTrue(text.contains("outside the contacts this client may reach"), text)
        XCTAssertTrue(text.contains("iCloud/Family"), text)
        // The refusal is assembled out of the client's own grant and the id it
        // sent. Nothing else can be in it, which is what "never names the
        // account or mailbox the message is actually in" means here.
        XCTAssertFalse(text.contains("On My Mac"), text)
        XCTAssertFalse(text.contains("Exchange"), text)
    }

    func testAHandleThatExistsNowhereIsANotFoundAndNotAViolation() throws {
        let refusal = try XCTUnwrap(ContactsService.handleRefusal(
            noun: "group", id: "abc", inScope: false, existsElsewhere: false, reachable: ["iCloud/Family"]
        ))
        XCTAssertEqual(refusal.isError, true)
        XCTAssertNil(refusal.meta?["scope_violation"], "a miss is not a boundary being probed")
        XCTAssertEqual(refusal.content.first?.text, "group not found: abc")
    }

    /// `contacts_create_group` is still the one tool refused outright under a
    /// scope, and the reasoning is re-derived rather than inherited: the
    /// premise that made it a dead end (a card reachable only through a group)
    /// is gone, so the refusal now rests on the two reasons the account/group
    /// split does not touch. A `contact_groups` value is an `Account/Group`
    /// path **matched whole** -- a group name may contain a `/` -- so it cannot
    /// be split into an account and a name to create one from; and a value
    /// matching no group is a stale or mistyped grant an operator needs to see
    /// (decision 11), not an instruction to make it real.
    func testCreateGroupIsRefusedOutrightUnderAScopeAndSaysWhy() throws {
        let refusal = ContactsService.createGroupRefusal(inScope: [catalog[0]])
        XCTAssertEqual(refusal.isError, true)
        XCTAssertEqual(refusal.meta?["scope_violation"], .bool(true))
        let text = try XCTUnwrap(refusal.content.first?.text)
        XCTAssertTrue(text.contains("may not create contact groups"), text)
        XCTAssertTrue(text.contains("iCloud/Family"), text)
        XCTAssertTrue(text.contains("Nothing was created"), text)
        XCTAssertTrue(text.contains("matched whole"), text)
        XCTAssertTrue(text.contains("stale or mistyped"), text)
    }

    /// A group tool whose gate carried no group bound refuses rather than
    /// running unconfined. Unreachable while the declaration and the handlers
    /// agree; it exists so that a group tool added to the service without being
    /// added to `contact_groups`'s `applies_to` fails closed.
    func testAGroupToolWithNoGroupBoundRefuses() throws {
        let refusal = ContactsService.groupBoundMissing()
        XCTAssertEqual(refusal.isError, true)
        XCTAssertEqual(refusal.meta?["scope_violation"], .bool(true))
        XCTAssertTrue(refusal.content.first?.text.contains("contact_groups") == true)
    }

    // MARK: - The filters that replace a predicate the framework will not compound

    /// A `CNContactFetchRequest` takes one predicate, so a scoped list fetches
    /// by **group** and matches the name here -- the choice that reads only
    /// cards already in scope.
    func testNameMatchingIsCaseAndDiacriticInsensitiveAcrossTheNameFields() {
        XCTAssertTrue(ContactsService.nameMatches("ann", fields: ["Anna", "Karenina", ""]))
        XCTAssertTrue(ContactsService.nameMatches("KAREN", fields: ["Anna", "Karenina", ""]))
        XCTAssertTrue(ContactsService.nameMatches("reunion", fields: ["", "", "Réunion Ltd"]))
        XCTAssertTrue(ContactsService.nameMatches("anna karenina", fields: ["Anna", "Karenina", ""]))
        XCTAssertFalse(ContactsService.nameMatches("boris", fields: ["Anna", "Karenina", ""]))
        XCTAssertFalse(
            ContactsService.nameMatches("anna boris", fields: ["Anna", "Karenina", ""]),
            "every term must be found, or a two-word query matches on one of them"
        )
    }

    func testAnEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertTrue(ContactsService.nameMatches("", fields: ["Anna"]))
        XCTAssertTrue(ContactsService.nameMatches("   ", fields: ["Anna"]))
    }

    /// The number rule is `MessagesService.normalizedHandle` -- digits, and the
    /// last ten of them when there are more -- so a number that finds a
    /// conversation finds the card too, rather than there being two rules for
    /// one question.
    func testPhoneMatchingIgnoresFormattingAndCountryCode() {
        XCTAssertTrue(ContactsService.phoneMatches("+1 (555) 123-4567", numbers: ["5551234567"]))
        XCTAssertTrue(ContactsService.phoneMatches("5551234567", numbers: ["+1-555-123-4567"]))
        XCTAssertFalse(ContactsService.phoneMatches("5551234567", numbers: ["5559999999"]))
        XCTAssertFalse(ContactsService.phoneMatches("5551234567", numbers: []))
        XCTAssertFalse(ContactsService.phoneMatches("", numbers: ["5551234567"]))
    }

    // MARK: - What a group row says

    /// The path is the scope value, so a client handed a row can tell which of
    /// its granted groups it is looking at, and an operator reading an audit
    /// line sees the same string they picked.
    func testAGroupRowCarriesItsPathAndAccountBesideTheHandle() {
        let dict = ContactsService.groupDict(catalog[0])
        XCTAssertEqual(dict["id"] as? String, "g-icloud-family")
        XCTAssertEqual(dict["name"] as? String, "Family")
        XCTAssertEqual(dict["account"] as? String, "iCloud")
        XCTAssertEqual(dict["path"] as? String, "iCloud/Family")
    }

    func testAGroupsPathIsBuiltByTheOneFunctionThatBuildsEveryScopePath() {
        XCTAssertEqual(catalog[2].path, ScopePath.Row(container: "On My Mac", leaf: "Family").path)
    }
}

/// The one step of `ContactsService.gate` that can be reached without an
/// address book: turning a reconciliation decision into what the call answers.
///
/// It is split out precisely so this can be pinned. Everything above it in
/// `gate` -- the presence check, the TCC check, the catalog read -- is either
/// tested in `ContactsScopeTests` or needs a live store.
final class ContactsGateMappingTests: XCTestCase {
    private let group = ContactGroupRef(
        account: "iCloud", name: "Family", identifier: "g", containerIdentifier: "c"
    )
    private let account = ContactAccountRef(name: "iCloud", identifier: "c")

    func testAnUnscopedDecisionLeavesTheToolExactlyAsItWas() {
        guard case .unscoped = ContactsService.gate(for: .unscoped) else {
            return XCTFail("a mediated-by-nobody call was confined")
        }
    }

    func testAUsableScopeConfinesRatherThanStopping() {
        let bound = ContactsService.ContactsBound(accounts: [account], groups: [group])
        guard case .scoped(let confined) = ContactsService.gate(for: .use(bound)) else {
            return XCTFail("a well-formed scope did not confine")
        }
        XCTAssertEqual(confined, bound)
    }

    /// A card tool's bound carries accounts and **no** groups, and `nil` is not
    /// `[]`: an empty group list is not a reachable state (an empty selection
    /// is a misconfiguration), so `nil` can only mean "this tool never asked".
    func testACardToolsBoundCarriesNoGroupsAtAll() {
        let bound = ContactsService.ContactsBound(accounts: [account])
        guard case .scoped(let confined) = ContactsService.gate(for: .use(bound)) else {
            return XCTFail("an account-only scope did not confine")
        }
        XCTAssertEqual(confined.accounts, [account])
        XCTAssertNil(confined.groups)
    }

    /// A client reaching outside its scope.
    func testARefusalCarriesTheViolationMarker() throws {
        guard case .stop(let result) = ContactsService.gate(for: .refuse("nope")) else {
            return XCTFail("a refusal did not stop the call")
        }
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.meta?["scope_violation"], .bool(true))
        XCTAssertEqual(result.content.first?.text, "nope")
    }

    /// An operator's typo. **The same stop, and deliberately not the same
    /// marker** -- ADR-011 decision 11. A security signal filled with
    /// configuration mistakes is not a security signal.
    func testAMisconfigurationStopsTheCallWithoutTheViolationMarker() throws {
        guard case .stop(let result) = ContactsService.gate(for: .misconfigured("typo")) else {
            return XCTFail("a misconfiguration did not stop the call")
        }
        XCTAssertEqual(result.isError, true)
        XCTAssertNil(result.meta?["scope_violation"], "an operator's typo was reported as a client probing a boundary")
        XCTAssertEqual(result.content.first?.text, "typo")
    }
}

// MARK: - What these tests cannot reach
//
// The chokepoint itself is covered: `gate` takes its two impure steps as
// arguments, so which groups a call reaches, in what order the checks run, and
// what each refusal says are all decided here without an address book. Three
// things are not, and they need a live `CNContactStore` and a fixture address
// book to check:
//
// * **`unifyResults = false` on every scoped read.** That the scoped paths in
//   `contacts_list`, `contacts_search_by_phone`, `cards(in:)` and
//   `rawContact(id:)` return raw per-container cards rather than merged ones is
//   asserted by reading the code, not by a test. It is the single most
//   load-bearing line of this branch -- a merged card carries fields from
//   containers the client may not reach -- and a live check would be: link a
//   card in an in-scope account to one in an out-of-scope account, read it
//   through `contacts_list`, and assert the out-of-scope card's phone number is
//   absent.
// * **That a scoped read touches only in-scope cards.** `cards(in:)` predicates
//   each fetch on a container, so the store is never enumerated; only an
//   instrumented store could prove it. The same goes for `contacts_create`
//   filing into the resolved account's container rather than the default one,
//   and for `contacts_update` / `contacts_delete` acting on a raw card.
// * **That a card is checked before it is read.** `resolve` asks
//   `containersOf(id:)` -- which returns containers, not contact data -- and
//   fetches the card only once one of them is in scope. The ordering is the
//   confinement, and only an instrumented store could show that no field of an
//   out-of-scope card was ever fetched.
// * **The existence probes.** `contactExistsAnywhere` / `groupExistsAnywhere`
//   are what turn a miss into a not-found and a hit into a violation; the
//   *decision* they feed is tested here in both directions, the probes
//   themselves are not.
