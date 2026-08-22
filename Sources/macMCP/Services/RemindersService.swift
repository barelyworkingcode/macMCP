import EventKit
import Foundation

enum RemindersService {
    private static let store = EKEventStore()

    /// Read-only check; see CalendarService.hasAccess for full rationale.
    /// Returns nil if authorized, otherwise an error string for the tool result.
    private static func ensureAccess() -> String? {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let ok: Bool
        if #available(macOS 14.0, *) {
            ok = (status == .fullAccess)
        } else {
            ok = (status == .authorized)
        }
        if !ok {
            return "reminders access denied — grant via Relay > Settings > MCP Servers > macMCP > Reset Permissions"
        }
        return nil
    }

    private static func fetchReminders(in calendars: [EKCalendar]?) -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        var results: [EKReminder] = []
        var done = false
        store.fetchReminders(matching: predicate) { reminders in
            results = reminders ?? []
            done = true
        }
        let deadline = Date(timeIntervalSinceNow: 15)
        while !done && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.25, true)
        }
        return results
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func register(_ registry: ToolRegistry) {
        let cat = "Reminders"

        // MARK: - reminders_list

        registry.register(
            MCPTool(
                name: "reminders_list",
                description: "List reminders. Returns title, completed status, priority, list name, and optional due_date/notes.",
                inputSchema: schema(
                    properties: [
                        "list_name": stringProp("Reminder list name to filter by (case-insensitive). Omit to list all reminders.")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true)
            ),
            category: cat
        ) { args in
            if let err = ensureAccess() { return errorResult(err) }

            let listName = args?["list_name"]?.stringValue
            var calendars: [EKCalendar]? = nil
            if let listName {
                let match = store.calendars(for: .reminder).filter { $0.title.lowercased() == listName.lowercased() }
                if match.isEmpty { return errorResult("no reminder list found named '\(listName)'") }
                calendars = match
            }

            let reminders = fetchReminders(in: calendars)
            if reminders.isEmpty { return textResult("no reminders found") }

            let items: [[String: Any]] = reminders.map { r in
                var item: [String: Any] = [
                    "title": r.title ?? "",
                    "completed": r.isCompleted,
                    "priority": r.priority,
                    "list": r.calendar?.title ?? ""
                ]
                if let notes = r.notes, !notes.isEmpty {
                    item["notes"] = notes
                }
                if let due = r.dueDateComponents, let date = Calendar.current.date(from: due) {
                    item["due_date"] = iso8601.string(from: date)
                }
                return item
            }
            return jsonResult(items)
        }

        // MARK: - reminders_create

        registry.register(
            MCPTool(
                name: "reminders_create",
                description: "Create a new reminder.",
                inputSchema: schema(
                    properties: [
                        "title": stringProp("Reminder title"),
                        "list_name": stringProp("Reminder list name (case-insensitive). Uses default list if omitted."),
                        "due_date": stringProp("Due date in ISO 8601 format (e.g. 2026-03-15T09:00:00Z)"),
                        "notes": stringProp("Notes for the reminder"),
                        "priority": intProp("Priority: 0 = none, 1-4 = high, 5 = medium, 6-9 = low")
                    ],
                    required: ["title"]
                )
            ),
            category: cat
        ) { args in
            if let err = ensureAccess() { return errorResult(err) }

            guard let title = args?["title"]?.stringValue, !title.isEmpty else {
                return errorResult("title is required")
            }

            let reminder = EKReminder(eventStore: store)
            reminder.title = title

            if let listName = args?["list_name"]?.stringValue {
                let match = store.calendars(for: .reminder).first { $0.title.lowercased() == listName.lowercased() }
                if let match {
                    reminder.calendar = match
                } else {
                    return errorResult("no reminder list found named '\(listName)'")
                }
            } else {
                reminder.calendar = store.defaultCalendarForNewReminders()
            }

            if let dueDateStr = args?["due_date"]?.stringValue {
                guard let date = iso8601.date(from: dueDateStr) else {
                    return errorResult("invalid ISO 8601 date: \(dueDateStr)")
                }
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: date
                )
            }

            if let notes = args?["notes"]?.stringValue {
                reminder.notes = notes
            }

            if let priority = args?["priority"]?.intValue {
                reminder.priority = max(0, min(9, priority))
            }

            do {
                try store.save(reminder, commit: true)
                return textResult("created reminder: \(title)")
            } catch {
                return errorResult("failed to create reminder: \(error.localizedDescription)")
            }
        }

        // MARK: - reminders_complete

        registry.register(
            MCPTool(
                name: "reminders_complete",
                description: "Mark a reminder as complete. Matches by title (case-insensitive), and only an incomplete one.",
                inputSchema: schema(
                    properties: [
                        "title": stringProp("Title of the reminder to complete")
                    ],
                    required: ["title"]
                )
            ),
            category: cat
        ) { args in
            if let err = ensureAccess() { return errorResult(err) }

            guard let title = args?["title"]?.stringValue, !title.isEmpty else {
                return errorResult("title is required")
            }

            let reminders = fetchReminders(in: nil)
            guard let match = reminders.first(where: { ($0.title ?? "").lowercased() == title.lowercased() && !$0.isCompleted }) else {
                return errorResult("no incomplete reminder found with title '\(title)'")
            }

            match.isCompleted = true
            do {
                try store.save(match, commit: true)
                return textResult("completed reminder: \(match.title ?? title)")
            } catch {
                return errorResult("failed to complete reminder: \(error.localizedDescription)")
            }
        }
    }
}
