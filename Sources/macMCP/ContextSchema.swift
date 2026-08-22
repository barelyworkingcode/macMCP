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
    "write_dirs": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Directories this client may write files into"),
        "scope": .string("restrict"),
        "source": .string("project_path"),
        "applies_to": .array([.string("mail_save_attachment"), .string("mail_get_source")])
    ])
]
