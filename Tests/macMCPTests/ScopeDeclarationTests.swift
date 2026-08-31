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
    ///
    /// **`contact_groups` is the one row whose `applies_to` is not its
    /// service's glob**, and that is the point of
    /// `testContactGroupsGovernsOnlyTheGroupTools` below rather than an
    /// exception smuggled into this table.
    func testTheSixNewFieldsAreDeclaredAsSpecified() throws {
        let expected: [(name: String, appliesTo: [String], dependsOn: String?)] = [
            ("calendar_accounts", ["calendars_*"], nil),
            ("calendars", ["calendars_*"], "calendar_accounts"),
            ("contact_accounts", ["contacts_*"], nil),
            ("contact_groups", [
                "contacts_list_groups", "contacts_create_group",
                "contacts_add_to_group", "contacts_remove_from_group"
            ], nil),
            ("reminder_accounts", ["reminders_*"], nil),
            ("reminder_lists", ["reminders_*"], "reminder_accounts")
        ]
        for row in expected {
            let f = try fragment(row.name)
            XCTAssertEqual(f["type"]?.stringValue, "array", row.name)
            XCTAssertEqual(f["items"]?.objectValue?["type"]?.stringValue, "string", row.name)
            XCTAssertEqual(f["scope"]?.stringValue, "restrict", row.name)
            XCTAssertEqual(f["source"]?.stringValue, "operator", row.name)
            XCTAssertEqual(f["applies_to"]?.stringsValue, row.appliesTo, row.name)
            XCTAssertEqual(f["enumerable"]?.boolValue, true, row.name)
            XCTAssertEqual(f["depends_on"]?.stringsValue, row.dependsOn.map { [$0] }, row.name)
            let description = try XCTUnwrap(f["description"]?.stringValue, row.name)
            XCTAssertFalse(description.isEmpty, "\(row.name) has no operator-facing description")
        }
    }

    /// **A message is always in a mailbox; a card need not be in a group.**
    ///
    /// Mail can put both of its axes on every `mail_*` tool because scoping
    /// mailboxes scopes messages. Copying that shape to contacts -- which the
    /// first pass did, declaring `contact_groups` with `applies_to:
    /// ["contacts_*"]` -- made group membership mandatory for every contacts
    /// tool, which does not tighten the confinement so much as remove one an
    /// operator needs: "every card in this account, group or not" becomes
    /// inexpressible, and account-level scoping with it.
    ///
    /// So the axes are declared for what they bound: `contact_accounts` on
    /// every contacts tool, `contact_groups` on exactly the four that cannot
    /// function without naming a group. Asserted tool by tool, in both
    /// directions, because a field that governs one tool too many is a
    /// capability silently removed and one tool too few is a confinement
    /// silently missing.
    func testContactGroupsGovernsOnlyTheGroupTools() {
        let groupTools = [
            "contacts_list_groups", "contacts_create_group",
            "contacts_add_to_group", "contacts_remove_from_group"
        ]
        let cardTools = [
            "contacts_list", "contacts_get", "contacts_create",
            "contacts_update", "contacts_delete", "contacts_search_by_phone"
        ]
        for tool in groupTools + cardTools {
            XCTAssertTrue(
                restrictFieldsGoverning(tool: tool).contains("contact_accounts"),
                "\(tool) is not bounded by contact_accounts"
            )
        }
        for tool in groupTools {
            XCTAssertEqual(restrictFieldsGoverning(tool: tool), ["contact_accounts", "contact_groups"], tool)
        }
        for tool in cardTools {
            XCTAssertEqual(
                restrictFieldsGoverning(tool: tool), ["contact_accounts"],
                "\(tool) requires a contact group grant it has no use for"
            )
        }
    }

    /// The four are named rather than matched by a glob, and this is what says
    /// the list is exhaustive: every registered `contacts_*` tool is bounded by
    /// at least the account field, so a tool added later cannot escape the
    /// scope entirely by being missed off both lists above.
    func testEveryRegisteredContactsToolIsAccountedFor() {
        let registry = ToolRegistry()
        ContactsService.register(registry)
        let tools = registry.allTools().map(\.name).sorted()
        XCTAssertEqual(tools.count, 10, "the contacts surface changed: \(tools)")
        for tool in tools {
            XCTAssertTrue(
                restrictFieldsGoverning(tool: tool).contains("contact_accounts"),
                "\(tool) escapes the contacts scope entirely"
            )
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

        // `file_dirs` is deliberately NOT a mail field, which is why its
        // `applies_to` grew past mail: `capture_screenshot`, `capture_audio`
        // and `utilities_play_sound` each open a file on this host and none of
        // them can function without a directory, which is the rule that puts a
        // tool in this list. `mail_send`, `mail_create_draft` and
        // `mail_get_source` stay out of it for the opposite reason -- each
        // works fine without one, and the parameter is what refuses.
        let dirs = try fragment("file_dirs")
        XCTAssertEqual(dirs["source"]?.stringValue, "project_path")
        XCTAssertEqual(
            dirs["applies_to"]?.stringsValue,
            ["mail_save_attachment", "capture_screenshot", "capture_audio", "utilities_play_sound"]
        )
        for excluded in ["mail_send", "mail_create_draft", "mail_get_source"] {
            XCTAssertFalse(
                restrictFieldsGoverning(tool: excluded).contains("file_dirs"),
                "\(excluded) has an optional parameter needing a directory, not a tool-level need"
            )
        }
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
        CaptureService.register(registry)
        UtilitiesService.register(registry)
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
