import XCTest
@testable import macmcp

/// What the contacts resource scope actually *does*, at every seam ADR-011
/// names for the ten `contacts_*` tools.
///
/// **Contacts cannot be driven from a hermetic test.** There is no stub
/// `CNContactStore`, and touching the real one reads the user's own address
/// book -- which is exactly what the rest of this suite refuses to do. So the
/// enforcement is built the way `MailService`'s was: the framework reads
/// (`groupCatalog`, `members(of:)`, the existence probes) do nothing but read,
/// and every decision they feed -- which groups a scope selects, which handle a
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

    /// The ten tools this branch had to cover, as `main.swift` registers them.
    private let allTools = [
        "contacts_list", "contacts_get", "contacts_create", "contacts_update", "contacts_delete",
        "contacts_list_groups", "contacts_create_group", "contacts_add_to_group",
        "contacts_remove_from_group", "contacts_search_by_phone"
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

    /// The presence check is driven by macMCP's own declaration
    /// (`applies_to: ["contacts_*"]`), which is what stops a tool added later
    /// from quietly escaping it. Asserted per tool, in both directions.
    func testEveryContactsToolRequiresBothFieldsAndNoneRequiresThemUnmediated() throws {
        let complete = scope(accounts: ["iCloud"], groups: ["iCloud/Family"])
        for tool in allTools {
            XCTAssertNil(complete.presenceRefusal(tool: tool), tool)
            XCTAssertNil(ResourceScope.none.presenceRefusal(tool: tool), "unmediated \(tool)")

            let accountsOnly = try XCTUnwrap(
                scope(accounts: ["iCloud"], groups: nil).presenceRefusal(tool: tool),
                "\(tool) is not governed by contact_groups"
            )
            XCTAssertTrue(accountsOnly.contains("`contact_groups`"), accountsOnly)

            let groupsOnly = try XCTUnwrap(
                scope(accounts: nil, groups: ["iCloud/Family"]).presenceRefusal(tool: tool),
                "\(tool) is not governed by contact_accounts"
            )
            XCTAssertTrue(groupsOnly.contains("`contact_accounts`"), groupsOnly)
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
        guard case .refuse = mailOnly.contactGroupTargets(catalog: catalog) else {
            return XCTFail("a mail scope read as a contacts grant")
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
        catalog fake: [ContactGroupRef]? = nil,
        error: String? = nil
    ) -> ContactsService.ContactsGate {
        ContactsService.gate(
            MCPCallContext(arguments: nil, meta: meta, toolName: tool),
            authorized: { authorized },
            catalog: {
                reads.count += 1
                return (fake ?? self.catalog, error)
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

    func testAWellFormedScopeReachesTheGroupsItNames() throws {
        let result = run(meta: [
            "contact_accounts": .array([.string("iCloud")]),
            "contact_groups": .array([.string("iCloud/Work")])
        ])
        guard case .scoped(let groups) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(groups.map(\.path), ["iCloud/Work"])
    }

    /// Every one of the ten, through the real chokepoint rather than through
    /// the presence check alone.
    func testEveryContactsToolIsConfinedByTheSameGate() throws {
        for tool in allTools {
            let confined = run(meta: [
                "contact_accounts": .array([.string("iCloud")]),
                "contact_groups": .array([.string("iCloud/Work")])
            ], tool: tool)
            guard case .scoped(let groups) = confined else { return XCTFail(tool) }
            XCTAssertEqual(groups.map(\.path), ["iCloud/Work"], tool)

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
        ], catalog: [], error: "the store would not answer")
        guard case .stop(let stopped) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(stopped.isError, true)
        XCTAssertNil(stopped.meta?["scope_violation"])
        XCTAssertEqual(stopped.content.first?.text, "the store would not answer")
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

    /// `contacts_create_group` is the one tool refused outright under a scope:
    /// a group created now is by construction not one `contact_groups` names,
    /// so there is no honest reconciliation, only a capability that would
    /// always dead-end or a client widening its own confinement by writing.
    func testCreateGroupIsRefusedOutrightUnderAScopeAndSaysWhy() throws {
        let refusal = ContactsService.createGroupRefusal(inScope: [catalog[0]])
        XCTAssertEqual(refusal.isError, true)
        XCTAssertEqual(refusal.meta?["scope_violation"], .bool(true))
        let text = try XCTUnwrap(refusal.content.first?.text)
        XCTAssertTrue(text.contains("may not create contact groups"), text)
        XCTAssertTrue(text.contains("iCloud/Family"), text)
        XCTAssertTrue(text.contains("Nothing was created"), text)
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

    func testAnUnscopedDecisionLeavesTheToolExactlyAsItWas() {
        guard case .unscoped = ContactsService.gate(for: .unscoped) else {
            return XCTFail("a mediated-by-nobody call was confined")
        }
    }

    func testAUsableScopeConfinesRatherThanStopping() {
        guard case .scoped(let groups) = ContactsService.gate(for: .use([group])) else {
            return XCTFail("a well-formed scope did not confine")
        }
        XCTAssertEqual(groups, [group])
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
//   `contacts_list`, `contacts_search_by_phone` and `resolve` return raw
//   per-container cards rather than merged ones is asserted by reading the
//   code, not by a test. It is the single most load-bearing line of this
//   branch -- a merged card carries fields from containers the client may not
//   reach -- and a live check would be: link a card in an in-scope account to
//   one in an out-of-scope account, read it through `contacts_list`, and assert
//   the out-of-scope card's phone number is absent.
// * **That a scoped read touches only in-scope cards.** `members(of:)`
//   predicates each fetch on a group, so the store is never enumerated; only an
//   instrumented store could prove it. The same goes for `contacts_create`
//   filing into the destination group's container rather than the default one,
//   and for `contacts_update` / `contacts_delete` acting on a raw card.
// * **The existence probes.** `contactExistsAnywhere` / `groupExistsAnywhere`
//   are what turn a miss into a not-found and a hit into a violation; the
//   *decision* they feed is tested here in both directions, the probes
//   themselves are not.
