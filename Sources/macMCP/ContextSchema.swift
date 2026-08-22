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
/// This is declaration only -- see `MailScope` for the type that parses a
/// value shaped like this out of `_meta`, and neither this nor that enforces
/// anything yet. ADR-011 decision 9 is explicit that declaring a scope an
/// MCP does not yet enforce is worse than declaring none: relay would then
/// advertise a confinement that is not real. This schema exists so the
/// *plumbing* (this change) and the *enforcement* (the change after it) land
/// as one server version, never independently -- relay must not start
/// offering this scope to an operator until macMCP actually honours it.
let mailContextSchema: JSONObject = [
    "mail_accounts": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Mail accounts this client may read from or send as"),
        "scope": .string("restrict"),
        "source": .string("operator"),
        "applies_to": .array([.string("mail_*")]),
        "enumerable": .bool(true)
    ]),
    "mail_mailboxes": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Mailbox paths within those accounts this client may reach"),
        "scope": .string("restrict"),
        "source": .string("operator"),
        "applies_to": .array([.string("mail_*")]),
        "enumerable": .bool(true),
        "depends_on": .array([.string("mail_accounts")])
    ]),
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
    // **`applies_to` still names only the two file tools, deliberately.**
    // Relay reads `applies_to` as "deny these tools outright when the field
    // has no value" (`checkScopePresence`), and denying `mail_send` outright
    // is not the intended outcome: a client with no `file_dirs` may still
    // send, it just may not attach a file off this host. The field governs the
    // *parameter*, which is the same reading `mail_get_source` has always had
    // here -- `save_to` is refused and the tool keeps working inline -- and it
    // is a reading only macMCP can act on, since relay is domain-blind about
    // arguments. That macMCP enforces something relay does not advertise is
    // the fail-CLOSED direction of a mismatch; ADR-011 decision 9 forbids the
    // other one, where relay advertises a confinement that is not real. The
    // `attachments` schema on both compose tools says so in the tool
    // description, which is the surface a client actually reads.
    "file_dirs": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Directories on this host this client may write files into and read attachments from"),
        "scope": .string("restrict"),
        "source": .string("project_path"),
        "applies_to": .array([.string("mail_save_attachment"), .string("mail_get_source")])
    ])
]

// MARK: - Reading the declaration back (ADR-011 decision 4)

/// Which of the fields declared above govern a given tool, by that field's own
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
/// Deriving the list from `mailContextSchema` instead means a field added to
/// the declaration is enforced on the tools it declares, without anyone
/// remembering to widen a per-handler argument list -- which is the same
/// fail-open shape ADR-011 finding 9 names for `disabled_tools`, one level
/// down.
func restrictFieldsGoverning(tool: String) -> [String] {
    mailContextSchema.compactMap { name, fragment -> String? in
        guard let fragment = fragment.objectValue,
              fragment["scope"]?.stringValue == "restrict" else { return nil }
        // An absent `applies_to` governs every tool, which is how relay reads
        // it too. Nothing macMCP declares omits it today.
        guard let patterns = fragment["applies_to"]?.stringsValue else { return name }
        return patterns.contains { globMatches($0, tool) } ? name : nil
    }.sorted()
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
