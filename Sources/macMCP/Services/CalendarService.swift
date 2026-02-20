import EventKit
import Foundation

enum CalendarService {
    private static let store = EKEventStore()

    private static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in
                granted = ok
                semaphore.signal()
            }
        } else {
            store.requestAccess(to: .event) { ok, _ in
                granted = ok
                semaphore.signal()
            }
        }

        semaphore.wait()
        return granted
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static func parseDate(_ string: String) -> Date? {
        if let d = iso8601Formatter.date(from: string) { return d }
        // Retry without fractional seconds
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
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

    private static func listCalendars(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else {
            return errorResult("calendar access denied")
        }

        let calendars = store.calendars(for: .event)
        let results: [[String: Any]] = calendars.map { cal in
            [
                "title": cal.title,
                "type": calendarTypeName(cal.type),
                "source": cal.source?.title ?? "unknown"
            ]
        }
        return jsonResult(results)
    }

    private static func listEvents(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else {
            return errorResult("calendar access denied")
        }

        guard let startStr = args?["start_date"]?.stringValue,
              let endStr = args?["end_date"]?.stringValue else {
            return errorResult("start_date and end_date are required (ISO 8601)")
        }

        guard let startDate = parseDate(startStr) else {
            return errorResult("invalid start_date format, expected ISO 8601")
        }
        guard let endDate = parseDate(endStr) else {
            return errorResult("invalid end_date format, expected ISO 8601")
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

    private static func createEvent(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else {
            return errorResult("calendar access denied")
        }

        guard let title = args?["title"]?.stringValue,
              let startStr = args?["start_date"]?.stringValue,
              let endStr = args?["end_date"]?.stringValue else {
            return errorResult("title, start_date, and end_date are required")
        }

        guard let startDate = parseDate(startStr) else {
            return errorResult("invalid start_date format, expected ISO 8601")
        }
        guard let endDate = parseDate(endStr) else {
            return errorResult("invalid end_date format, expected ISO 8601")
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
                        "start_date": stringProp("Start date in ISO 8601 format"),
                        "end_date": stringProp("End date in ISO 8601 format"),
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
                        "start_date": stringProp("Start date in ISO 8601 format"),
                        "end_date": stringProp("End date in ISO 8601 format"),
                        "calendar_name": stringProp("Calendar to add the event to (uses default if not specified)"),
                        "location": stringProp("Event location"),
                        "notes": stringProp("Event notes")
                    ],
                    required: ["title", "start_date", "end_date"]
                )
            ),
            category: cat,
            handler: createEvent
        )
    }
}
