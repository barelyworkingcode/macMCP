import XCTest
@testable import macmcp

/// What every tool claims about itself, pinned tool by tool.
///
/// Both hints are read by a permission check in relay -- `readOnlyHint` by the
/// access mode, `openWorldHint` by the `allow_external` grant -- and both
/// default, when absent, to the answer that costs the tool its availability or
/// hands it a reach it should not have. `MCPAnnotations` makes an *omission*
/// impossible by having no optionals, so what is left to go wrong is a wrong
/// *value*, and the only way to catch that is to write the intended value down
/// somewhere a change has to be made deliberately. That is this table.
///
/// A tool added later fails here twice over: `testEveryRegisteredToolIsInTheTable`
/// reports it as unaccounted for, and the count assertion moves. Neither can be
/// satisfied without someone deciding what the new tool reaches.
///
/// Pure: registration builds schemas and closures. Nothing in this file calls a
/// handler, so no Apple Event, no EventKit query and no network request happens.
final class ToolAnnotationTests: XCTestCase {
    /// Every tool macMCP serves, with the two hints it publishes.
    ///
    /// The `openWorld` column answers one question: **is the call itself what
    /// reaches beyond this Mac?** Two things deliberately do not count, and
    /// each is argued at the service that relies on it:
    ///
    /// - replication of a local store to the user's own account
    ///   (`MailService.register`), which is what keeps every mail read, and
    ///   `mail_create_draft`, closed;
    /// - naming a remote thing without contacting it
    ///   (`MapsService.maps_get_directions`).
    static let expected: [String: (readOnly: Bool, openWorld: Bool)] = [
        // Calendar -- EKEventStore, local. No attendees, so no invitations.
        "calendars_list": (true, false),
        "calendars_list_events": (true, false),
        "calendars_create_event": (false, false),

        // Capture -- local devices to local files. Privileged, not open world.
        "capture_screenshot": (false, false),
        "capture_audio": (false, false),

        // Contacts -- CNContactStore, local.
        "contacts_list": (true, false),
        "contacts_get": (true, false),
        "contacts_create": (false, false),
        "contacts_update": (false, false),
        "contacts_delete": (false, false),
        "contacts_list_groups": (true, false),
        "contacts_create_group": (false, false),
        "contacts_add_to_group": (false, false),
        "contacts_remove_from_group": (false, false),
        "contacts_search_by_phone": (true, false),

        // Location -- all three reach Apple. `location_get_current` included:
        // a Mac has no GPS and resolves position over the network.
        "location_get_current": (true, true),
        "location_geocode": (true, true),
        "location_reverse_geocode": (true, true),

        // Mail -- one open-world tool, and it is the one that delivers.
        "mail_list_accounts": (true, false),
        "mail_list_mailboxes": (true, false),
        "mail_get_emails": (true, false),
        "mail_get_email": (true, false),
        "mail_search": (true, false),
        "mail_send": (false, true),
        "mail_create_draft": (false, false),
        "mail_save_attachment": (false, false),
        "mail_get_source": (false, false),
        "mail_move": (false, false),
        "mail_mark_read": (false, false),

        // Maps -- geocoding and Maps.app reach Apple; the directions tool is
        // string formatting and reaches nothing.
        "maps_search": (true, true),
        "maps_open": (false, true),
        "maps_get_directions": (true, false),

        // Messages -- reads are SQLite on chat.db; sending is delivery.
        "messages_list_chats": (true, false),
        "messages_get_chat": (true, false),
        "messages_search": (true, false),
        "messages_send": (false, true),

        // System
        "permissions_check": (true, false),

        // Reminders -- EventKit, local.
        "reminders_list": (true, false),
        "reminders_create": (false, false),
        "reminders_complete": (false, false),

        // Shortcuts -- running one is arbitrary user code.
        "shortcuts_list": (true, false),
        "shortcuts_run": (false, true),

        // Utilities -- afplay, measured to open no socket.
        "utilities_play_sound": (false, false),

        // Weather -- api.open-meteo.com on every call.
        "weather_current": (true, true),
        "weather_forecast": (true, true),
        "weather_hourly": (true, true),

        // Web -- the tool this hint was added for.
        "web_fetch": (true, true)
    ]

    /// Every service, registered exactly as `main.swift` registers them.
    static func fullRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        PermissionsService.register(registry)
        CalendarService.register(registry)
        ContactsService.register(registry)
        RemindersService.register(registry)
        LocationService.register(registry)
        MapsService.register(registry)
        CaptureService.register(registry)
        MailService.register(registry)
        MessagesService.register(registry)
        ShortcutsService.register(registry)
        UtilitiesService.register(registry)
        WeatherService.register(registry)
        WebService.register(registry)
        return registry
    }

    // MARK: - The table is the whole surface

    func testTheToolSurfaceIsExactlyTheTable() {
        let registered = Set(Self.fullRegistry().allTools().map(\.name))
        XCTAssertEqual(registered.count, 47, "the tool count changed")
        XCTAssertEqual(
            registered.subtracting(Self.expected.keys).sorted(), [],
            "registered but unclassified: decide what these reach before shipping them"
        )
        XCTAssertEqual(
            Set(Self.expected.keys).subtracting(registered).sorted(), [],
            "classified but not registered: a stale row here silently stops guarding anything"
        )
    }

    /// The claim each tool publishes, one assertion per tool.
    func testEveryToolPublishesTheHintsItIsClassifiedWith() throws {
        for tool in Self.fullRegistry().allTools() {
            let want = try XCTUnwrap(Self.expected[tool.name], "\(tool.name) is not classified")
            let annotations = try XCTUnwrap(
                tool.annotations,
                "\(tool.name) registered no annotations at all -- an absent openWorldHint reads as "
                    + "open world and an absent readOnlyHint reads as mutating"
            )
            XCTAssertEqual(annotations.readOnlyHint, want.readOnly, "\(tool.name) readOnlyHint")
            XCTAssertEqual(annotations.openWorldHint, want.openWorld, "\(tool.name) openWorldHint")
        }
    }

    /// The twelve, named rather than counted, because "12 tools are open
    /// world" is satisfied by any twelve.
    func testExactlyTheseTwelveToolsAreOpenWorld() {
        let openWorld = Self.fullRegistry().allTools()
            .filter { $0.annotations?.openWorldHint == true }
            .map(\.name)
            .sorted()
        XCTAssertEqual(openWorld, [
            "location_geocode",
            "location_get_current",
            "location_reverse_geocode",
            "mail_send",
            "maps_open",
            "maps_search",
            "messages_send",
            "shortcuts_run",
            "weather_current",
            "weather_forecast",
            "weather_hourly",
            "web_fetch"
        ])
    }

    // MARK: - The split this annotation exists for

    /// **`mail_send` and `mail_create_draft` differ on `openWorldHint` and on
    /// nothing else**, which is what makes "may draft, may not send"
    /// expressible as a grant rather than as a hand-maintained tool denylist.
    ///
    /// Both mutate, so the access mode cannot tell them apart: a profile that
    /// can draft must hold `write`, and `write` admits `mail_send` too. The
    /// second axis is the only thing that separates them, and it separates
    /// them in the right direction -- a draft lands in the sending account's
    /// own Drafts for a human to review, a send is delivered to a recipient
    /// the caller named and cannot be recalled.
    func testDraftingIsClosedWorldAndSendingIsNot() throws {
        let tools = Dictionary(uniqueKeysWithValues: Self.fullRegistry().allTools().map { ($0.name, $0) })
        let send = try XCTUnwrap(tools["mail_send"]?.annotations)
        let draft = try XCTUnwrap(tools["mail_create_draft"]?.annotations)

        XCTAssertTrue(send.openWorldHint, "mail_send delivers to an arbitrary recipient")
        XCTAssertFalse(draft.openWorldHint, "a draft is written locally and delivered to nobody")

        XCTAssertEqual(
            send.readOnlyHint, draft.readOnlyHint,
            "both compose a message, so the access mode cannot be what separates them"
        )
        XCTAssertFalse(send.readOnlyHint)
    }

    /// The other pairing worth pinning: read-only and open world are
    /// independent, and each combination is populated. If a future change made
    /// `openWorldHint` a restatement of `readOnlyHint`, this is what notices.
    func testTheTwoHintsAreIndependent() {
        let tools = Self.fullRegistry().allTools().compactMap(\.annotations)
        func count(_ readOnly: Bool, _ openWorld: Bool) -> Int {
            tools.filter { $0.readOnlyHint == readOnly && $0.openWorldHint == openWorld }.count
        }
        XCTAssertGreaterThan(count(true, true), 0, "read-only and open world: web_fetch, weather_*")
        XCTAssertGreaterThan(count(false, true), 0, "mutating and open world: mail_send")
        XCTAssertGreaterThan(count(true, false), 0, "read-only and closed: mail_search")
        XCTAssertGreaterThan(count(false, false), 0, "mutating and closed: mail_create_draft")
    }
}

/// The same claims, read back off the wire the way relay reads them.
///
/// `MCPTool` carries the hints; `main.swift` decides what `tools/list` actually
/// emits, and that is a separate piece of code with its own way of going wrong
/// -- the version this replaced emitted `annotations` only when a hint had been
/// set, so an omission published a permission decision by saying nothing.
/// Relay reads these out of the JSON by exact key, so the JSON is what has to
/// be asserted.
///
/// Hermetic: `tools/list` is answered from `ToolRegistry` alone. No handler
/// runs, so nothing here touches Mail, EventKit or the network.
final class ToolAnnotationWireTests: StdioServerTestCase {
    private func listedTools() throws -> [[String: Any]] {
        let response = try send(method: "tools/list", params: nil)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["tools"] as? [[String: Any]])
    }

    func testEveryToolOnTheWireCarriesBothHintsAsBooleans() throws {
        let tools = try listedTools()
        XCTAssertEqual(tools.count, 47)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(
                tool["annotations"] as? [String: Any],
                "\(name) published no annotations object"
            )
            // `as? Bool` rather than a truthiness read: relay requires the
            // exact spelling and a JSON boolean, and `NSNumber` bridging would
            // let a 0/1 through unnoticed here while failing there.
            let readOnly = try XCTUnwrap(annotations["readOnlyHint"] as? Bool, "\(name) readOnlyHint")
            let openWorld = try XCTUnwrap(annotations["openWorldHint"] as? Bool, "\(name) openWorldHint")

            let want = try XCTUnwrap(ToolAnnotationTests.expected[name], "\(name) is not classified")
            XCTAssertEqual(readOnly, want.readOnly, "\(name) readOnlyHint on the wire")
            XCTAssertEqual(openWorld, want.openWorld, "\(name) openWorldHint on the wire")

            XCTAssertEqual(
                Set(annotations.keys), ["readOnlyHint", "openWorldHint"],
                "\(name) publishes an annotation nothing consumes"
            )
        }
    }

    /// The feature, end to end on the wire: two tools that differ here and
    /// nowhere else in `annotations`.
    func testTheSendAndDraftSplitSurvivesToTheWire() throws {
        let byName = Dictionary(uniqueKeysWithValues: try listedTools().compactMap { tool -> (String, [String: Any])? in
            guard let name = tool["name"] as? String else { return nil }
            return (name, tool)
        })
        let send = try XCTUnwrap(byName["mail_send"]?["annotations"] as? [String: Any])
        let draft = try XCTUnwrap(byName["mail_create_draft"]?["annotations"] as? [String: Any])
        XCTAssertEqual(send["openWorldHint"] as? Bool, true)
        XCTAssertEqual(draft["openWorldHint"] as? Bool, false)
        XCTAssertEqual(send["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(draft["readOnlyHint"] as? Bool, false)
    }
}
