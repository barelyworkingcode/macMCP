import Foundation

/// The mail resource scope a caller's `_meta` carries, per ADR-011
/// ("A Client Is an Identity, an Access Profile, and a Resource Scope").
///
/// ADR-011 decision 4 ("Absent and empty are refusals, on all three sides")
/// depends on three states staying distinguishable, and collapsing any two of
/// them into one would make a correct enforcer impossible to write:
///
/// 1. **No scope is in play for this call at all** -- nothing mediated it, so
///    there is no chokepoint that could have injected one. A mail tool must
///    behave exactly as it always has: `mail_search` with no `account` scans
///    everything, as it does today with `MailCall` built from `nil` meta
///    (every existing test constructs one this way, and must keep doing so
///    unchanged).
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
/// 2 depends on whether the call was mediated at all, which is what
/// `isScoped` answers, and `access(for:)` (or the three named wrappers below
/// it) is what an enforcer should actually call rather than re-deriving the
/// same branch on `isScoped` at every call site.
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

    /// Whether this call was **mediated** -- whether `_meta` was present at
    /// all -- which is what makes it governed.
    ///
    /// **Not "did `_meta` carry one of my restrict keys".** That reading has a
    /// hole in the fail-open direction, and ADR-011 decision 4 names it: relay
    /// failing to inject a field, for any reason, produces a call that looks
    /// to macMCP exactly like an unmediated one, so the confinement would rest
    /// entirely on relay's own call-time presence check having run. That is
    /// one check, not two, and the whole point of decision 4 is that the MCP's
    /// test is independent of relay's.
    ///
    /// Relay injects `_meta.project_id` on **every** mediated call and has
    /// since ADR-007. So `_meta` present is a reliable signal that a
    /// chokepoint mediated this call, and macMCP can require its own declared
    /// restrict fields on that basis -- reading its own `contextSchema`,
    /// needing nothing from relay beyond the fact of mediation. `_meta` absent
    /// means nobody mediated: an operator running macmcp over stdio by hand,
    /// which is same-user local access equivalent to opening Mail.app, and
    /// behaves exactly as it always has.
    ///
    /// The consequence is deliberate and is the ADR's: a mediated call whose
    /// profile sets no mail scope loses every `mail_*` tool until an operator
    /// sets one. A scope has no safe default -- there is no answer to "which
    /// mailbox" anyone could pick and be right about -- so it is always
    /// required, and a missing one fails closed and loud.
    ///
    /// Stored rather than derived from `mailAccounts != nil || ...` for the
    /// same reason it always was: a key present with a malformed value (not a
    /// string or an array of strings) parses to `nil`, the same as absent, and
    /// must still refuse rather than read as "no restriction at all".
    private let isScopedFlag: Bool

    /// No `_meta` at all: the "nobody mediated this call" state. Every mail
    /// tool call macMCP has ever served over a bare stdio pipe falls here.
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
    /// `meta == nil` -- no `_meta` in the request at all -- is the only thing
    /// that produces `.none`. A present `_meta` makes the call governed even
    /// when it carries none of the three keys (see `isScopedFlag`), so a
    /// relay-mediated call whose profile sets no mail scope refuses rather
    /// than reading as unrestricted. A key present with a value that is not a
    /// string or an array of strings parses that field to `nil`, the same as
    /// absent, and refuses the same way.
    static func parse(_ meta: JSONObject?) -> MailScope {
        guard let meta else { return .none }
        return MailScope(
            mailAccounts: meta["mail_accounts"]?.stringsValue,
            mailMailboxes: meta["mail_mailboxes"]?.stringsValue,
            writeDirs: meta["write_dirs"]?.stringsValue,
            isScopedFlag: true
        )
    }
}

// MARK: - The reconciliation rule

/// ADR-011, "The reconciliation rule the MCP implements", stated once so every
/// seam applies the same rule:
///
/// * an **absent or default-valued** scope-relevant argument resolves **to the
///   scope**, not to everything;
/// * a **tool-level wildcard** (`mailbox: "all"`) means "everything I am
///   allowed to see" and resolves to the scope -- it does not error;
/// * an **explicit** argument outside the scope is an **error**, never a
///   silent narrowing, because silent narrowing lets an agent build a false
///   model of what it can reach and burn calls discovering the truth;
/// * **enumerators are scoped too**, since listing the machine's real account
///   names to a confined client is a disclosure and is how that client learns
///   what to try next.
extension MailScope {
    /// What one seam should do about one field, once the reconciliation rule
    /// has been applied to the caller's own argument.
    enum Decision<T>: Equatable where T: Equatable {
        /// Nothing is in play; behave exactly as macMCP always has.
        case unscoped
        /// Proceed, confined to this.
        case use(T)
        /// Refuse, with this sentence. Always a scope violation.
        case refuse(String)
    }

    /// Case-insensitive membership, which is how every mailbox and account
    /// name a caller supplies is matched everywhere else in `MailService`.
    ///
    /// The one thing case-insensitivity can be wrong about is two mailboxes in
    /// one account whose paths differ only in case, where allowing one would
    /// admit the other. That is narrow -- same account, and Mail has to have
    /// been made to hold both -- and the alternative is worse: a scope that
    /// resolved names by a different rule from the one every tool resolves
    /// arguments by is how an operator ends up allowing a mailbox the client
    /// cannot reach, which is constraint 2 defeating constraint 1.
    static func names(_ value: String, oneOf allowed: [String]) -> Bool {
        let needle = value.lowercased()
        return allowed.contains { $0.lowercased() == needle }
    }

    /// The scan targets for an `account` argument.
    ///
    /// `.use` carries account **names**, with `On My Mac` among them when the
    /// scope allows it -- it is an account name every mail tool accepts (#54),
    /// and relay cannot scope what the enumeration does not name, so it has to
    /// be nameable here too. The caller maps it onto the local pass.
    func accountTargets(requested: String?) -> Decision<[String]> {
        switch accountsAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            return .refuse(MailScope.refusalNoValue(field: "mail_accounts", noun: "mail account"))
        case .allowed(let allowed):
            guard let requested else { return .use(allowed) }
            guard MailScope.names(requested, oneOf: allowed) else {
                return .refuse(
                    "account \"\(requested)\" is outside the mail accounts this client may reach. "
                    + "It may reach: \(allowed.joined(separator: ", ")). "
                    + "Omit `account` to read every account it may reach."
                )
            }
            return .use([requested])
        }
    }

    /// The mailbox paths a scan may read, for a `mailbox` argument.
    ///
    /// `requested` is the argument **as the caller wrote it** -- `nil` for
    /// absent, which resolves to the scope rather than to the tool's own
    /// default, because a default-valued argument is not a choice the caller
    /// made. `wildcard` is the tool-level "everything" value, which also
    /// resolves to the scope.
    ///
    /// An explicit argument is matched against the allowed paths first, then
    /// against their leaf names, which is the same two-step every mailbox
    /// argument is resolved by (a bare name is a path with one component; a
    /// leaf name is a fallback). The *result* is still the whole allowed list:
    /// the intersection with what Mail actually holds happens inside the scan,
    /// against paths read off Mail rather than against strings.
    func mailboxTargets(requested: String?, wildcard: String = "all") -> Decision<[String]> {
        switch mailboxesAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            return .refuse(MailScope.refusalNoValue(field: "mail_mailboxes", noun: "mailbox"))
        case .allowed(let allowed):
            guard let requested, requested.lowercased() != wildcard.lowercased() else {
                return .use(allowed)
            }
            let leaves = allowed.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            guard MailScope.names(requested, oneOf: allowed)
                    || MailScope.names(requested, oneOf: leaves) else {
                return .refuse(
                    "mailbox \"\(requested)\" is outside the mailboxes this client may reach. "
                    + "It may reach: \(allowed.joined(separator: ", ")). "
                    + "Pass mailbox \"\(wildcard)\", or omit it, to read every mailbox it may reach."
                )
            }
            return .use(allowed)
        }
    }

    /// Whether a filesystem destination is one this call may write to
    /// (`write_dirs`, whose `applies_to` names exactly `mail_save_attachment`
    /// and `mail_get_source`).
    ///
    /// The comparison is fsMCP's `validatePath`, deliberately: symlinks and
    /// `..` resolved on both sides before comparing, and a trailing separator
    /// on the prefix so `/foo` does not match `/foobar`. A path that does not
    /// exist yet -- the normal case, since `mail_save_attachment` creates its
    /// destination -- is standardised without symlink resolution, which is the
    /// most that can be said about a path with nothing at the end of it.
    func writeDestination(_ path: String) -> Decision<String> {
        let expanded = (path as NSString).expandingTildeInPath
        switch writeDirsAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            return .refuse(
                "this client may not write files: its access profile carries no `write_dirs`, "
                + "and an absent or empty scope is a refusal rather than \"anywhere\". "
                + "An access profile has no project directory to derive one from, so "
                + "mail_save_attachment is unavailable to it and mail_get_source works "
                + "without save_to."
            )
        case .allowed(let dirs):
            guard expanded.hasPrefix("/") else {
                return .refuse("path \"\(path)\" must be absolute")
            }
            let resolved = MailScope.realPath(expanded)
            for dir in dirs {
                let root = MailScope.realPath((dir as NSString).expandingTildeInPath)
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if resolved == root || resolved.hasPrefix(prefix) { return .use(expanded) }
            }
            return .refuse(
                "path \"\(path)\" is outside the directories this client may write into: "
                + dirs.joined(separator: ", ")
            )
        }
    }

    /// A stable string identifying *this confinement*, for anything keyed on
    /// what a call may reach rather than on what it asked for.
    ///
    /// One consumer: `MailService.sourceCacheKey`. A held source is bytes
    /// handed back without running a script, and the script is where the scope
    /// is checked -- so the held bytes have to belong to the scope that
    /// fetched them, or a differently-confined caller reaching the same
    /// process is served a message it may not read, with nothing anywhere
    /// having decided that.
    ///
    /// Unscoped is its own value rather than the empty string, and the three
    /// fields are separated, so no two different scopes can spell the same
    /// fingerprint by rearranging their contents.
    var cacheFingerprint: String {
        guard isScoped else { return "u" }
        func part(_ values: [String]?) -> String {
            values.map { $0.map { $0.lowercased() }.sorted().joined(separator: ",") } ?? "-"
        }
        return "s[\(part(mailAccounts))][\(part(mailMailboxes))][\(part(writeDirs))]"
    }

    /// The path with every symlink and every `..` resolved, component by
    /// component, whether or not the whole path exists yet.
    ///
    /// **Deliberately stronger than fsMCP's `validatePath`**, which this
    /// otherwise follows exactly. That one resolves symlinks with
    /// `realpathSync` and falls back to a *lexical* `path.resolve` for a path
    /// that does not exist yet -- and the path here normally does not exist
    /// yet, because `mail_save_attachment` is documented to create its
    /// destination. Measured: with `write_dirs` allowing `<root>` and a
    /// symlink `<root>/way-out` pointing outside it, `<root>/way-out/f.txt`
    /// does not exist, so the lexical fallback compares a string that still
    /// begins with `<root>` and the write escapes.
    ///
    /// A client cannot plant that symlink through macMCP -- these two tools
    /// create directories and write files, nothing else -- but it does not
    /// have to: a project directory is an ordinary checkout, and repositories
    /// contain symlinks.
    ///
    /// Walking down rather than resolving the tail in one go is what makes
    /// `..` safe too: resolving it lexically first turns `a/link/../b` into
    /// `a/b`, which is a different directory when `link` points elsewhere.
    /// Each component is appended and then resolved, so `..` is applied to
    /// where the path really is by then.
    private static func realPath(_ path: String) -> String {
        let manager = FileManager.default
        var resolved = "/"
        for component in (path as NSString).pathComponents {
            if component == "/" || component == "." { continue }
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved.isEmpty { resolved = "/" }
                continue
            }
            resolved = (resolved as NSString).appendingPathComponent(component)
            if manager.fileExists(atPath: resolved) {
                resolved = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            }
        }
        return resolved
    }

    /// The one sentence for a field a mediated call did not carry a value for.
    ///
    /// Absent and empty say the same thing on purpose (decision 4): an
    /// operator who never set the field and one who set it to `[]` have both
    /// granted nothing, and a client that could tell them apart would learn
    /// only which mistake was made.
    private static func refusalNoValue(field: String, noun: String) -> String {
        "this call carries no `\(field)`, so there is no \(noun) it may reach. "
        + "An absent or empty resource scope is a refusal rather than \"everything\": "
        + "the access profile making this call needs \(field) set to the "
        + "\(noun)(s) it is allowed to reach."
    }
}

// MARK: - Carrying a scope refusal out of generated JavaScript

/// How a refusal raised *inside* a generated script says that it was a scope
/// violation rather than any other kind of no.
///
/// Most of what `MailService` does is generated JavaScript, and several scope
/// checks can only happen there: `messages.byId` resolves globally, so where a
/// message really is comes off the message; a destination mailbox is only
/// known once it has been resolved; and which account owns a `from` address is
/// something only Mail can answer. Those refusals reach Swift as prose -- a
/// thrown sentence unwrapped by `scriptErrorMessage`, or an `{error: ...}`
/// field -- and prose is exactly what ADR-011 decision 7 says relay must not
/// have to parse.
///
/// So a script-side scope refusal prefixes its sentence with a sentinel, and
/// `MailService.mailError` strips it back off and tags the result's `_meta`
/// instead. U+0001 cannot occur in a mailbox path, an account name or an email
/// address, and is not something a caller can smuggle in through an argument
/// that gets echoed back: the match is on the *prefix*, so an argument would
/// have to begin the sentence, and every sentence here begins with text this
/// file wrote.
enum MailScopeRefusal {
    static let sentinel = "\u{1}scope_violation\u{1}"

    /// Wraps a message for a script to throw or return.
    static func mark(_ message: String) -> String { sentinel + message }

    /// Splits the sentinel back off. `violation` is false for every message
    /// that never carried one, which is every message written before this
    /// existed.
    static func split(_ message: String) -> (message: String, violation: Bool) {
        guard message.hasPrefix(sentinel) else { return (message, false) }
        return (String(message.dropFirst(sentinel.count)), true)
    }
}
