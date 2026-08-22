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
/// `mailAccounts` / `mailMailboxes` / `fileDirs` being `nil` means only "this
/// field's key was not present in `_meta`"; whether that is state 1 or state
/// 2 depends on whether the call was mediated at all, which is what
/// `isScoped` answers, and `access(for:)` (or the three named wrappers below
/// it) is what an enforcer should actually call rather than re-deriving the
/// same branch on `isScoped` at every call site.
///
/// The three field names and shapes are ADR-011's worked `contextSchema` (see
/// `ContextSchema.swift`, declared in `main.swift`'s `initialize` handler):
/// `mail_accounts` and `mail_mailboxes` are operator-set and apply to
/// `mail_*`; `file_dirs` is derived by relay from a project's own path
/// (`source: "project_path"`).
///
/// **`file_dirs` is ADR-011's `write_dirs`, renamed because it was only ever
/// half the axis.** It governed `mail_save_attachment`'s `destination` and
/// `mail_get_source`'s `save_to` -- the two places macMCP writes a file --
/// while `mail_send` and `mail_create_draft` took `attachments: [absolute
/// POSIX paths]` and *read* whatever was named straight off the host into an
/// outbound message, scoped by nothing at all. That is ADR-011 finding 1 on
/// the read side and worse: finding 1 was an arbitrary host write, this was an
/// arbitrary host read wired directly to a channel that leaves the machine. A
/// write mail profile could mail out any file Mail could open, and did:
/// `mail_send {"attachments": ["/tmp/zsec-secret.txt"]}` through the live
/// `hermes-alice` profile arrived base64'd in Alice's Sent Maildir.
///
/// One axis rather than two (ADR-011 constraint 3): the field is the client's
/// **filesystem foothold on this host**, in both directions, and an operator
/// who has decided which directories a client may touch has answered both
/// questions at once. Two lists would be two chances to get it wrong for one
/// decision, and no one has named a case wanting read here and write there.
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

    /// Same contract as `mailAccounts`, for `file_dirs`.
    let fileDirs: [String]?

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
    static let none = MailScope(mailAccounts: nil, mailMailboxes: nil, fileDirs: nil, isScopedFlag: false)

    /// The answer to "is this call scoped at all?", and a distinct question
    /// from "what does `mail_accounts` allow?" on purpose: a call can be
    /// scoped by `file_dirs` alone (a local project's project-path bound,
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
    var fileDirsAccess: Access { access(for: fileDirs) }

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
            fileDirs: meta["file_dirs"]?.stringsValue,
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
        /// Refuse, with this sentence, because the *scope itself* cannot be
        /// applied -- not because the caller reached outside it.
        ///
        /// ADR-011 decision 11 draws this line for a scope naming a mailbox
        /// that does not exist, and the reason is the same here: a violation
        /// is a client probing a boundary and belongs in alerting, while a
        /// `file_dirs` entry that is not an absolute path is an operator
        /// mistake and belongs in the editor. Conflating them fills a security
        /// signal with configuration errors. So this maps to `errorResult`
        /// where `.refuse` maps to `scopeViolationResult`.
        case misconfigured(String)
    }

    /// **The one spelling every scope comparison is made in: NFC, lowercased.**
    ///
    /// Case-insensitivity is how every mailbox and account name a caller
    /// supplies is matched everywhere else in `MailService`. The one thing it
    /// can be wrong about is two mailboxes in one account whose paths differ
    /// only in case, where allowing one would admit the other. That is narrow
    /// -- same account, and Mail has to have been made to hold both -- and the
    /// alternative is worse: a scope that resolved names by a different rule
    /// from the one every tool resolves arguments by is how an operator ends
    /// up allowing a mailbox the client cannot reach, which is constraint 2
    /// defeating constraint 1.
    ///
    /// **Normalisation is the same argument, and it had the same bug in the
    /// opposite direction.** Swift's `==` on `String` compares by *canonical
    /// equivalence*, so `"Ã©"` spelled NFC (U+00E9) and NFD (U+0065 U+0301) are
    /// one string here; JavaScript's `===` compares UTF-16 code units, so in
    /// every generated script they are two. A scope naming an accented or
    /// Hebrew mailbox in one spelling and a Mail that reports the other
    /// therefore passed the Swift front door and was rejected by every JS
    /// seam behind it: the *correct* scope silently reached nothing, with no
    /// violation logged and nothing anywhere saying why. It fails closed,
    /// which is why it is a correctness bug rather than a hole, but a
    /// confinement that cannot express the names the machine actually holds is
    /// not a confinement an operator can use.
    ///
    /// So both sides fold to one form, at one boundary, and this is it. NFC
    /// because that is what `precomposedStringWithCanonicalMapping` and
    /// JavaScript's `normalize('NFC')` both produce, and it is re-applied
    /// after the case fold because lowercasing is not guaranteed to preserve
    /// the form. Every JS comparison calls `scopeFold`, whose body is this
    /// function transliterated (`MailService.scopeFoldJXA`), and every scope
    /// array reaching a script is folded here before it is emitted.
    static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    /// Membership under `fold`.
    static func names(_ value: String, oneOf allowed: [String]) -> Bool {
        let needle = fold(value)
        return allowed.contains { fold($0) == needle }
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

    /// Which direction a path is being confined in. The bound is one list
    /// (`file_dirs`); only the sentence a refusal is written in differs, and
    /// it has to, because "this client may not write files" is useless advice
    /// to a caller that was trying to attach one.
    enum FileUse {
        /// `mail_save_attachment`'s `destination`, `mail_get_source`'s
        /// `save_to`: macMCP creates a file here.
        case write
        /// `mail_send` / `mail_create_draft`'s `attachments`: macMCP opens a
        /// file here and puts its bytes into a message.
        case read
    }

    /// Whether a filesystem path is one this call may write to
    /// (`mail_save_attachment`'s `destination`, `mail_get_source`'s
    /// `save_to`).
    func writeDestination(_ path: String) -> Decision<String> {
        confine(path, for: .write)
    }

    /// Whether a filesystem path is one this call may read a file out of
    /// (`mail_send` / `mail_create_draft`'s `attachments`).
    ///
    /// **A client with no `file_dirs` may attach nothing at all.** This is
    /// ADR-011's own reasoning for finding 1, run in the other direction: an
    /// access profile has no host directory, relay derives nothing, so every
    /// use of the field refuses -- and that is the intended outcome, not a
    /// gap. Reading a file to mail it away is a filesystem foothold whether
    /// the bytes end on disk or in a message.
    func readableAttachment(_ path: String) -> Decision<String> {
        confine(path, for: .read)
    }

    /// The one containment check.
    ///
    /// The comparison follows fsMCP's `validatePath` in shape -- symlinks and
    /// `..` resolved on both sides before comparing, and a trailing separator
    /// on the prefix so `/foo` does not match `/foobar` -- and is deliberately
    /// stronger in the one place that one is wrong (see `realPath`). A path
    /// that does not exist yet -- the normal case for a `destination`, since
    /// `mail_save_attachment` is documented to create it -- is resolved
    /// component by component with the not-yet-existing tail carried
    /// lexically, which is the most that can be said about a path with
    /// nothing at the end of it.
    ///
    /// **The bound itself is checked, and a bound that is not an absolute
    /// path is refused rather than resolved.** `realPath` walks components
    /// from a `/` seed, so it answers `/` for `"."`, for `""` and for `".."`
    /// alike -- and `/` is a prefix of every absolute path, so a single such
    /// entry turned the whole check into a no-op that reported success.
    /// Measured over stdio: `file_dirs: ["."]` let `mail_get_source` write a
    /// message to `/tmp/zoutside/…`. A bare JSON string reaches
    /// `stringsValue` as `[""]`, so `"file_dirs": ""` was one of the
    /// spellings. Relay cannot currently produce any of them -- a profile
    /// cannot supply a `project_path` field and a local project's path is
    /// validated absolute -- and that is exactly why it is checked here:
    /// macMCP must not be relying on the value being well formed by the time
    /// it arrives.
    ///
    /// A bad entry is `.misconfigured` rather than `.refuse`: it is an
    /// operator mistake, not a client probing a boundary, and ADR-011
    /// decision 11 keeps those two apart so a security signal does not fill
    /// up with configuration errors. Every entry is checked, not just the
    /// ones reached before a match, so `["/valid", "."]` is refused rather
    /// than quietly working for paths under `/valid` and being a no-op for
    /// everything else.
    private func confine(_ path: String, for use: FileUse) -> Decision<String> {
        let expanded = (path as NSString).expandingTildeInPath
        switch fileDirsAccess {
        case .unscoped:
            return .unscoped
        case .refuse:
            switch use {
            case .write:
                return .refuse(
                    "this client may not write files: its access profile carries no `file_dirs`, "
                    + "and an absent or empty scope is a refusal rather than \"anywhere\". "
                    + "An access profile has no project directory to derive one from, so "
                    + "mail_save_attachment is unavailable to it and mail_get_source works "
                    + "without save_to."
                )
            case .read:
                return .refuse(
                    "this client may not attach files from this host: its access profile carries "
                    + "no `file_dirs`, and an absent or empty scope is a refusal rather than "
                    + "\"anywhere\". An access profile has no project directory to derive one from, "
                    + "so it may compose and send mail but may not read a file off this machine to "
                    + "put in it. Omit `attachments`."
                )
            }
        case .allowed(let dirs):
            var roots: [String] = []
            for dir in dirs {
                guard let root = MailScope.realPath((dir as NSString).expandingTildeInPath) else {
                    return .misconfigured(
                        "the directory scope this call carries is not usable: `file_dirs` entry "
                        + "\"\(dir)\" is not an absolute path, so there is no directory it names. "
                        + "Nothing was read or written. This is a configuration mistake rather than "
                        + "a refusal: the access profile making this call needs file_dirs set to "
                        + "absolute directory paths."
                    )
                }
                guard root != "/" else {
                    return .misconfigured(
                        "the directory scope this call carries is not usable: `file_dirs` entry "
                        + "\"\(dir)\" resolves to the filesystem root, which bounds nothing -- "
                        + "every absolute path is inside it. Nothing was read or written. Name the "
                        + "directories this client may reach instead."
                    )
                }
                roots.append(root)
            }
            guard let resolved = MailScope.realPath(expanded) else {
                return .refuse("path \"\(path)\" must be absolute")
            }
            for root in roots {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if resolved == root || resolved.hasPrefix(prefix) { return .use(expanded) }
            }
            switch use {
            case .write:
                return .refuse(
                    "path \"\(path)\" is outside the directories this client may write into: "
                    + dirs.joined(separator: ", ")
                )
            case .read:
                return .refuse(
                    "path \"\(path)\" is outside the directories this client may read files from: "
                    + dirs.joined(separator: ", ")
                )
            }
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
    /// **Each value is length-prefixed rather than joined with a separator.**
    /// A `,` join makes `["a,b"]` and `["a","b"]` spell the same fingerprint,
    /// and a mailbox path may contain a comma (Mail's own separator is `/`,
    /// which is no safer -- a path contains those by construction). There is
    /// no character that cannot occur in a value, so no separator can be
    /// chosen; a byte count in front of each value makes the encoding
    /// unambiguous whatever the values are. The collision is not academic: it
    /// is one process serving profile A bytes that were fetched under
    /// profile B, which is the exact bypass this key exists to prevent.
    var cacheFingerprint: String {
        guard isScoped else { return "u" }
        func part(_ values: [String]?) -> String {
            guard let values else { return "-" }
            return values.map(MailScope.fold).sorted().map { "\($0.utf8.count):\($0)" }.joined()
        }
        return "s[\(part(mailAccounts))][\(part(mailMailboxes))][\(part(fileDirs))]"
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
    ///
    /// **It answers `nil` for anything that is not already absolute**, rather
    /// than resolving it against the `/` it seeds. Seeding `/` is right for an
    /// absolute path and is how the walk starts, but it silently turned `"."`,
    /// `""` and `".."` into `/` -- a prefix of every absolute path there is --
    /// so a `file_dirs` entry spelled any of those was a bound that bounded
    /// nothing while still reporting a confinement. Returning `nil` makes the
    /// anchoring structural: there is nothing for a caller to remember to
    /// check, because the function cannot answer for a path it cannot anchor.
    private static func realPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
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
