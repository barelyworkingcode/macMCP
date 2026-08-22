import Foundation

/// The `contextSchema` macMCP declares in `initialize`'s `serverInfo`, per
/// ADR-011 ("A Client Is an Identity, an Access Profile, and a Resource
/// Scope") "What macMCP declares" worked example.
///
/// Relay reads five keywords here and learns no field names: `scope:
/// "restrict"` marks a field as narrowing access at all (an ordinary context
/// value relay injects and otherwise ignores has none of this and is
/// invisible to the mechanism); `source` says who supplies the value --
/// `"operator"` typed once by whoever configures an access profile,
/// `"project_path"` derived by relay from `Project.Path` and therefore
/// absent (and so refusing, by decision 4) for an access profile, which has
/// no path; `applies_to` selects which tools (by glob) the field governs;
/// `enumerable` says whether `context/enumerate` can list this field's real
/// values instead of an operator typing a resource name by hand;
/// `depends_on` orders that enumeration (mailboxes cannot be listed before
/// an account is chosen).
///
/// **Every field here is a `ScopeField`, and a `ScopeField` is always a
/// restriction.** macMCP has never had a reason to put an ordinary,
/// non-restricting context value on the wire, and inventing the shape in
/// advance would mean carrying a `scope` that could be absent through every
/// consumer below -- each of which would then need a fail-closed reading of
/// "this field does not restrict", which is precisely the reading that is
/// fail-open. A future non-restrict field is a new type, not a nullable
/// keyword.
///
/// ## Declaring without enforcing
///
/// ADR-011 decision 9 is explicit that declaring a scope an MCP does not
/// enforce is worse than declaring none: relay would advertise a confinement
/// that is not real. The mail fields honour that -- they were declared in the
/// same server version that enforces them.
///
/// **The six calendar / contacts / reminders fields below were declared ahead
/// of their enforcement, as a staging step, and that state must not reach a
/// running relay.** Relay's own call-time presence check refuses a `calendars_*`
/// call from a profile that sets no value, so the *presence* half goes live the
/// moment a field is declared; the *value* half -- which calendar -- does not,
/// and a profile scoped to `iCloud/Work` would have been shown as confined while
/// `calendars_list_events` still answered from every calendar on the Mac. That
/// is exactly decision 9's failure.
///
/// `calendar_accounts`, `calendars`, `reminder_accounts` and `reminder_lists`
/// are now enforced: `ScopedRows` (`Services/EventKitScope.swift`) applies the
/// reconciliation rule at every one of the six tools those four govern, and
/// `CalendarRemindersScopeWiringTests` is what says so tool by tool.
/// `contact_accounts` and `contact_groups` are enforced too, by
/// `ContactsService.gate`; the four calendar and reminder fields above are the
/// remainder, and this file is the honest place to say which half of the
/// declaration is real.
let macmcpContextSchema: JSONObject = {
    var schema: JSONObject = [:]
    for field in scopeFields { schema[field.name] = field.declaration }
    return schema
}()

/// Every `scope: "restrict"` field macMCP declares, in declaration order.
///
/// Grouped by the service that owns each. A service's whole obligation is the
/// entry (or entries) here plus, for an enumerable field, a function that lists
/// its values; everything else comes from `ResourceScope`.
let scopeFields: [ScopeField] = mailScopeFields + calendarScopeFields
    + contactsScopeFields + remindersScopeFields

/// The same list, ordered by name, for anything that has to be stable across
/// declaration edits -- `cacheFingerprint`'s slot order, above all, since a
/// fingerprint that reshuffled when a field was added would silently unify two
/// different confinements in an existing cache.
let restrictFields: [ScopeField] = scopeFields.sorted { $0.name < $1.name }

func contextField(named name: String) -> ScopeField? {
    scopeFields.first { $0.name == name }
}

// MARK: - Mail (ADR-011's worked example)

private let mailScopeFields: [ScopeField] = [
    ScopeField(
        name: "mail_accounts",
        noun: "mail account",
        description: "Mail accounts this client may read from or send as",
        appliesTo: ["mail_*"],
        enumerate: { _ in MailService.enumerateMailAccounts() }
    ),
    ScopeField(
        name: "mail_mailboxes",
        noun: "mailbox",
        description: "Mailbox paths within those accounts this client may reach",
        appliesTo: ["mail_*"],
        dependsOn: ["mail_accounts"],
        enumerate: { values in
            MailService.enumerateMailMailboxes(accountFilter: values?["mail_accounts"]?.stringsValue)
        }
    ),
    // ADR-011 calls this `write_dirs` and describes it as "Directories this
    // client may write files into". It is renamed, because that was only half
    // the axis and the missing half was the dangerous one.
    //
    // It governed `mail_save_attachment`'s `destination` and
    // `mail_get_source`'s `save_to` -- the two places macMCP writes a file --
    // while `mail_send` and `mail_create_draft` took `attachments: [absolute
    // POSIX paths]` and read whatever was named straight off the host into an
    // outbound message, scoped by nothing. That is ADR-011 finding 1 on the
    // read side and worse: finding 1 was an arbitrary host *write*; this is an
    // arbitrary host *read* wired directly to a channel that leaves the
    // machine. Reproduced through the live `hermes-alice` write profile --
    // `mail_send {"attachments": ["/tmp/zsec-secret.txt"]}` arrived base64'd
    // in Alice's Sent Maildir.
    //
    // One field rather than two (ADR-011 constraint 3, "tight, not defensive
    // sprawl"): what an operator is deciding is which directories on this host
    // a client may touch, and that answers both directions at once. Two lists
    // would be two chances to make constraint 1's mistake for one decision.
    // The name has to say so, because an operator reading "directories this
    // client may write files into" would not expect the same list to decide
    // what the client may read off this machine and mail away -- and a control
    // whose name understates it is constraint 2 defeating constraint 1.
    //
    // **The general rule `applies_to` is read by: name a tool here only if it
    // cannot function at all without this field. A tool that merely has a
    // *parameter* needing the field keeps working, and the parameter itself
    // is what refuses.**
    //
    // Relay reads `applies_to` as "deny this tool outright when the field has
    // no value" (`checkScopePresence`). That is the right answer for
    // `mail_save_attachment`: `destination` is required, so with no
    // `file_dirs` the tool cannot do anything at all, and relay denying it
    // outright is ADR-011 finding 1's intended outcome. It is the wrong
    // answer for `mail_send`, `mail_create_draft` and `mail_get_source`: each
    // has an optional parameter that needs a directory (`attachments`,
    // `attachments`, `save_to`), and none of the three stops working without
    // one -- a client with no `file_dirs` may still send without attaching,
    // still draft without attaching, still read a message's source inline.
    // Denying the whole tool to close one parameter would gut a write profile
    // for a field that only ever bore on a fraction of its calls.
    //
    // So those three tools stay out of `applies_to`, and the field governs
    // their parameter instead, at the one place each path actually opens a
    // file (`writeDestination` for `destination` and `save_to`,
    // `readableAttachment` for `attachments`) -- a reading only macMCP can
    // act on, since relay is domain-blind about arguments. Enforcing a
    // parameter relay does not know it is enforcing is the fail-CLOSED
    // direction of a mismatch between the two; ADR-011 decision 9 forbids
    // only the other one, where relay *advertises* a confinement that is not
    // real. The `attachments` and `save_to` schemas say this in the tool
    // descriptions, which is the surface a client actually reads.
    ScopeField(
        name: "file_dirs",
        noun: "directory",
        description: "Directories on this host this client may write files into and read attachments from",
        source: .projectPath,
        appliesTo: ["mail_save_attachment"]
    )
]

// MARK: - Calendar, Contacts, Reminders
//
// The three services ADR-011 deferred ("Calendars, contacts and iMessage.
// Same mechanism, no new decisions"), declared on the mechanism the mail work
// generalised. `messages_*` is still absent and still deliberately so: it has
// no resource axis short of per-chat, so a profile that needs it is confined
// by `allowed_tools` and the access mode alone.
//
// Each service is two fields -- the account and the thing inside it -- with
// the second `depends_on` the first, which is the `mail_accounts` /
// `mail_mailboxes` shape and combines the same way: a **cross-product**.
// Accounts `[iCloud, On My Mac]` with calendars `[iCloud/Work]` means the
// calendars in those accounts that are also in that list, which is one
// calendar. The account field is not redundant beside the leaf field: it is
// what governs the tools that take no leaf argument at all, and it is what an
// operator narrows the picker with.
//
// **Values are paths, not bare titles**, for the reason `ScopePath` states at
// length: `EKCalendar.title` is not unique, `CalendarService` matches with
// `$0.title == name` and therefore matches *both* when two sources hold a
// "Work", and a permission value that quietly selects two of something is the
// same class of bug the mailbox path work fixed. `Source/Title` for a
// calendar and a reminder list, `Account/Group` for a contact group.

private let calendarScopeFields: [ScopeField] = [
    ScopeField(
        name: "calendar_accounts",
        noun: "calendar account",
        description: "Calendar accounts this client may reach — the sources Calendar files calendars "
            + "under, such as iCloud, On My Mac, or an Exchange or CalDAV server. A client sees no "
            + "calendar outside these accounts.",
        appliesTo: ["calendars_*"],
        enumerate: { _ in CalendarService.enumerateAccounts() }
    ),
    ScopeField(
        name: "calendars",
        noun: "calendar",
        description: "Calendars this client may read and add events to, each written as "
            + "Account/Calendar — for example “iCloud/Work”. The account is part of the value "
            + "because a calendar title on its own does not identify one: two accounts can each "
            + "hold a calendar called Work, and a bare title would silently grant both. Choose "
            + "these from the list rather than typing them.",
        appliesTo: ["calendars_*"],
        dependsOn: ["calendar_accounts"],
        enumerate: { values in
            CalendarService.enumerateCalendars(accountFilter: values?["calendar_accounts"]?.stringsValue)
        }
    )
]

// **The contacts pair is enforced, as of the branch that added this note**, so
// the staging warning above no longer applies to these two: `contact_accounts`
// and `contact_groups` are read by `ContactsService.gate`, which every one of
// the ten `contacts_*` tools goes through. The four calendar and reminder
// fields are still declaration-only.
//
// **The two contacts fields do NOT share an `applies_to`, and that asymmetry
// with mail is the whole shape of this service.** Mail can require both of its
// axes on every tool because *a message is always in a mailbox*: scoping
// mailboxes scopes messages, and there is no message the pair cannot describe.
// *A card need not be in any group.* Declaring `contact_groups` with
// `applies_to: ["contacts_*"]` -- which is what the first pass did, by copying
// mail's shape -- therefore made group membership mandatory for every contacts
// tool, and the consequence was not a tightening but a **hole in what an
// operator can say**: "every card in this account, group or not" became
// inexpressible, so a profile could only ever be granted the cards somebody had
// remembered to file. The enforcement built on that declaration was correct
// about the declaration and wrong about contacts.
//
// So the axes are separated by what they actually bound:
//
// * `contact_accounts` bounds **cards**, and governs every `contacts_*` tool. A
//   card is reachable when its container is named here, group or no group.
// * `contact_groups` bounds **groups**, and governs only the four tools that
//   list, create or change membership of one. A group is reachable when its
//   path is named here *and* its container is named in `contact_accounts` --
//   still a cross-product, one level down.
//
// The four are named explicitly rather than matched by a glob. `contacts_*group*`
// would select exactly these four today, but it selects them by the *spelling*
// of a tool name, and a permission boundary that depends on a naming convention
// is one rename away from being wrong in the fail-open direction. The rule for
// adding a fifth is stated here instead, where someone adding a tool will read
// it: **a tool belongs in this list when it cannot function without naming a
// group.** `contacts_create`, which merely *may* take a `group` argument, does
// not -- it works without one, and the argument itself is what refuses when the
// grant is absent, exactly as `file_dirs` governs `mail_get_source`'s `save_to`
// without governing the tool.
//
// Note what this costs a profile holding accounts and no groups:
// `contacts_list_groups` refuses rather than answering `[]`. That is decision
// 4's rule and it is the right answer -- an empty list is an affirmative claim
// that this Mac holds no group, which is the `total_messages: 0` shape the mail
// work removed -- but it does mean an account-scoped client sees no groups at
// all, which is exactly what it was granted.
private let contactsScopeFields: [ScopeField] = [
    ScopeField(
        name: "contact_accounts",
        noun: "contact account",
        description: "Contact accounts this client may reach — the containers Contacts files cards "
            + "under, such as On My Mac, iCloud, or an Exchange or CardDAV server. A client sees no "
            + "card and no group outside these accounts. This is the field that bounds cards: every "
            + "card in one of these accounts is reachable, whether or not it is in any group.",
        appliesTo: ["contacts_*"],
        enumerate: { _ in ContactsService.enumerateAccounts() }
    ),
    ScopeField(
        name: "contact_groups",
        noun: "contact group",
        description: "Contact groups this client may list and change the membership of, each "
            + "written as Account/Group — for example “iCloud/Family”. The account is part of the "
            + "value because a group name on its own does not identify one: two accounts can each "
            + "hold a group called Family, and a bare name would silently grant both. Choose these "
            + "from the list rather than typing them. This field bounds groups, not cards: a "
            + "client granted contact_accounts and no groups still reads every card in those "
            + "accounts, and simply has no group tools.",
        appliesTo: [
            "contacts_list_groups", "contacts_create_group",
            "contacts_add_to_group", "contacts_remove_from_group"
        ],
        dependsOn: ["contact_accounts"],
        enumerate: { values in
            ContactsService.enumerateGroups(accountFilter: values?["contact_accounts"]?.stringsValue)
        }
    )
]

private let remindersScopeFields: [ScopeField] = [
    ScopeField(
        name: "reminder_accounts",
        noun: "reminder account",
        description: "Reminder accounts this client may reach — the sources Reminders files lists "
            + "under, such as iCloud, On My Mac, or an Exchange or CalDAV server. A client sees no "
            + "list outside these accounts.",
        appliesTo: ["reminders_*"],
        enumerate: { _ in RemindersService.enumerateAccounts() }
    ),
    ScopeField(
        name: "reminder_lists",
        noun: "reminder list",
        description: "Reminder lists this client may read and add to, each written as Account/List "
            + "— for example “iCloud/Groceries”. The account is part of the value because a list "
            + "name on its own does not identify one: two accounts can each hold a list called "
            + "Shopping, and a bare name would silently grant both. Choose these from the list "
            + "rather than typing them.",
        appliesTo: ["reminders_*"],
        dependsOn: ["reminder_accounts"],
        enumerate: { values in
            RemindersService.enumerateLists(accountFilter: values?["reminder_accounts"]?.stringsValue)
        }
    )
]

// MARK: - Reading the declaration back (ADR-011 decision 4)

/// Which of the declared fields govern a given tool, by that field's own
/// `applies_to`.
///
/// **The declaration is the enforcement, rather than a description of it.**
/// Before this, every mail handler named the scope fields it checked by hand,
/// as `accountKeys` / `mailboxKeys` arguments to `scopeRefusal` -- and the
/// handlers that had nothing to reconcile passed `[]` and therefore checked
/// nothing at all. `mail_list_mailboxes` passed `mailboxKeys: []`, so a
/// mediated call carrying no `mail_mailboxes` reached
/// `allowedList(.refuse) == nil`, which the generated JavaScript reads as "no
/// restriction", and the discovery tool listed **every mailbox on the
/// machine** -- the exact disclosure its own comment says it prevents.
/// `mail_send`, `mail_create_draft` and `mail_list_accounts` never consulted
/// `mail_mailboxes` either. Relay's own call-time presence check masks all
/// four, which is precisely the reason they had to be fixed: ADR-011
/// decision 4 exists so macMCP's test is independent of relay's, and a check
/// that only holds because the other side also ran one is one check, not two.
///
/// Deriving the list from the declaration instead means a field added to it is
/// enforced on the tools it declares, without anyone remembering to widen a
/// per-handler argument list -- which is the same fail-open shape ADR-011
/// finding 9 names for `disabled_tools`, one level down.
func scopeFieldsGoverning(tool: String) -> [ScopeField] {
    scopeFields.filter { field in
        // An absent `applies_to` governs every tool, which is how relay reads
        // it too. Nothing macMCP declares omits it today.
        guard !field.appliesTo.isEmpty else { return true }
        return field.appliesTo.contains { globMatches($0, tool) }
    }
}

/// The names of those fields, sorted -- the spelling every caller outside this
/// file wants.
func restrictFieldsGoverning(tool: String) -> [String] {
    scopeFieldsGoverning(tool: tool).map(\.name).sorted()
}

/// A tool-name glob: `*` matches any run of characters, everything else is
/// literal. `mail_*` is the only wildcard shape macMCP declares, but the
/// matcher is general because `applies_to` is a glob list by contract and a
/// matcher that silently mishandled a shape would fail *open*.
func globMatches(_ pattern: String, _ value: String) -> Bool {
    let segments = pattern.components(separatedBy: "*")
    guard segments.count > 1 else { return pattern == value }
    var rest = Substring(value)
    guard rest.hasPrefix(segments[0]) else { return false }
    rest = rest.dropFirst(segments[0].count)
    for segment in segments[1..<(segments.count - 1)] where !segment.isEmpty {
        guard let found = rest.range(of: segment) else { return false }
        rest = rest[found.upperBound...]
    }
    let last = segments[segments.count - 1]
    return last.isEmpty || rest.hasSuffix(last)
}
