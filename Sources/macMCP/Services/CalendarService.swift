import EventKit
import Foundation

enum CalendarService {
    private static let store = EKEventStore()

    /// Read-only check for whether Calendar access is granted. macmcp
    /// inherits Relay's grant via TCC's responsible-parent attribution at
    /// runtime, so calling requestFullAccessToEvents from macmcp itself is
    /// pointless: tccd silently denies the request for any bundle lacking
    /// com.apple.security.personal-information.calendars, and macmcp doesn't
    /// carry that entitlement (Relay does). Use Relay > Settings > MCP >
    /// Reset Permissions to grant via Relay's process.
    private static func hasAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    private static let accessDeniedMsg = "calendar access denied — grant via Relay > Settings > MCP Servers > macMCP > Reset Permissions"

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    /// Accepts ISO 8601 with offset, zone-less local datetime, or a bare date.
    /// Bare dates resolve to local midnight; endOfDay resolves them to 23:59:59.
    private static func parseDate(_ string: String, endOfDay: Bool = false) -> Date? {
        if let d = iso8601Formatter.date(from: string) { return d }
        if let d = plainISO8601Formatter.date(from: string) { return d }
        if string.count == 19, let d = localDateTimeFormatter.date(from: string) { return d }
        if string.count == 10, let d = dateOnlyFormatter.date(from: string) {
            return endOfDay
                ? Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: d)
                : d
        }
        return nil
    }

    private static func dateFormatError(_ field: String, _ value: String) -> MCPCallResult {
        errorResult("invalid \(field) \"\(value)\": expected ISO 8601 such as 2026-06-12, 2026-06-12T09:00:00, or 2026-06-12T09:00:00-07:00")
    }

    private static func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        case .exchange: return "exchange"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Tool Handlers

    private static func listCalendars(_ ctx: MCPCallContext) -> MCPCallResult {
        guard hasAccess() else {
            return errorResult(accessDeniedMsg)
        }

        let calendars = store.calendars(for: .event)
        let results: [[String: Any]] = calendars.map { cal in
            [
                "title": cal.title,
                "type": calendarTypeName(cal.type),
                "source": cal.source?.title ?? unknownSourceName
            ]
        }
        return jsonResult(results)
    }

    private static func listEvents(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else {
            return errorResult(accessDeniedMsg)
        }

        guard let startStr = args?["start_date"]?.stringValue,
              let endStr = args?["end_date"]?.stringValue else {
            return errorResult("start_date and end_date are required (ISO 8601)")
        }

        guard let startDate = parseDate(startStr) else {
            return dateFormatError("start_date", startStr)
        }
        guard let endDate = parseDate(endStr, endOfDay: true) else {
            return dateFormatError("end_date", endStr)
        }

        var calendars: [EKCalendar]? = nil
        if let name = args?["calendar_name"]?.stringValue {
            let matched = store.calendars(for: .event).filter { $0.title == name }
            if matched.isEmpty {
                return errorResult("calendar not found: \(name)")
            }
            calendars = matched
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)

        let results: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "title": event.title ?? "",
                "start_date": displayFormatter.string(from: event.startDate),
                "end_date": displayFormatter.string(from: event.endDate),
                "calendar": event.calendar?.title ?? ""
            ]
            if let location = event.location, !location.isEmpty {
                dict["location"] = location
            }
            if let notes = event.notes, !notes.isEmpty {
                dict["notes"] = notes
            }
            return dict
        }
        return jsonResult(results)
    }

    private static func createEvent(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else {
            return errorResult(accessDeniedMsg)
        }

        guard let title = args?["title"]?.stringValue,
              let startStr = args?["start_date"]?.stringValue,
              let endStr = args?["end_date"]?.stringValue else {
            return errorResult("title, start_date, and end_date are required")
        }

        guard let startDate = parseDate(startStr) else {
            return dateFormatError("start_date", startStr)
        }
        guard let endDate = parseDate(endStr, endOfDay: true) else {
            return dateFormatError("end_date", endStr)
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate

        if let calendarName = args?["calendar_name"]?.stringValue {
            if let cal = store.calendars(for: .event).first(where: { $0.title == calendarName }) {
                event.calendar = cal
            } else {
                return errorResult("calendar not found: \(calendarName)")
            }
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let location = args?["location"]?.stringValue {
            event.location = location
        }
        if let notes = args?["notes"]?.stringValue {
            event.notes = notes
        }

        do {
            try store.save(event, span: .thisEvent)
            return textResult("event created: \(title) (\(displayFormatter.string(from: startDate)) to \(displayFormatter.string(from: endDate)))")
        } catch {
            return errorResult("failed to create event: \(error.localizedDescription)")
        }
    }

    // MARK: - context/enumerate (ADR-011 decision 6)

    /// Every event calendar, as a container/leaf row.
    ///
    /// Read through `store.calendars(for: .event)` -- the one call
    /// `calendars_list` and `calendars_list_events` already make -- so the
    /// picker can never offer a calendar the tools cannot see, or miss one
    /// they can. Deriving the *accounts* from the same rows rather than from
    /// `store.sources` is the same rule one level up: a source holding no
    /// event calendar is not a calendar account this client could reach
    /// anything through, and offering it would be a permission that grants
    /// nothing while reading as though it grants something.
    ///
    /// The access check is what makes a failure a failure. `-32000` and an
    /// empty list must not look the same (`relay/docs/context-schema.md`: "a
    /// failure and 'there are none' must not look the same, or a profile gets
    /// saved against a host the operator was shown nothing about"), so a Mac
    /// whose Calendar grant is missing answers with the sentence, never with
    /// `[]`.
    static func calendarRows() -> (rows: [ScopePath.Row], error: String?) {
        guard hasAccess() else { return ([], accessDeniedMsg) }
        let rows = store.calendars(for: .event).map {
            ScopePath.Row(container: $0.source?.title ?? unknownSourceName, leaf: $0.title)
        }
        return (rows, nil)
    }

    /// What `calendars_list` reports for a calendar whose source EventKit will
    /// not name -- the same string, so the two surfaces agree.
    static let unknownSourceName = "unknown"

    static func enumerateAccounts() -> ScopeEnumeration {
        let (rows, error) = calendarRows()
        if let error { return ([], error) }
        return (ScopePath.containerEntries(fromRows: rows), nil)
    }

    static func enumerateCalendars(accountFilter: [String]?) -> ScopeEnumeration {
        let (rows, error) = calendarRows()
        if let error { return ([], error) }
        return (ScopePath.entries(fromRows: rows, containerFilter: accountFilter), nil)
    }

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Calendar"

        registry.register(
            MCPTool(
                name: "calendars_list",
                description: "List all calendars available on this Mac",
                inputSchema: emptySchema(),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listCalendars
        )

        registry.register(
            MCPTool(
                name: "calendars_list_events",
                description: "List calendar events within a date range",
                inputSchema: schema(
                    properties: [
                        "start_date": stringProp("Start date — ISO 8601: '2026-06-12' (local midnight), '2026-06-12T09:00:00' (local time), or '2026-06-12T09:00:00-07:00'"),
                        "end_date": stringProp("End date — same formats as start_date; a bare date like '2026-06-12' means end of that day (23:59:59 local)"),
                        "calendar_name": stringProp("Filter to a specific calendar by name")
                    ],
                    required: ["start_date", "end_date"]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat,
            handler: listEvents
        )

        registry.register(
            MCPTool(
                name: "calendars_create_event",
                description: "Create a new calendar event",
                inputSchema: schema(
                    properties: [
                        "title": stringProp("Event title"),
                        "start_date": stringProp("Start date — ISO 8601: '2026-06-12' (local midnight), '2026-06-12T09:00:00' (local time), or '2026-06-12T09:00:00-07:00'"),
                        "end_date": stringProp("End date — same formats as start_date; a bare date like '2026-06-12' means end of that day (23:59:59 local)"),
                        "calendar_name": stringProp("Calendar to add the event to (uses default if not specified)"),
                        "location": stringProp("Event location"),
                        "notes": stringProp("Event notes")
                    ],
                    required: ["title", "start_date", "end_date"]
                ),
                annotations: MCPAnnotations(readOnlyHint: false)
            ),
            category: cat,
            handler: createEvent
        )
    }
}
