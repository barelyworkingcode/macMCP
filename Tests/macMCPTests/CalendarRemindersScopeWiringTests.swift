import XCTest
@testable import macmcp

/// That the enforcement is **wired in**, at every calendar and reminders tool.
///
/// `EventKitScopeTests` covers what the rule decides. This covers the thing a
/// pure seam cannot prove and which is exactly how phase 1 came to declare four
/// fields it did not enforce: a correct seam nobody calls confines nothing, and
/// relay's call-time presence check would still have rendered such a profile as
/// confined. ADR-011 decision 4 is explicit that macMCP's test must be
/// independent of relay's — "one check, not two" — so a check that only holds
/// because the other side also ran one is not this check.
///
/// **The refusal path is the only one reachable hermetically.** It returns
/// before `store.calendars(for:)`, which is why the presence check sits ahead
/// of the TCC check in every handler. A mediated call carrying real values
/// would read this Mac's own calendars, which the suite may not do, so the
/// admitting direction is pinned on `presenceRefusal` itself — the same
/// function the handlers call, with no EventKit underneath it.
final class CalendarRemindersScopeWiringTests: XCTestCase {
    private static let calendarTools = ["calendars_list", "calendars_list_events", "calendars_create_event"]
    private static let reminderTools = ["reminders_list", "reminders_create", "reminders_complete"]

    private func registry() -> ToolRegistry {
        let registry = ToolRegistry()
        CalendarService.register(registry)
        RemindersService.register(registry)
        return registry
    }

    /// `_meta` present with nothing else in it: relay injects `project_id` on
    /// every mediated call, so this is what a profile that never set a scope
    /// looks like from here.
    private let mediatedWithNoScope: JSONObject = ["project_id": .string("prof_hermes")]

    private func isScopeViolation(_ result: MCPCallResult) -> Bool {
        result.isError == true && result.meta?["scope_violation"] == .bool(true)
    }

    private func text(_ result: MCPCallResult) -> String {
        result.content.map(\.text).joined()
    }

    // MARK: - Out of scope: refused, at every tool

    /// Decision 4 at the tool surface. Note the arguments are the ones each
    /// tool requires, so nothing here is refused for being malformed.
    func testEveryCalendarAndRemindersToolRefusesAMediatedCallWithNoScope() {
        let reg = registry()
        let arguments: [String: JSONObject] = [
            "calendars_list": [:],
            "calendars_list_events": ["start_date": .string("2026-06-12"), "end_date": .string("2026-06-13")],
            "calendars_create_event": [
                "title": .string("t"),
                "start_date": .string("2026-06-12"),
                "end_date": .string("2026-06-13")
            ],
            "reminders_list": [:],
            "reminders_create": ["title": .string("t")],
            "reminders_complete": ["title": .string("t")]
        ]
        for tool in Self.calendarTools + Self.reminderTools {
            let result = reg.call(name: tool, arguments: arguments[tool], meta: mediatedWithNoScope)
            XCTAssertTrue(isScopeViolation(result), "\(tool) did not refuse a mediated call with no scope")
            XCTAssertTrue(
                text(result).contains("refusal rather than \"everything\""),
                "\(tool): \(text(result))"
            )
        }
    }

    /// A field **absent** still refuses -- decision 4's untouched half. What
    /// changed (ADR-011 addendum, "A star and an empty array") is that a
    /// field present as an **explicit** empty array no longer reads the same
    /// way: it is `.confirmedEmpty`, not absent, and `presenceRefusal` -- the
    /// same pure function every handler calls before touching EventKit --
    /// must not treat it as a violation. What that resolves *to*
    /// (`.confined([])`, an empty but successful `calendars_list`) is
    /// `EventKitScopeTests.testAConfirmedEmptyValueIsAnEmptyConfinementNotARefusal`,
    /// which can assert it purely; this file cannot go further than the
    /// presence check without a real EventKit store to read, per the class
    /// doc above.
    func testAPresentEmptyScopeValueIsNotAPresenceRefusalUnlikeAbsent() {
        let absent: JSONObject = ["project_id": .string("p"), "calendars": .array([.string("iCloud/Work")])]
        XCTAssertNotNil(ResourceScope.parse(absent).presenceRefusal(tool: "calendars_list"))

        let confirmedEmpty: JSONObject = [
            "project_id": .string("p"),
            "calendar_accounts": .array([]),
            "calendars": .array([])
        ]
        XCTAssertNil(ResourceScope.parse(confirmedEmpty).presenceRefusal(tool: "calendars_list"))
    }

    /// Half a scope is not a scope: `calendars` set and `calendar_accounts`
    /// missing still refuses, and names the field that is missing rather than
    /// the one that is not.
    func testOneOfTheTwoFieldsIsNotEnough() {
        let reg = registry()
        let half: JSONObject = [
            "project_id": .string("p"),
            "calendars": .array([.string("iCloud/Work")])
        ]
        let result = reg.call(name: "calendars_list", arguments: nil, meta: half)
        XCTAssertTrue(isScopeViolation(result))
        XCTAssertTrue(text(result).contains("`calendar_accounts`"), text(result))
    }

    /// A mail scope does not authorise a calendar call. The fields are read by
    /// their own declared names, so a profile scoped to Bob's INBOX and nothing
    /// else reaches no calendar at all.
    func testAMailScopeDoesNotAdmitACalendarCall() {
        let reg = registry()
        let mailOnly: JSONObject = [
            "project_id": .string("p"),
            "mail_accounts": .array([.string("Bob")]),
            "mail_mailboxes": .array([.string("INBOX")])
        ]
        XCTAssertTrue(isScopeViolation(reg.call(name: "calendars_list", arguments: nil, meta: mailOnly)))
        XCTAssertTrue(isScopeViolation(reg.call(name: "reminders_list", arguments: nil, meta: mailOnly)))
    }

    // MARK: - In scope: admitted, at every tool

    /// The other direction, on the function the handlers call. A scope that
    /// carries both of a tool's fields passes the presence check — otherwise
    /// the refusal above would be unconditional, which is a confinement that
    /// confines by breaking the tool.
    func testAScopeCarryingBothFieldsIsAdmittedAtEveryTool() {
        let calendarScope = ResourceScope.parse([
            "project_id": .string("p"),
            "calendar_accounts": .array([.string("iCloud")]),
            "calendars": .array([.string("iCloud/Work")])
        ])
        for tool in Self.calendarTools {
            XCTAssertNil(calendarScope.presenceRefusal(tool: tool), tool)
        }
        let reminderScope = ResourceScope.parse([
            "project_id": .string("p"),
            "reminder_accounts": .array([.string("iCloud")]),
            "reminder_lists": .array([.string("iCloud/Groceries")])
        ])
        for tool in Self.reminderTools {
            XCTAssertNil(reminderScope.presenceRefusal(tool: tool), tool)
        }
    }

    /// An unmediated call — macmcp on a bare stdio pipe, which is every call it
    /// has ever served — is not scoped and is not refused.
    func testAnUnmediatedCallIsNotRefused() {
        for tool in Self.calendarTools + Self.reminderTools {
            XCTAssertNil(ResourceScope.none.presenceRefusal(tool: tool), tool)
        }
    }

    // MARK: - The declaration is what selects the tools

    /// Each of the six tools is governed by **both** of its service's fields.
    /// The presence check is driven by `applies_to` rather than by a list
    /// re-typed per handler, so this is what makes the six refusals above
    /// follow from the declaration instead of from six remembered calls.
    func testEachToolIsGovernedByBothOfItsServicesFields() {
        for tool in Self.calendarTools {
            XCTAssertEqual(restrictFieldsGoverning(tool: tool), ["calendar_accounts", "calendars"], tool)
        }
        for tool in Self.reminderTools {
            XCTAssertEqual(restrictFieldsGoverning(tool: tool), ["reminder_accounts", "reminder_lists"], tool)
        }
    }

    /// The two services must not govern each other: a calendar scope is not a
    /// reminders grant, which is the same separation `mail_*` already has.
    func testTheTwoServicesDoNotGovernEachOther() {
        for tool in Self.calendarTools {
            XCTAssertFalse(restrictFieldsGoverning(tool: tool).contains("reminder_lists"), tool)
        }
        for tool in Self.reminderTools {
            XCTAssertFalse(restrictFieldsGoverning(tool: tool).contains("calendars"), tool)
        }
    }
}
