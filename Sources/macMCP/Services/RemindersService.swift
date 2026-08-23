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

    // MARK: - context/enumerate (ADR-011 decision 6)

    /// Every reminder list, as a container/leaf row.
    ///
    /// `store.calendars(for: .reminder)` is exactly what `reminders_list` and
    /// `reminders_create` already resolve `list_name` against, so the picker
    /// offers what those tools can see and nothing else. The account is the
    /// EKSource title, the same axis a calendar uses -- Reminders and Calendar
    /// share EventKit's source model, which is why the two field pairs are
    /// shaped identically rather than merely looking alike.
    ///
    /// A missing grant is the sentence, never an empty list: `-32000` and
    /// "there are none" must stay distinguishable.
    static func listRows() -> (rows: [ScopePath.Row], error: String?) {
        if let err = ensureAccess() { return ([], err) }
        return (rows(of: store.calendars(for: .reminder)), nil)
    }

    // MARK: - Enforcement (ADR-011, "The reconciliation rule the MCP implements")

    /// The words every reminder-list refusal is written in.
    static let scopeFields = ScopedRows.Fields(
        containerField: "reminder_accounts",
        containerNoun: "reminder account",
        leafField: "reminder_lists",
        leafNoun: "reminder list",
        argument: "list_name",
        listTool: "reminders_list"
    )

    /// One reminder list as the (container, leaf) pair a scope value is written
    /// in -- the one place a list becomes a path, so the picker, the listing and
    /// the enforcement cannot disagree about what a list is called. A leaf name
    /// is not an identity here either: every account may hold a `Reminders`.
    static func row(of calendar: EKCalendar) -> ScopePath.Row {
        ScopePath.Row(
            // Shared with `CalendarService` rather than spelled again: an
            // empty `EKSource.title` has to fall back the same way on both
            // axes, or one service's picker offers `"/Work"` while the other
            // offers `"unknown/Work"` for the same unnamed account.
            container: CalendarService.sourceName(calendar.source?.title),
            leaf: calendar.title
        )
    }

    /// Rows positionally aligned with the lists they came from, so an index the
    /// enforcement returns names the very object the handler acts on.
    static func rows(of calendars: [EKCalendar]) -> [ScopePath.Row] { calendars.map(row(of:)) }

    /// Whether a reminder's own title is the one `reminders_complete` was
    /// asked for.
    ///
    /// **`fold`, not `lowercased()`, and the reason is not the one it looks
    /// like.** `fold` is NFC -> lowercase -> NFC, and it exists because
    /// JavaScript's `===` compares UTF-16 code units, so an NFD mailbox name
    /// and an NFC scope value are two strings in every generated script. In
    /// *Swift* they are not: `String ==` compares by canonical equivalence, so
    /// `.lowercased()` already answered every NFC/NFD pair identically.
    /// Measured rather than assumed -- every scalar in U+0000...U+2FFFF
    /// against its own decomposition, **zero** verdicts differ between the two
    /// spellings. So this changes no behaviour today and is not a hole that
    /// was open.
    ///
    /// What it is is the last comparison on a scoped path still carrying its
    /// own case rule. The handler picks a reminder with this and then decides
    /// that reminder's list membership with `ScopedRows.admits`, which folds;
    /// two spellings of one rule in one handler is how they come apart, and
    /// the way they would come apart here is by this comparison being moved
    /// somewhere `==` is not canonical -- a generated script, a `Set` of raw
    /// keys, a byte compare. One spelling, at the one seam.
    static func titleMatches(_ candidate: String?, _ requested: String) -> Bool {
        ResourceScope.fold(candidate ?? "") == ResourceScope.fold(requested)
    }

    private static func confinement(_ scope: ResourceScope, rows: [ScopePath.Row]) -> ScopedRows.RowScope {
        ScopedRows.allowed(
            rows: rows,
            containers: scope.access("reminder_accounts"),
            leaves: scope.access("reminder_lists"),
            fields: scopeFields
        )
    }

    static func enumerateAccounts() -> ScopeEnumeration {
        let (rows, error) = listRows()
        if let error { return ([], error) }
        return (ScopePath.containerEntries(fromRows: rows), nil)
    }

    static func enumerateLists(accountFilter: [String]?) -> ScopeEnumeration {
        let (rows, error) = listRows()
        if let error { return ([], error) }
        return (ScopePath.entries(fromRows: rows, containerFilter: accountFilter), nil)
    }

    /// Nothing here is open world: EventKit's local reminder store, read and
    /// written. Account replication is not counted -- see
    /// `MailService.register`.
    static func register(_ registry: ToolRegistry) {
        let cat = "Reminders"

        // MARK: - reminders_list

        registry.register(
            MCPTool(
                name: "reminders_list",
                description: "List reminders. Returns title, completed status, priority, list name, and optional due_date/notes.",
                inputSchema: schema(
                    properties: [
                        "list_name": stringProp("Reminder list to filter by, named as Account/List exactly as reminders_list reports its `list_path` — for example 'iCloud/Groceries'. A bare list name works only when a single list carries it; two carriers is refused with both named. Omit to list every reminder this client may reach.")
                    ]
                ),
                annotations: MCPAnnotations(readOnlyHint: true, openWorldHint: false)
            ),
            category: cat
        ) { ctx in
            let args = ctx.arguments
            // Authority before availability: the presence check is a question
            // about this call's authority, which does not depend on whether
            // this Mac would have answered. Ordering it after the TCC check
            // would make the refusal a client sees vary with a grant it has
            // nothing to do with, and would put the one check that is macMCP's
            // own behind a framework read no hermetic test can make.
            let scope = ResourceScope.parse(ctx.meta)
            if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
                return scopeViolationResult(refusal)
            }
            if let err = ensureAccess() { return errorResult(err) }

            let all = store.calendars(for: .reminder)
            let rows = rows(of: all)
            let admitted: [Int]?
            switch confinement(scope, rows: rows) {
            case .unscoped: admitted = nil
            case .confined(let indices): admitted = indices
            case .refused(let message): return scopeViolationResult(message)
            case .misconfigured(let message): return errorResult(message)
            }

            // `nil` is "every list on this Mac", which `predicateForReminders`
            // reads it as -- right only when nothing is in play. An omitted
            // `list_name` under a scope resolves to the scope, because a tool's
            // own default is not a choice the caller made.
            var calendars: [EKCalendar]? = admitted.map { $0.map { all[$0] } }
            if let listName = args?["list_name"]?.stringValue {
                switch ScopedRows.resolve(listName, rows: rows, allowed: admitted, fields: scopeFields) {
                case .rows(let indices): calendars = indices.map { all[$0] }
                case .outOfScope(let message): return scopeViolationResult(message)
                case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                    return errorResult(message)
                }
            }

            let reminders = fetchReminders(in: calendars)
            if reminders.isEmpty { return textResult("no reminders found") }

            let items: [[String: Any]] = reminders.map { r in
                var item: [String: Any] = [
                    "title": r.title ?? "",
                    "completed": r.isCompleted,
                    "priority": r.priority,
                    "list": r.calendar?.title ?? "",
                    // The title is kept because it always has been; the path is
                    // added because it is the only one of the two a caller can
                    // pass back as `list_name` and be sure which list it names.
                    "list_path": r.calendar.map { row(of: $0).path } ?? ""
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
                        "list_name": stringProp("Reminder list to create in, named as Account/List exactly as reminders_list reports its `list_path` — for example 'iCloud/Groceries'. A bare list name works only when a single list carries it. Omitted, the reminder goes to this Mac's default list; a client whose access profile is scoped gets that default only when it is inside the scope, and is otherwise asked to name one rather than having the reminder filed somewhere it was never granted."),
                        "due_date": stringProp("Due date in ISO 8601 format (e.g. 2026-03-15T09:00:00Z)"),
                        "notes": stringProp("Notes for the reminder"),
                        "priority": intProp("Priority: 0 = none, 1-4 = high, 5 = medium, 6-9 = low")
                    ],
                    required: ["title"]
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
            ),
            category: cat
        ) { ctx in
            let args = ctx.arguments
            // Authority before availability: the presence check is a question
            // about this call's authority, which does not depend on whether
            // this Mac would have answered. Ordering it after the TCC check
            // would make the refusal a client sees vary with a grant it has
            // nothing to do with, and would put the one check that is macMCP's
            // own behind a framework read no hermetic test can make.
            let scope = ResourceScope.parse(ctx.meta)
            if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
                return scopeViolationResult(refusal)
            }
            if let err = ensureAccess() { return errorResult(err) }

            guard let title = args?["title"]?.stringValue, !title.isEmpty else {
                return errorResult("title is required")
            }

            let reminder = EKReminder(eventStore: store)
            reminder.title = title

            let all = store.calendars(for: .reminder)
            let rows = rows(of: all)
            let admitted: [Int]?
            switch confinement(scope, rows: rows) {
            case .unscoped: admitted = nil
            case .confined(let indices): admitted = indices
            case .refused(let message): return scopeViolationResult(message)
            case .misconfigured(let message): return errorResult(message)
            }

            if let listName = args?["list_name"]?.stringValue {
                switch ScopedRows.resolve(listName, rows: rows, allowed: admitted, fields: scopeFields) {
                case .rows(let indices): reminder.calendar = all[indices[0]]
                case .outOfScope(let message): return scopeViolationResult(message)
                case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                    return errorResult(message)
                }
            } else if let admitted {
                // EventKit answers `defaultCalendarForNewReminders()` whatever
                // the scope says. Writing there is how a confined client
                // silently files a reminder in a list its profile never
                // granted, so a scoped write resolves to the scope or refuses.
                let defaultIndex = store.defaultCalendarForNewReminders()
                    .flatMap { def in all.firstIndex { $0.calendarIdentifier == def.calendarIdentifier } }
                switch ScopedRows.defaultTarget(
                    defaultIndex: defaultIndex, allowed: admitted, rows: rows, fields: scopeFields
                ) {
                case .rows(let indices): reminder.calendar = all[indices[0]]
                case .outOfScope(let message): return scopeViolationResult(message)
                case .notFound(let message), .ambiguous(let message), .needsChoice(let message):
                    return errorResult(message)
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
                ),
                annotations: MCPAnnotations(readOnlyHint: false, openWorldHint: false)
            ),
            category: cat
        ) { ctx in
            let args = ctx.arguments
            // Authority before availability: the presence check is a question
            // about this call's authority, which does not depend on whether
            // this Mac would have answered. Ordering it after the TCC check
            // would make the refusal a client sees vary with a grant it has
            // nothing to do with, and would put the one check that is macMCP's
            // own behind a framework read no hermetic test can make.
            let scope = ResourceScope.parse(ctx.meta)
            if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
                return scopeViolationResult(refusal)
            }
            if let err = ensureAccess() { return errorResult(err) }

            guard let title = args?["title"]?.stringValue, !title.isEmpty else {
                return errorResult("title is required")
            }

            let all = store.calendars(for: .reminder)
            let rows = rows(of: all)
            let admitted: [Int]?
            switch confinement(scope, rows: rows) {
            case .unscoped: admitted = nil
            case .confined(let indices): admitted = indices
            case .refused(let message): return scopeViolationResult(message)
            case .misconfigured(let message): return errorResult(message)
            }

            // The scoped read comes first, so the common path never fetches a
            // reminder this client may not see. Only a miss re-reads every list,
            // and only to tell ADR-011 decision 11's two answers apart: a title
            // that is on a real out-of-scope reminder is a refusal, a title on
            // nothing at all is a plain miss. Saying "not found" for both is
            // indistinguishable from a real miss and leaves nothing to debug.
            func incomplete(in calendars: [EKCalendar]?) -> EKReminder? {
                fetchReminders(in: calendars).first {
                    titleMatches($0.title, title) && !$0.isCompleted
                }
            }
            let match = incomplete(in: admitted.map { $0.map { all[$0] } })
            if match == nil, let admitted {
                if incomplete(in: nil) != nil {
                    return scopeViolationResult(
                        "a reminder titled '\(title)' exists on this Mac, but not in a reminder list "
                        + "this client may reach. It may reach: "
                        + admitted.map { rows[$0].path }.joined(separator: ", ") + ". "
                        + "The list actually holding it is deliberately not named here."
                    )
                }
            }
            guard let match else {
                return errorResult("no incomplete reminder found with title '\(title)'")
            }

            // A reminder is found by title across the lists in scope, which does
            // not by itself say where it ended up -- the same shape as mail's
            // `messages.byId` resolving globally. So where it lives is read back
            // off the reminder and checked, rather than trusted from the query.
            if let admitted, let list = match.calendar {
                let where_ = row(of: list)
                guard ScopedRows.admits(
                    container: where_.container, leaf: where_.leaf, allowed: admitted, rows: rows
                ) else {
                    return scopeViolationResult(
                        "the reminder titled '\(title)' is in a reminder list this client may not "
                        + "reach. It may reach: "
                        + admitted.map { rows[$0].path }.joined(separator: ", ") + ". "
                        + "Nothing was changed."
                    )
                }
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
