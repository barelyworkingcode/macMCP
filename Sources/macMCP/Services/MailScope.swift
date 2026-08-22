import Foundation

/// The mail resource scope a caller's `_meta` carries, per ADR-011
/// ("A Client Is an Identity, an Access Profile, and a Resource Scope").
///
/// **This type is plumbing, not enforcement.** Nothing here refuses a call --
/// that is the job of a following change. What has to be right *now* is the
/// representation, because ADR-011 decision 4 ("Absent and empty are
/// refusals, on all three sides") depends on three states staying
/// distinguishable, and collapsing any two of them into one would make a
/// correct enforcer impossible to write later without re-deriving this type:
///
/// 1. **No scope is in play for this call at all** -- there is no relay-like
///    chokepoint injecting resource scope, or the caller's access profile
///    declares no mail scope for this MCP. A mail tool must behave exactly as
///    it always has: `mail_search` with no `account` scans everything, as it
///    does today with `MailCall` built from `nil` meta (every existing test
///    constructs one this way, and must keep doing so unchanged).
/// 2. **A scope is in play, and a field it governs is missing or empty.**
///    ADR-011's decision 4 is explicit that this is a *refusal*, not a
///    fallback to "everything" and not a fallback to some CLI default. This
///    is what makes finding 9's fail-open shape (`disabled_tools` as an
///    upgrade-safe allowlist) safe to generalise: a scope field an operator
///    never got round to setting must not silently mean "unrestricted".
/// 3. **A scope is in play, and the field lists what it allows.**
///
/// States 1 and 2 look identical if a field's absence is represented the
/// same way whether or not anything else in `_meta` was scoped -- which is
/// exactly the mistake this type exists to make structurally impossible.
/// `mailAccounts` / `mailMailboxes` / `writeDirs` being `nil` means only "this
/// field's key was not present in `_meta`"; whether that is state 1 or state
/// 2 depends on whether *any* of the three fields was present at all, which
/// is what `isScoped` answers, and `access(for:)` (or the three named
/// wrappers below it) is what an enforcer should actually call rather than
/// re-deriving the same branch on `isScoped` at every call site.
///
/// The three field names and shapes are exactly ADR-011's worked
/// `contextSchema` (see `main.swift`'s `initialize` handler): `mail_accounts`
/// and `mail_mailboxes` are operator-set and apply to `mail_*`; `write_dirs`
/// is derived by relay from a project's own path (`source: "project_path"`)
/// and applies only to `mail_save_attachment` and `mail_get_source`.
struct MailScope: Equatable {
    /// `nil` means the request's `_meta` had no `mail_accounts` key at all.
    /// A present-but-empty array (`[]`) is a distinct, equally-refusing state
    /// -- see `Access` below -- kept apart from `nil` because "an operator
    /// wrote an empty list" and "the key was never sent" are different facts
    /// worth telling apart later (diagnostics, audit), even though decision 4
    /// treats them identically for the purpose of the call.
    let mailAccounts: [String]?

    /// Same contract as `mailAccounts`, for `mail_mailboxes`.
    let mailMailboxes: [String]?

    /// Same contract as `mailAccounts`, for `write_dirs`.
    let writeDirs: [String]?

    /// Whether `_meta` carried the *key* for any of the three fields this
    /// type models, at all -- i.e. whether whatever produced `_meta`
    /// attempted to describe a mail resource scope for this call, regardless
    /// of which field or whether its value parsed.
    ///
    /// Stored rather than derived from `mailAccounts != nil || ...` on
    /// purpose: a key present with a malformed value (not a string or an
    /// array of strings) parses to `nil`, the same as the key being absent,
    /// because a malformed field must fail closed exactly as a missing one
    /// does. If `isScoped` were derived from field-nilness, that malformed
    /// field would ALSO make the call look unscoped whenever it was the only
    /// restrict key present -- turning a misconfigured scope into "no
    /// restriction at all", which is the fail-open direction this whole
    /// mechanism exists to rule out. Tracking presence independently of
    /// parse success keeps `isScoped == true` (and therefore `.refuse`, not
    /// `.unscoped`) for that case.
    private let isScopedFlag: Bool

    /// No `_meta` at all, or `_meta` present with none of the three keys --
    /// the "no scope schema in play" state. Every mail tool call macMCP has
    /// ever served falls here today, since nothing yet injects a scope.
    static let none = MailScope(mailAccounts: nil, mailMailboxes: nil, writeDirs: nil, isScopedFlag: false)

    /// The answer to "is this call scoped at all?", and a distinct question
    /// from "what does `mail_accounts` allow?" on purpose: a call can be
    /// scoped by `write_dirs` alone (a local project's project-path bound,
    /// auto-derived with no operator action) while carrying no
    /// `mail_accounts` -- and whether that combination should refuse
    /// `mail_search` is a per-tool `applies_to` question for the enforcer,
    /// not something this type should decide by collapsing the three fields
    /// into one flag.
    var isScoped: Bool { isScopedFlag }

    /// What one field allows, for a caller that already knows which field
    /// governs the tool it is about to run.
    enum Access: Equatable {
        /// No scope is in play for this call at all (`isScoped == false`).
        /// The tool must behave exactly as it does when built with `.none`.
        case unscoped
        /// A scope is in play, but this field is absent or empty. ADR-011
        /// decision 4: refuse every call this field governs. Never treat
        /// this as "unrestricted" and never treat it as "everything" --
        /// both are the fail-open mistake finding 8 named in fsMCP.
        case refuse
        /// A scope is in play and this field lists what it allows. The list
        /// is never empty here -- an empty list is `.refuse`, not
        /// `.allowed([])`, so a caller can match on this case and use the
        /// array without an extra emptiness check.
        case allowed([String])
    }

    private func access(for field: [String]?) -> Access {
        guard isScoped else { return .unscoped }
        guard let field, !field.isEmpty else { return .refuse }
        return .allowed(field)
    }

    var accountsAccess: Access { access(for: mailAccounts) }
    var mailboxesAccess: Access { access(for: mailMailboxes) }
    var writeDirsAccess: Access { access(for: writeDirs) }

    /// Parses a scope out of the `_meta` object a `tools/call` request
    /// carried, per `MCPCallContext.meta`.
    ///
    /// `meta == nil` (no `_meta` in the request at all) and `meta` present
    /// but missing all three keys both produce `.none` / `isScoped == false`
    /// -- correctly, since neither describes any mail resource scope. `meta`
    /// present with a key whose value is not a string or an array of strings
    /// (a malformed field) parses that field to `nil`, the same as absent,
    /// but still counts as scoped -- see `isScopedFlag` -- so a malformed
    /// restrict field fails closed (`.refuse`) rather than being silently
    /// ignored in a way that would read as "unrestricted".
    static func parse(_ meta: JSONObject?) -> MailScope {
        guard let meta else { return .none }
        let restrictKeys = ["mail_accounts", "mail_mailboxes", "write_dirs"]
        return MailScope(
            mailAccounts: meta["mail_accounts"]?.stringsValue,
            mailMailboxes: meta["mail_mailboxes"]?.stringsValue,
            writeDirs: meta["write_dirs"]?.stringsValue,
            isScopedFlag: restrictKeys.contains { meta[$0] != nil }
        )
    }
}
