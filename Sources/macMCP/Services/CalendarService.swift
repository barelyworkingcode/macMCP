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
        // The presence check runs before the TCC check on purpose: it is a
        // question about this call's authority, which does not depend on
        // whether this Mac would have answered. Ordering it second would make
        // the refusal a client sees vary with a grant it has nothing to do
        // with, and would put the one check that is macMCP's own behind a
        // framework read no hermetic test can make.
        let scope = ResourceScope.parse(ctx.meta)
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return scopeViolationResult(refusal)
        }
        guard hasAccess() else {
            return errorResult(accessDeniedMsg)
        }

        let calendars = store.calendars(for: .event)
        let rows = rows(of: calendars)
        let admitted: [Int]
        switch confinement(scope, rows: rows) {
        case .unscoped: admitted = Array(calendars.indices)
        case .confined(let indices): admitted = indices
        case .refused(let message): return scopeViolationResult(message)
        case .misconfigured(let message): return errorResult(message)
        }

        // An enumerator is scoped too (ADR-011, "The reconciliation rule the
        // MCP implements"). Listing every calendar on the machine to a confined
        // client is a disclosure in itself, and it is also how that client
        // learns what to try next.
        let results: [[String: Any]] = admitted.map { index in
            let cal = calendars[index]
            return [
                "title": cal.title,
                // The handle. `title` is not one -- two sources can each hold a
                // "Work" -- so the value a caller passes back as
                // `calendar_name` has to be the path, and it has to be in the
                // one listing that hands it out.
                "path": rows[index].path,
                "type": calendarTypeName(cal.type),
                "source": rows[index].container
            ]
        }
        return jsonResult(results)
    }

    private static func listEvents(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        // Authority before availability; see `listCalendars`.
        let scope = ResourceScope.parse(ctx.meta)
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return scopeViolationResult(refusal)
        }
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

        let all = store.calendars(for: .event)
        let rows = rows(of: all)
        let admitted: [Int]?
        switch confinement(scope, rows: rows) {
        case .unscoped: admitted = nil
        case .confined(let indices): admitted = indices
        case .refused(let message): return scopeViolationResult(message)
        case .misconfigured(let message): return errorResult(message)
        }

        // `nil` means "every calendar on this Mac", which is what
        // `predicateForEvents` reads it as -- correct only when nothing is in
        // play. An omitted `calendar_name` under a scope resolves **to the
        // scope**, not to everything: a tool's own default is not a choice the
        // caller made.
        var calendars: [EKCalendar]? = admitted.map { $0.map { all[$0] } }
        if let name = args?["calendar_name"]?.stringValue {
            switch ScopedRows.resolve(name, rows: rows, allowed: admitted, fields: scopeFields) {
            case .rows(let indices): calendars = indices.map { all[$0] }
            case .outOfScope(let message): return scopeViolationResult(message)
            case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                return errorResult(message)
            }
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)

        let results: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "title": event.title ?? "",
                "start_date": displayFormatter.string(from: event.startDate),
                "end_date": displayFormatter.string(from: event.endDate),
                "calendar": event.calendar?.title ?? "",
                // The title is kept because it always has been; the path is
                // added because it is the only one of the two a caller can pass
                // back as `calendar_name` and be sure which calendar it names.
                "calendar_path": event.calendar.map { row(of: $0).path } ?? ""
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
        // Authority before availability; see `listCalendars`.
        let scope = ResourceScope.parse(ctx.meta)
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return scopeViolationResult(refusal)
        }
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

        let all = store.calendars(for: .event)
        let rows = rows(of: all)
        let admitted: [Int]?
        switch confinement(scope, rows: rows) {
        case .unscoped: admitted = nil
        case .confined(let indices): admitted = indices
        case .refused(let message): return scopeViolationResult(message)
        case .misconfigured(let message): return errorResult(message)
        }

        if let calendarName = args?["calendar_name"]?.stringValue {
            switch ScopedRows.resolve(calendarName, rows: rows, allowed: admitted, fields: scopeFields) {
            case .rows(let indices): event.calendar = all[indices[0]]
            case .outOfScope(let message): return scopeViolationResult(message)
            case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                return errorResult(message)
            }
        } else if let admitted {
            // EventKit answers `defaultCalendarForNewEvents` whatever the scope
            // says, and writing there is how a confined client silently files an
            // event on a calendar its profile never granted. The same shape as
            // mail refusing a `from` no account owns rather than letting Mail
            // substitute the default account: resolve to the scope, or refuse.
            let defaultIndex = store.defaultCalendarForNewEvents
                .flatMap { def in all.firstIndex { $0.calendarIdentifier == def.calendarIdentifier } }
            switch ScopedRows.defaultTarget(
                defaultIndex: defaultIndex, allowed: admitted, rows: rows, fields: scopeFields
            ) {
            case .rows(let indices): event.calendar = all[indices[0]]
            case .outOfScope(let message): return scopeViolationResult(message)
            case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                return errorResult(message)
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
        return (rows(of: store.calendars(for: .event)), nil)
    }

    // MARK: - Enforcement (ADR-011, "The reconciliation rule the MCP implements")

    /// The words every calendar refusal is written in.
    static let scopeFields = ScopedRows.Fields(
        containerField: "calendar_accounts",
        containerNoun: "calendar account",
        leafField: "calendars",
        leafNoun: "calendar",
        argument: "calendar_name",
        listTool: "calendars_list"
    )

    /// One calendar as the (container, leaf) pair a scope value is written in.
    ///
    /// The **one** place a calendar becomes a path, so the enumeration an
    /// operator picks a value out of, the listing a client reads and the
    /// comparison the enforcement makes cannot disagree about what a calendar
    /// is called. `EKCalendar.title` is not an identity: two sources can each
    /// hold a "Work", which is why `$0.title == name` returned both.
    static func row(of calendar: EKCalendar) -> ScopePath.Row {
        ScopePath.Row(container: calendar.source?.title ?? unknownSourceName, leaf: calendar.title)
    }

    /// Rows positionally aligned with the calendars they came from, so an index
    /// the enforcement returns names the very object the handler acts on.
    static func rows(of calendars: [EKCalendar]) -> [ScopePath.Row] { calendars.map(row(of:)) }

    private static func confinement(_ scope: ResourceScope, rows: [ScopePath.Row]) -> ScopedRows.RowScope {
        ScopedRows.allowed(
            rows: rows,
            containers: scope.access("calendar_accounts"),
            leaves: scope.access("calendars"),
            fields: scopeFields
        )
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
                        "calendar_name": stringProp("Filter to one calendar, named as Account/Calendar exactly as calendars_list reports its `path` — for example 'iCloud/Work'. A bare calendar name works only when a single calendar carries it; two carriers is refused with both named, because a title on its own does not identify a calendar. Omit to read every calendar this client may reach.")
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
                        "calendar_name": stringProp("Calendar to add the event to, named as Account/Calendar exactly as calendars_list reports its `path` — for example 'iCloud/Work'. A bare calendar name works only when a single calendar carries it. Omitted, the event goes to this Mac's default calendar; a client whose access profile is scoped gets that default only when it is inside the scope, and is otherwise asked to name one rather than having the event filed somewhere it was never granted."),
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
