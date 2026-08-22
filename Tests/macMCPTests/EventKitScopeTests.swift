import XCTest
@testable import macmcp

/// What ADR-011's reconciliation rule actually *does* for calendars and
/// reminder lists.
///
/// EventKit cannot be driven from a hermetic test — there is no stub store, and
/// touching the real one reads the user's own data — so the enforcement is
/// written as a function from rows and a scope to row indices, and this is that
/// function. `CalendarService` and `RemindersService` contribute one line each
/// (`store.calendars(for:)`, mapped positionally to rows); everything that can
/// be *wrong* about which calendar a client reaches is here.
///
/// **The negatives are the point.** A scope that admits what it should admit
/// and also everything else passes every positive test there is.
final class EventKitScopeTests: XCTestCase {
    /// Two sources that each hold a "Work", which is the whole reason a value
    /// is a path: `EKCalendar.title` is not unique, and the code this replaces
    /// matched with `$0.title == name` and therefore selected **both**.
    private let rows: [ScopePath.Row] = [
        .init(container: "iCloud", leaf: "Work"),
        .init(container: "iCloud", leaf: "Home"),
        .init(container: "Exchange", leaf: "Work"),
        .init(container: "On My Mac", leaf: "Personal")
    ]

    private let fields = CalendarService.scopeFields

    private func scope(accounts: [String]?, calendars: [String]?) -> ResourceScope {
        var meta: JSONObject = ["project_id": .string("prof_test")]
        if let accounts { meta["calendar_accounts"] = .array(accounts.map { .string($0) }) }
        if let calendars { meta["calendars"] = .array(calendars.map { .string($0) }) }
        return ResourceScope.parse(meta)
    }

    private func confinement(accounts: [String]?, calendars: [String]?) -> ScopedRows.RowScope {
        let s = scope(accounts: accounts, calendars: calendars)
        return ScopedRows.allowed(
            rows: rows,
            containers: s.access("calendar_accounts"),
            leaves: s.access("calendars"),
            fields: fields
        )
    }

    private func paths(_ indices: [Int]) -> [String] { indices.map { rows[$0].path } }

    // MARK: - Which rows a scope admits

    /// An unmediated call — no `_meta` at all — must behave exactly as macMCP
    /// always has. Every existing caller over a bare stdio pipe is this one.
    func testAnUnmediatedCallIsUnscopedAndSeesEverything() {
        let unscoped = ScopedRows.allowed(
            rows: rows,
            containers: ResourceScope.none.access("calendar_accounts"),
            leaves: ResourceScope.none.access("calendars"),
            fields: fields
        )
        XCTAssertEqual(unscoped, .unscoped)
        XCTAssertNil(unscoped.indices)
    }

    /// The cross-product ADR-011's worked example describes: accounts and
    /// leaves are ANDed, so a calendar is reachable only when its account is
    /// listed too.
    func testTheTwoFieldsCombineAsACrossProduct() {
        guard case .confined(let indices) = confinement(
            accounts: ["iCloud"], calendars: ["iCloud/Work", "Exchange/Work"]
        ) else { return XCTFail("expected a confinement") }
        XCTAssertEqual(paths(indices), ["iCloud/Work"])
    }

    /// The disclosure this exists to stop: a confined client must not be handed
    /// the other account's calendar of the same name.
    func testASameNamedCalendarInAnotherAccountIsNotAdmitted() {
        guard case .confined(let indices) = confinement(
            accounts: ["iCloud"], calendars: ["iCloud/Work"]
        ) else { return XCTFail("expected a confinement") }
        XCTAssertEqual(paths(indices), ["iCloud/Work"])
        XCTAssertFalse(paths(indices).contains("Exchange/Work"))
    }

    /// Decision 4: a mediated call carrying no value for a field is a refusal,
    /// never "everything" and never "nothing quietly".
    func testAMediatedCallWithNoValueRefusesRatherThanWidening() {
        for missing in [confinement(accounts: nil, calendars: ["iCloud/Work"]),
                        confinement(accounts: ["iCloud"], calendars: nil),
                        confinement(accounts: [], calendars: []),
                        confinement(accounts: nil, calendars: nil)] {
            guard case .refused(let message) = missing else {
                return XCTFail("expected a refusal, got \(missing)")
            }
            XCTAssertTrue(message.contains("refusal rather than \"everything\""), message)
        }
    }

    /// Decision 11: a scope naming a calendar this Mac does not hold is an
    /// **operator misconfiguration**, an error but explicitly not a violation,
    /// so a typo cannot fill the signal a client probing a boundary belongs in.
    func testAScopeNamingACalendarThatDoesNotExistIsMisconfiguredNotAViolation() {
        guard case .misconfigured(let message) = confinement(
            accounts: ["iCloud"], calendars: ["iCloud/Wrok"]
        ) else { return XCTFail("expected a misconfiguration") }
        XCTAssertTrue(message.contains("\"iCloud/Wrok\""), message)
        XCTAssertTrue(message.contains("configuration mistake rather than a refusal"), message)
    }

    /// The same for the account half, and it names which half was wrong.
    func testAnAccountThatDoesNotExistIsNamedRatherThanBlamedOnTheCalendar() {
        guard case .misconfigured(let message) = confinement(
            accounts: ["iCloudy"], calendars: ["iCloud/Work"]
        ) else { return XCTFail("expected a misconfiguration") }
        XCTAssertTrue(message.contains("`calendar_accounts` names \"iCloudy\""), message)
        XCTAssertFalse(message.contains("`calendars` names"), message)
    }

    /// Two values that each exist and grant nothing together is a third,
    /// distinct mistake, and saying "not on this Mac" about either would be
    /// false. It has to say the cross-product is empty.
    func testTwoRealValuesThatIntersectInNothingSayThatRatherThanLie() {
        guard case .misconfigured(let message) = confinement(
            accounts: ["iCloud"], calendars: ["Exchange/Work"]
        ) else { return XCTFail("expected a misconfiguration") }
        XCTAssertTrue(message.contains("cross-product"), message)
        XCTAssertFalse(message.contains("not a calendar on this Mac"), message)
    }

    /// An empty intersection must never come back as an empty *result*.
    /// `[]` with `isError: false` is an affirmative claim that this Mac holds
    /// no calendar the client may reach — the shape the mail scan work removed
    /// as `total_messages: 0`.
    func testAnEmptyIntersectionIsNeverAnEmptyConfinement() {
        let verdict = confinement(accounts: ["iCloud"], calendars: ["Exchange/Work"])
        XCTAssertNotEqual(verdict, .confined([]))
    }

    /// The scope and macMCP's own enumeration have to match under one rule, or
    /// an operator picks a value out of the picker that then reaches nothing.
    func testMatchingIsCaseAndNormalisationInsensitiveLikeEverythingElse() {
        guard case .confined(let indices) = confinement(
            accounts: ["ICLOUD"], calendars: ["icloud/work"]
        ) else { return XCTFail("expected a confinement") }
        XCTAssertEqual(paths(indices), ["iCloud/Work"])

        let decomposed = [ScopePath.Row(container: "iCloud", leaf: "Cafe\u{0301}")]
        var meta: JSONObject = ["project_id": .string("p")]
        meta["calendar_accounts"] = .array([.string("iCloud")])
        meta["calendars"] = .array([.string("iCloud/Caf\u{00E9}")])
        let s = ResourceScope.parse(meta)
        guard case .confined(let hit) = ScopedRows.allowed(
            rows: decomposed, containers: s.access("calendar_accounts"),
            leaves: s.access("calendars"), fields: fields
        ) else { return XCTFail("NFD and NFC must be one name") }
        XCTAssertEqual(hit, [0])
    }

    // MARK: - Reconciling an explicit argument

    /// The bug named in the task: `store.calendars(for:).filter { $0.title == name }`
    /// selects **both** "Work" calendars. A bare title carried by two is now
    /// refused with both named, exactly as `mail_move` refuses two same-named
    /// mailboxes.
    func testABareTitleTwoCalendarsCarryIsRefusedWithBothNamed() {
        guard case .ambiguous(let message) = ScopedRows.resolve(
            "Work", rows: rows, allowed: nil, fields: fields
        ) else { return XCTFail("expected an ambiguity refusal") }
        XCTAssertTrue(message.contains("\"iCloud/Work\""), message)
        XCTAssertTrue(message.contains("\"Exchange/Work\""), message)
    }

    /// A bare name is a path with one component, and stays usable when only one
    /// calendar carries it — refusing it would cost every existing caller for
    /// no gain.
    func testABareTitleOnlyOneCalendarCarriesStillResolves() {
        guard case .rows(let indices) = ScopedRows.resolve(
            "Home", rows: rows, allowed: nil, fields: fields
        ) else { return XCTFail("expected a match") }
        XCTAssertEqual(paths(indices), ["iCloud/Home"])
    }

    /// The path is the handle, and it picks exactly one of the two Works.
    func testAPathResolvesToTheOneCalendarItNames() {
        guard case .rows(let indices) = ScopedRows.resolve(
            "Exchange/Work", rows: rows, allowed: nil, fields: fields
        ) else { return XCTFail("expected a match") }
        XCTAssertEqual(paths(indices), ["Exchange/Work"])
    }

    /// A path is matched before a leaf name, so a calendar literally titled
    /// `Exchange/Work` inside iCloud cannot shadow the real `Exchange/Work`.
    func testAPathMatchWinsOverALeafNameMatch() {
        let tricky = rows + [.init(container: "iCloud", leaf: "Exchange/Work")]
        guard case .rows(let indices) = ScopedRows.resolve(
            "Exchange/Work", rows: tricky, allowed: nil, fields: fields
        ) else { return XCTFail("expected a match") }
        XCTAssertEqual(indices.map { tricky[$0].path }, ["Exchange/Work"])
    }

    /// Under a scope the ambiguity often is not one: only one of the two Works
    /// is reachable, so there is nothing to choose between and the caller's own
    /// spelling keeps working.
    func testAScopeDisambiguatesABareNameRatherThanRefusingIt() {
        guard case .rows(let indices) = ScopedRows.resolve(
            "Work", rows: rows, allowed: [0], fields: fields
        ) else { return XCTFail("expected a match") }
        XCTAssertEqual(paths(indices), ["iCloud/Work"])
    }

    /// …and when the scope really does admit both, it still refuses.
    func testAScopeAdmittingBothCarriersStillRefusesTheBareName() {
        guard case .ambiguous = ScopedRows.resolve(
            "Work", rows: rows, allowed: [0, 2], fields: fields
        ) else { return XCTFail("expected an ambiguity refusal") }
    }

    /// Two calendars that generate one path cannot be told apart by anything
    /// the request can carry, so the sentence says that rather than printing
    /// one string twice and inviting a retry that lands in the same place.
    func testTwoCalendarsSharingOnePathSayTheyCannotBeToldApart() {
        let twins: [ScopePath.Row] = [
            .init(container: "iCloud", leaf: "Work"),
            .init(container: "iCloud", leaf: "Work")
        ]
        XCTAssertEqual(ScopePath.ambiguousValues(in: twins), ["iCloud/Work"])
        guard case .ambiguous(let message) = ScopedRows.resolve(
            "iCloud/Work", rows: twins, allowed: nil, fields: fields
        ) else { return XCTFail("expected an ambiguity refusal") }
        XCTAssertTrue(message.contains("nothing in a request can tell them apart"), message)
    }

    /// ADR-011 decision 11: found-but-out-of-scope is a **refusal**, not a
    /// "not found". A not-found is indistinguishable from a real miss and
    /// leaves an operator with nothing to debug.
    func testAnExplicitOutOfScopeCalendarIsRefusedRatherThanNarrowedOrMissed() {
        guard case .outOfScope(let message) = ScopedRows.resolve(
            "Exchange/Work", rows: rows, allowed: [0, 1], fields: fields
        ) else { return XCTFail("expected a scope refusal") }
        XCTAssertTrue(message.contains("outside the calendars this client may reach"), message)
        XCTAssertTrue(message.contains("iCloud/Work, iCloud/Home"), message)
    }

    /// The other half of the same ruling: a name on no calendar at all is a
    /// plain miss, and must not be tagged as a boundary probe.
    func testANameOnNoCalendarAtAllIsANotFoundAndNotAViolation() {
        guard case .notFound(let message) = ScopedRows.resolve(
            "Nowhere", rows: rows, allowed: [0], fields: fields
        ) else { return XCTFail("expected a not-found") }
        XCTAssertTrue(message.contains("no calendar named \"Nowhere\""), message)
    }

    /// The refusal never says which account holds it — the disclosure ADR-011
    /// accepts is that *some* calendar carries the name, not where it lives.
    func testTheOutOfScopeRefusalNamesTheScopeAndNotTheHidingPlace() {
        guard case .outOfScope(let message) = ScopedRows.resolve(
            "Personal", rows: rows, allowed: [0], fields: fields
        ) else { return XCTFail("expected a scope refusal") }
        XCTAssertFalse(message.contains("On My Mac"), message)
    }

    // MARK: - The argument that was not passed

    /// An absent argument resolves **to the scope**, and a default that is
    /// inside the scope satisfies it — so an operator who granted the calendar
    /// the user already writes to gets exactly what they meant.
    func testADefaultInsideTheScopeIsUsed() {
        XCTAssertEqual(
            ScopedRows.defaultTarget(defaultIndex: 1, allowed: [0, 1], rows: rows, fields: fields),
            .rows([1])
        )
    }

    /// A scope of exactly one calendar resolves an absent argument, because
    /// there is only one answer.
    func testAScopeOfOneCalendarResolvesAnAbsentArgument() {
        XCTAssertEqual(
            ScopedRows.defaultTarget(defaultIndex: 2, allowed: [0], rows: rows, fields: fields),
            .rows([0])
        )
        XCTAssertEqual(
            ScopedRows.defaultTarget(defaultIndex: nil, allowed: [3], rows: rows, fields: fields),
            .rows([3])
        )
    }

    /// The write this whole seam exists for: EventKit answers
    /// `defaultCalendarForNewEvents` whatever the scope says, and filing an
    /// event there is a silent write to a calendar the profile never granted.
    /// With no way to pick, it asks — naming the choices — rather than writing.
    func testAnOutOfScopeDefaultIsRefusedRatherThanWrittenTo() {
        guard case .needsChoice(let message) = ScopedRows.defaultTarget(
            defaultIndex: 2, allowed: [0, 1], rows: rows, fields: fields
        ) else { return XCTFail("expected a refusal to guess") }
        XCTAssertTrue(message.contains("\"iCloud/Work\", \"iCloud/Home\""), message)
        XCTAssertTrue(message.contains("will not write to the default"), message)
    }

    /// A Mac with no default calendar at all and a scope holding several is
    /// the same answer, not a crash and not a write to `all[0]`.
    func testNoDefaultAtAllAndSeveralAllowedAlsoAsks() {
        guard case .needsChoice = ScopedRows.defaultTarget(
            defaultIndex: nil, allowed: [0, 1], rows: rows, fields: fields
        ) else { return XCTFail("expected a refusal to guess") }
    }

    // MARK: - Where a globally-found resource ended up

    /// `reminders_complete` matches a title across lists, the same shape as
    /// mail's `messages.byId` resolving globally, so where the thing *is* has
    /// to be read back off it. Comparing the **path** rather than the leaf is
    /// the other half of that lesson: every account may hold a `Reminders`.
    func testALeafNameIsNotEnoughToPlaceAReminderInsideTheScope() {
        XCTAssertTrue(ScopedRows.admits(
            container: "iCloud", leaf: "Work", allowed: [0], rows: rows))
        XCTAssertFalse(ScopedRows.admits(
            container: "Exchange", leaf: "Work", allowed: [0], rows: rows))
    }

    // MARK: - The reminders half is the same rule with different words

    /// The two services share the seam and differ only in the nouns, so a
    /// refusal a reminders caller reads talks about reminder lists. Getting
    /// this wrong is not a security hole but it is the difference between an
    /// operator finding the field to edit and not.
    func testReminderRefusalsAreWrittenInReminderWords() {
        let lists: [ScopePath.Row] = [
            .init(container: "iCloud", leaf: "Groceries"),
            .init(container: "Exchange", leaf: "Groceries")
        ]
        guard case .outOfScope(let message) = ScopedRows.resolve(
            "Exchange/Groceries", rows: lists, allowed: [0],
            fields: RemindersService.scopeFields
        ) else { return XCTFail("expected a scope refusal") }
        XCTAssertTrue(message.contains("outside the reminder lists this client may reach"), message)
        XCTAssertTrue(message.contains("`list_name`"), message)
    }
}
