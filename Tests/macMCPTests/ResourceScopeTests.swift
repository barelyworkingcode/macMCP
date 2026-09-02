import XCTest
@testable import macmcp

/// The shared core `MailScope` was generalised into (ADR-011), exercised
/// through the four fields that are **not** mail's -- because a mechanism that
/// only ever ran against the service it was extracted from is not a mechanism,
/// it is the same code with a new file name.
///
/// Everything here is pure: `_meta` in, a decision out. Nothing touches
/// EventKit, Contacts or Mail.
final class ResourceScopeTests: XCTestCase {
    // MARK: - The three states, on a field mail never heard of

    func testTheFiveStatesHoldForANewServicesField() {
        // 1. Nobody mediated: behave exactly as macmcp on a bare stdio pipe.
        XCTAssertEqual(ResourceScope.parse(nil).access("calendars"), .unscoped)
        // 2. Mediated, field **absent** -> refuse. Not "unrestricted", not
        //    "everything": ADR-011 decision 4, which is the whole reason this
        //    type keeps `isScoped` separate from any field's value. This is
        //    the state reached by doing nothing -- forgetting the field, or a
        //    relay bug that fails to inject it -- so it must never look like
        //    a reviewed decision, unlike 2b and 2c below.
        XCTAssertEqual(ResourceScope.parse(["project_id": .string("p")]).access("calendars"), .refuse)
        // 2b. Mediated, field **present** and empty -> `.confirmedEmpty`, not
        //     `.refuse`. Reachable only by an explicit action (relay's
        //     "confirm nothing to grant" button), never by omission -- see
        //     the ADR-011 addendum ("A star and an empty array"). Distinct
        //     from 2 specifically so a consumer can resolve it to "the
        //     confined set is empty" (an ordinary, successful empty result)
        //     rather than a refusal.
        XCTAssertEqual(ResourceScope.parse(["calendars": .array([])]).access("calendars"), .confirmedEmpty)
        // 2c. Mediated, field present as exactly `["*"]` -> `.unrestricted`.
        //     Also reachable only by an explicit action, never by omission or
        //     by a real value that happens to be the string "*" mixed with
        //     anything else.
        XCTAssertEqual(ResourceScope.parse(["calendars": .array([.string("*")])]).access("calendars"), .unrestricted)
        XCTAssertEqual(
            ResourceScope.parse(["calendars": .array([.string("*"), .string("iCloud/Work")])]).access("calendars"),
            .allowed(["*", "iCloud/Work"]),
            "\"*\" mixed with a real value is not the wildcard -- it is a literal value that folds and "
            + "matches nothing real, so it fails closed rather than guessing what was meant"
        )
        // 3. Mediated, with values.
        XCTAssertEqual(
            ResourceScope.parse(["calendars": .array([.string("iCloud/Work")])]).access("calendars"),
            .allowed(["iCloud/Work"])
        )
    }

    /// The one test in this mechanism that is macMCP's own rather than
    /// relay's, restated for a field declared after the extraction: `_meta`
    /// **present at all** is what makes a call governed. Reading it as "did
    /// `_meta` carry one of my keys" would mean relay failing to inject a
    /// field produced a call indistinguishable from an unmediated one, so the
    /// confinement would rest entirely on relay's own check having run --
    /// one check, not two.
    func testMediationRatherThanTheFieldsPresenceIsWhatGoverns() {
        let mediatedWithNoCalendarScope = ResourceScope.parse(["mail_accounts": .array([.string("Bob")])])
        XCTAssertTrue(mediatedWithNoCalendarScope.isScoped)
        XCTAssertEqual(mediatedWithNoCalendarScope.access("calendars"), .refuse)
        XCTAssertEqual(mediatedWithNoCalendarScope.access("contact_groups"), .refuse)
        XCTAssertEqual(mediatedWithNoCalendarScope.access("reminder_lists"), .refuse)
    }

    func testAMalformedValueFailsClosedRatherThanReadingAsUnscoped() {
        let scope = ResourceScope.parse(["calendar_accounts": .int(5)])
        XCTAssertTrue(scope.isScoped)
        XCTAssertNil(scope.values(of: "calendar_accounts"))
        XCTAssertEqual(scope.access("calendar_accounts"), .refuse)
    }

    /// `_meta` is a general channel -- it carries `project_id` today and could
    /// carry an API key tomorrow -- so a scope is built from the **declared**
    /// fields and nothing else. A scope assembled out of whatever happened to
    /// be in `_meta` would be a scope no operator wrote.
    func testAnUndeclaredKeyInMetaIsNotAScopeField() {
        let scope = ResourceScope.parse(["not_a_declared_field": .array([.string("x")])])
        XCTAssertNil(scope.values(of: "not_a_declared_field"))
        XCTAssertEqual(scope.access("not_a_declared_field"), .refuse)
    }

    // MARK: - The presence check reads the declaration

    func testThePresenceCheckGovernsEachServicesOwnToolsAndStopsThere() throws {
        let calendarScope = ResourceScope.parse([
            "calendar_accounts": .array([.string("iCloud")]),
            "calendars": .array([.string("iCloud/Work")])
        ])
        // Its own tools are satisfied...
        XCTAssertNil(calendarScope.presenceRefusal(tool: "calendars_list_events"))
        // ...and every other service's are refused, because a mediated call
        // that names no mailbox has no mailbox to reach.
        let mailRefusal = try XCTUnwrap(calendarScope.presenceRefusal(tool: "mail_search"))
        XCTAssertTrue(mailRefusal.contains("mail_accounts") || mailRefusal.contains("mail_mailboxes"), mailRefusal)
        XCTAssertNotNil(calendarScope.presenceRefusal(tool: "contacts_list"))
        XCTAssertNotNil(calendarScope.presenceRefusal(tool: "reminders_list"))
        // A tool no field declares is governed by nothing at all.
        XCTAssertNil(calendarScope.presenceRefusal(tool: "web_fetch"))
    }

    func testEachNewFieldIsRequiredIndependentlyOfItsSibling() throws {
        let onlyAccounts = ResourceScope.parse(["calendar_accounts": .array([.string("iCloud")])])
        let refusal = try XCTUnwrap(
            onlyAccounts.presenceRefusal(tool: "calendars_list"),
            "calendars is declared to govern calendars_* and was not required"
        )
        XCTAssertTrue(refusal.contains("`calendars`"), refusal)

        let onlyCalendars = ResourceScope.parse(["calendars": .array([.string("iCloud/Work")])])
        let other = try XCTUnwrap(onlyCalendars.presenceRefusal(tool: "calendars_list"))
        XCTAssertTrue(other.contains("`calendar_accounts`"), other)
    }

    /// The unmediated case is what must not move.
    func testAnUnmediatedCallIsNotSubjectToThePresenceCheckForAnyService() {
        for tool in ["calendars_list", "contacts_list", "reminders_list", "mail_search"] {
            XCTAssertNil(ResourceScope.none.presenceRefusal(tool: tool), tool)
        }
    }

    /// The refusal names the field, the noun and the tool -- the three things
    /// an operator needs to act on it. The noun comes off the declaration, so
    /// a field added later cannot arrive with "there is no  it may reach".
    func testTheRefusalNamesTheFieldItsNounAndTheTool() throws {
        let text = try XCTUnwrap(ResourceScope.parse([:]).presenceRefusal(tool: "reminders_create"))
        XCTAssertTrue(text.contains("`reminder_accounts`"), text)
        XCTAssertTrue(text.contains("reminder account"), text)
        XCTAssertTrue(text.contains("reminders_create"), text)
        for field in scopeFields {
            XCTAssertFalse(field.noun.isEmpty, "\(field.name) declares no noun")
        }
    }

    // MARK: - The fingerprint covers every declared field

    func testTwoCalendarScopesCannotSpellTheSameFingerprint() {
        let work = ResourceScope.parse(["calendars": .array([.string("iCloud/Work")])])
        let home = ResourceScope.parse(["calendars": .array([.string("iCloud/Home")])])
        XCTAssertNotEqual(work.cacheFingerprint, home.cacheFingerprint)
        XCTAssertNotEqual(work.cacheFingerprint, ResourceScope.none.cacheFingerprint)
        XCTAssertEqual(
            work.cacheFingerprint,
            ResourceScope.parse(["calendars": .array([.string("icloud/work")])]).cacheFingerprint,
            "the same confinement, folded, is the same key"
        )
    }

    /// The length prefix, on a value that contains the separator a naive join
    /// would have used. A calendar path contains a `/` by construction, so the
    /// hazard is not hypothetical for this field the way it merely was for a
    /// mailbox.
    func testAValueContainingASeparatorCannotCollideWithTwoValues() {
        let one = ResourceScope.parse(["calendars": .array([.string("a/b")])])
        let two = ResourceScope.parse(["calendars": .array([.string("a"), .string("b")])])
        XCTAssertNotEqual(one.cacheFingerprint, two.cacheFingerprint)
    }

    /// A field declared later must join the fingerprint automatically -- a key
    /// covering three of nine fields is a cache bypass the day a fourth starts
    /// mattering.
    func testEveryDeclaredFieldHasItsOwnSlot() {
        let all = restrictFields.map(\.name)
        for name in all {
            let scope = ResourceScope.parse([name: .array([.string("value")])])
            XCTAssertNotEqual(
                scope.cacheFingerprint,
                ResourceScope.parse([:]).cacheFingerprint,
                "\(name) does not change the fingerprint"
            )
        }
        XCTAssertEqual(Set(all).count, all.count, "two fields share a name")
    }

    // MARK: - Path containment, as a shared rule

    func testTheContainmentWalkRefusesABoundThatIsNotAbsolute() {
        XCTAssertEqual(ResourceScope.bound("/tmp/x", within: ["."]), .rootNotAbsolute("."))
        XCTAssertEqual(ResourceScope.bound("/tmp/x", within: [""]), .rootNotAbsolute(""))
        XCTAssertEqual(ResourceScope.bound("/tmp/x", within: ["/"]), .rootIsFilesystemRoot("/"))
        XCTAssertEqual(ResourceScope.bound("relative.txt", within: ["/tmp"]), .notAbsolute)
    }

    func testRealPathAnchorsOrAnswersNil() {
        XCTAssertNil(ResourceScope.realPath("."))
        XCTAssertNil(ResourceScope.realPath(""))
        XCTAssertNil(ResourceScope.realPath(".."))
        XCTAssertEqual(ResourceScope.realPath("/"), "/")
    }
}
