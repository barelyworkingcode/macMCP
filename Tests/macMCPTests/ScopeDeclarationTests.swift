import XCTest
@testable import macmcp

/// What macMCP puts on the wire in `initialize` and answers `context/enumerate`
/// from -- the declaration half of ADR-011, checked against
/// `relay/docs/context-schema.md`'s contract rather than against itself.
///
/// Pure: a declaration is data, and none of this reaches EventKit, Contacts or
/// Mail.
final class ScopeDeclarationTests: XCTestCase {
    private func fragment(_ name: String) throws -> JSONObject {
        try XCTUnwrap(macmcpContextSchema[name]?.objectValue, "\(name) is not declared")
    }

    // MARK: - The six new fields

    /// Each row of ADR-011's table for calendars, contacts and reminders:
    /// `scope: restrict`, `source: operator`, the service's own `applies_to`,
    /// enumerable, and the leaf field depending on its account field.
    func testTheSixNewFieldsAreDeclaredAsSpecified() throws {
        let expected: [(name: String, appliesTo: String, dependsOn: String?)] = [
            ("calendar_accounts", "calendars_*", nil),
            ("calendars", "calendars_*", "calendar_accounts"),
            ("contact_accounts", "contacts_*", nil),
            ("contact_groups", "contacts_*", "contact_accounts"),
            ("reminder_accounts", "reminders_*", nil),
            ("reminder_lists", "reminders_*", "reminder_accounts")
        ]
        for row in expected {
            let f = try fragment(row.name)
            XCTAssertEqual(f["type"]?.stringValue, "array", row.name)
            XCTAssertEqual(f["items"]?.objectValue?["type"]?.stringValue, "string", row.name)
            XCTAssertEqual(f["scope"]?.stringValue, "restrict", row.name)
            XCTAssertEqual(f["source"]?.stringValue, "operator", row.name)
            XCTAssertEqual(f["applies_to"]?.stringsValue, [row.appliesTo], row.name)
            XCTAssertEqual(f["enumerable"]?.boolValue, true, row.name)
            XCTAssertEqual(f["depends_on"]?.stringsValue, row.dependsOn.map { [$0] }, row.name)
            let description = try XCTUnwrap(f["description"]?.stringValue, row.name)
            XCTAssertFalse(description.isEmpty, "\(row.name) has no operator-facing description")
        }
    }

    /// The mail declaration is byte-for-byte what it was before the shared
    /// core existed. Relay reads this to decide what a grant may narrow, so a
    /// keyword quietly changing shape is a permission changing shape.
    func testTheMailDeclarationIsUnchanged() throws {
        let accounts = try fragment("mail_accounts")
        XCTAssertEqual(accounts["description"]?.stringValue, "Mail accounts this client may read from or send as")
        XCTAssertEqual(accounts["applies_to"]?.stringsValue, ["mail_*"])
        XCTAssertEqual(accounts["enumerable"]?.boolValue, true)
        XCTAssertNil(accounts["depends_on"])

        let mailboxes = try fragment("mail_mailboxes")
        XCTAssertEqual(mailboxes["depends_on"]?.stringsValue, ["mail_accounts"])

        let dirs = try fragment("file_dirs")
        XCTAssertEqual(dirs["source"]?.stringValue, "project_path")
        XCTAssertEqual(dirs["applies_to"]?.stringsValue, ["mail_save_attachment"])
    }

    /// **Omitted, not `false`.** Relay's contract is that a keyword's absence
    /// is its default, and `ContextEnumerateDispatchTests` reads the absence
    /// of `enumerable` on `file_dirs` as the thing that makes its `-32602`
    /// refusal mean something.
    func testNonEnumerableAndDependencyFreeFieldsOmitTheKeywordEntirely() throws {
        XCTAssertNil(try fragment("file_dirs")["enumerable"])
        XCTAssertNil(try fragment("file_dirs")["depends_on"])
        XCTAssertNil(try fragment("calendar_accounts")["depends_on"])
    }

    // MARK: - Declaration and implementation cannot drift

    /// `enumerable` is derived from carrying an enumerator, so "declares
    /// enumerable but does not implement it" is not a reachable state. This
    /// asserts the derivation rather than trusting it: every field the wire
    /// says is enumerable has a function behind it, and every one that does
    /// says so.
    func testEnumerableIsExactlyTheFieldsThatCarryAnEnumerator() throws {
        for field in scopeFields {
            let declared = try fragment(field.name)["enumerable"]?.boolValue ?? false
            XCTAssertEqual(declared, field.enumerate != nil, field.name)
        }
    }

    /// A `depends_on` naming a field that is not declared would send relay
    /// asking for values of something that does not exist.
    func testEveryDependencyNamesADeclaredField() {
        let names = Set(scopeFields.map(\.name))
        for field in scopeFields {
            for dependency in field.dependsOn {
                XCTAssertTrue(names.contains(dependency), "\(field.name) depends on undeclared \(dependency)")
            }
        }
    }

    /// A field governing tools that do not exist is a restriction that
    /// restricts nothing, and would read in relay's editor as a control the
    /// operator has.
    func testEveryAppliesToPatternReachesAtLeastOneRegisteredTool() {
        let registry = ToolRegistry()
        PermissionsService.register(registry)
        CalendarService.register(registry)
        ContactsService.register(registry)
        RemindersService.register(registry)
        MailService.register(registry)
        MessagesService.register(registry)
        WebService.register(registry)
        let tools = registry.allTools().map(\.name)
        for field in scopeFields {
            for pattern in field.appliesTo {
                XCTAssertTrue(
                    tools.contains { globMatches(pattern, $0) },
                    "\(field.name)'s applies_to \"\(pattern)\" matches no registered tool"
                )
            }
        }
    }
}
