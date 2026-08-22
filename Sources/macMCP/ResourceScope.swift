import Foundation

// MARK: - What a service declares

/// Who supplies a `scope: "restrict"` field's value (ADR-011 decision 5).
enum ScopeSource: String {
    /// An operator types it, once, into relay's editor. Local and remote alike.
    case operatorSet = "operator"
    /// Relay derives it from `Project.Path`, so an access profile -- which has
    /// no path -- never carries one, and everything it governs refuses.
    case projectPath = "project_path"
}

/// One `context/enumerate` answer: the values a picker offers for one field.
///
/// `value` is what goes into `_meta` verbatim; `label` is display only.
///
/// **A non-nil `error` must become a JSON-RPC error and never an empty
/// `entries`.** An operator's picker has to be able to tell "this Mac holds no
/// more calendars" from "the store could not be read at all" -- an empty list
/// rendered for a call that failed gets a profile saved against a host the
/// operator was shown nothing about (`relay/docs/context-schema.md`). The two
/// halves of the tuple are what keeps them apart, which is why the shape is
/// this rather than a bare array.
///
/// An enumeration runs for the operator configuring a profile, not for any
/// client: it carries no `_meta`, applies no scope, lists the whole host, and
/// never reaches `tools/list` -- ADR-011 decision 6 names that disclosure as
/// deliberate.
///
/// A tuple rather than a struct or a `Result` because that is the shape every
/// other read helper in this codebase already returns (`accountNames`,
/// `runJXA`, `calendarRows`), and the pair has no behaviour worth a type.
typealias ScopeEnumeration = (entries: [(value: String, label: String)], error: String?)

/// A `scope: "restrict"` field, declared once by the service that owns it.
///
/// **This is the whole per-service surface.** A service says what its fields
/// are called, what a value of one *is* in one operator-facing sentence, which
/// of its tools the field governs, and -- if the field can be listed -- how to
/// list it. Everything after that (parsing `_meta`, the three-state `Access`
/// answer, the presence check, folding, path containment, the cache
/// fingerprint, the `context/enumerate` dispatch) is machinery it gets for
/// free from `ResourceScope` and `ContextSchema.swift`.
///
/// The alternative -- each service growing its own `MailScope`-shaped type --
/// is four copies of a rule whose failure direction is fail-open, which is
/// exactly the shape ADR-011 finding 7 names when it says service-specific
/// knowledge belongs in services but the *rule* does not.
struct ScopeField {
    /// The `_meta` key and the `contextSchema` map key. Opaque to relay.
    let name: String

    /// What one value of this field is, singular, for a refusal sentence:
    /// "there is no **mailbox** `mail_search` may reach". Written here rather
    /// than at the refusal so a field added later cannot forget it.
    let noun: String

    /// Shown to an operator verbatim in relay's editor. Write it for that
    /// reader: they are deciding what a semi-trusted agent may reach, and they
    /// cannot see this file.
    let description: String

    let source: ScopeSource

    /// Tool-name globs. **Absent/empty governs every tool**, which is how
    /// relay reads it too and is the fail-closed reading for a restriction.
    let appliesTo: [String]

    /// Fields whose already-chosen values arrive as `values` on a
    /// `context/enumerate` request, so a picker fills in dependency order.
    let dependsOn: [String]

    /// How to list this field's real values for the operator picker, or `nil`
    /// for a field that cannot be listed.
    ///
    /// **`enumerable` is derived from this rather than declared beside it.**
    /// The two used to be separate -- a bool in the schema and a `switch` in
    /// `MailService.enumerateContext` whose `default:` branch existed solely
    /// to answer "macmcp declares this enumerable but does not implement its
    /// enumeration". A field that carries its own enumerator cannot be in that
    /// state, so the branch is gone rather than kept as a guard against a
    /// mistake that is no longer expressible.
    let enumerate: ((_ values: JSONObject?) -> ScopeEnumeration)?

    init(
        name: String,
        noun: String,
        description: String,
        source: ScopeSource = .operatorSet,
        appliesTo: [String],
        dependsOn: [String] = [],
        enumerate: ((_ values: JSONObject?) -> ScopeEnumeration)? = nil
    ) {
        self.name = name
        self.noun = noun
        self.description = description
        self.source = source
        self.appliesTo = appliesTo
        self.dependsOn = dependsOn
        self.enumerate = enumerate
    }

    var isEnumerable: Bool { enumerate != nil }

    /// The JSON fragment relay reads, per `relay/docs/context-schema.md`.
    ///
    /// `enumerable` and `depends_on` are **omitted** rather than emitted false
    /// or empty: relay's contract is that a keyword's absence is its default,
    /// and a `file_dirs` carrying `enumerable: false` would be a second
    /// spelling of the same fact for anyone reading the declaration by hand.
    ///
    /// Every field macMCP declares is an array of strings; nothing here has
    /// ever needed another shape, and relay validates only array-of-string and
    /// string anyway.
    var declaration: JSONValue {
        var fragment: JSONObject = [
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
            "scope": .string("restrict"),
            "source": .string(source.rawValue),
            "applies_to": .array(appliesTo.map { .string($0) })
        ]
        if isEnumerable { fragment["enumerable"] = .bool(true) }
        if !dependsOn.isEmpty {
            fragment["depends_on"] = .array(dependsOn.map { .string($0) })
        }
        return .object(fragment)
    }
}

// MARK: - What a call carries

/// The resource scope one `tools/call` carries, whatever service it is for.
///
/// This is `MailScope` generalised (`MailScope` is now a typealias for it, and
/// mail's field names and reconciliation rules live in an extension in
/// `MailScope.swift`). What moved here is everything that was never about mail:
///
/// * the three-state `Access` answer and the rule that produces it;
/// * `isScoped` -- **`_meta` was present at all**, not "`_meta` carried one of
///   my fields";
/// * `Decision`, including `misconfigured` as an outcome distinct from a scope
///   violation;
/// * `fold`, the one spelling every comparison is made in;
/// * the path containment walk;
/// * the cache fingerprint;
/// * the presence check driven by the declaration's own `applies_to`.
///
/// ADR-011 decision 4 ("Absent and empty are refusals, on all three sides")
/// depends on three states staying distinguishable, and collapsing any two of
/// them into one would make a correct enforcer impossible to write:
///
/// 1. **No scope is in play for this call at all** -- nothing mediated it, so
///    there is no chokepoint that could have injected one. A tool must behave
///    exactly as it always has: `mail_search` with no `account` scans
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
/// States 1 and 2 look identical if a field's absence is represented the same
/// way whether or not anything else in `_meta` was scoped -- which is exactly
/// the mistake this type exists to make structurally impossible. `values(of:)`
/// returning `nil` means only "this field's key was not present in `_meta`";
/// whether that is state 1 or state 2 depends on whether the call was mediated
/// at all, which is what `isScoped` answers, and `access(_:)` (or a service's
/// named wrappers over it) is what an enforcer should actually call rather
/// than re-deriving the same branch at every call site.
struct ResourceScope: Equatable {
    /// One entry per declared `scope: "restrict"` field whose key was present
    /// in `_meta` **and** parsed as a string or array of strings.
    ///
    /// A key present with a malformed value is *absent* here and present in
    /// `_meta`, which is deliberate: it must refuse rather than read as "no
    /// restriction at all", and `isScopedFlag` is what carries the difference.
    /// A key present as `[]` is stored as `[]` -- a distinct fact from absent,
    /// worth telling apart later (diagnostics, audit), even though decision 4
    /// treats them identically for the purpose of the call.
    private let fields: [String: [String]]

    /// Whether this call was **mediated** -- whether `_meta` was present at
    /// all -- which is what makes it governed.
    ///
    /// **Not "did `_meta` carry one of my restrict keys".** That reading has a
    /// hole in the fail-open direction, and ADR-011 decision 4 names it: relay
    /// failing to inject a field, for any reason, produces a call that looks
    /// to macMCP exactly like an unmediated one, so the confinement would rest
    /// entirely on relay's own call-time presence check having run. That is
    /// one check, not two, and the whole point of decision 4 is that the MCP's
    /// test is independent of relay's. It is the one test in this mechanism
    /// that is macMCP's own rather than relay's, and generalising the type
    /// must not weaken it.
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
    /// profile sets no scope for a service loses that service's tools until an
    /// operator sets one. A scope has no safe default -- there is no answer to
    /// "which mailbox", or "which calendar", anyone could pick and be right
    /// about -- so it is always required, and a missing one fails closed and
    /// loud.
    private let isScopedFlag: Bool

    /// No `_meta` at all: the "nobody mediated this call" state. Every tool
    /// call macMCP has ever served over a bare stdio pipe falls here.
    static let none = ResourceScope(fields: [:], isScopedFlag: false)

    var isScoped: Bool { isScopedFlag }

    /// Parses a scope out of the `_meta` object a `tools/call` request carried,
    /// per `MCPCallContext.meta`.
    ///
    /// `meta == nil` -- no `_meta` in the request at all -- is the only thing
    /// that produces `.none`. A present `_meta` makes the call governed even
    /// when it carries none of the declared keys (see `isScopedFlag`), so a
    /// relay-mediated call whose profile sets no scope refuses rather than
    /// reading as unrestricted.
    ///
    /// Only **declared** fields are read. `_meta` is a general channel -- it
    /// carries `project_id` today and could carry anything tomorrow -- and a
    /// scope built from whatever happened to be in it would be a scope an
    /// operator never wrote.
    static func parse(_ meta: JSONObject?) -> ResourceScope {
        guard let meta else { return .none }
        var parsed: [String: [String]] = [:]
        for field in restrictFields {
            guard let raw = meta[field.name], let strings = raw.stringsValue else { continue }
            parsed[field.name] = strings
        }
        return ResourceScope(fields: parsed, isScopedFlag: true)
    }

    /// The raw value of one declared field: `nil` for "the key was not present
    /// (or did not parse)", `[]` for "present and empty". Both refuse; see
    /// `access(_:)`.
    func values(of field: String) -> [String]? { fields[field] }

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

    func access(_ field: String) -> Access {
        guard isScopedFlag else { return .unscoped }
        guard let values = fields[field], !values.isEmpty else { return .refuse }
        return .allowed(values)
    }

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
        /// that does not exist, and the reason generalises: a violation is a
        /// client probing a boundary and belongs in alerting, while a
        /// `file_dirs` entry that is not an absolute path -- or, in phase 2, a
        /// `calendars` entry naming a calendar that is not on this Mac -- is
        /// an operator mistake and belongs in the editor. Conflating them
        /// fills a security signal with configuration errors. So this maps to
        /// `errorResult` where `.refuse` maps to `scopeViolationResult`.
        case misconfigured(String)
    }

    // MARK: - The one spelling every comparison is made in

    /// **NFC, lowercased, NFC again.**
    ///
    /// Case-insensitivity is how every mailbox and account name a caller
    /// supplies is matched everywhere else in `MailService`, and the same is
    /// true of a calendar title or a reminder list. The one thing it can be
    /// wrong about is two resources in one container whose names differ only
    /// in case, where allowing one would admit the other. That is narrow, and
    /// the alternative is worse: a scope that resolved names by a different
    /// rule from the one every tool resolves arguments by is how an operator
    /// ends up allowing a resource the client cannot reach, which is
    /// constraint 2 defeating constraint 1.
    ///
    /// **Normalisation is the same argument, and it had the same bug in the
    /// opposite direction.** Swift's `==` on `String` compares by *canonical
    /// equivalence*, so `"é"` spelled NFC (U+00E9) and NFD (U+0065 U+0301) are
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
    ///
    /// EventKit and Contacts need no JS twin -- there is no generated script
    /// on those paths -- but they need the *same* fold, or a `calendars` value
    /// an operator picked out of macMCP's own enumeration would fail to match
    /// the calendar it came from.
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

    // MARK: - The presence check (ADR-011 decision 4)

    /// ADR-011 decision 4's presence requirement, read off macMCP's own
    /// declaration rather than off a list re-typed per handler, and returning
    /// the refusal sentence or `nil` to proceed.
    ///
    /// For every `scope: "restrict"` field whose `applies_to` selects this
    /// tool, a mediated call must carry a non-empty value or the call refuses.
    /// The three states `Access` keeps apart are what makes it correct:
    /// `.unscoped` (nobody mediated -- behave exactly as macmcp on a bare
    /// stdio pipe always has), `.refuse` (mediated, field absent or empty --
    /// refuse), `.allowed` (proceed, confined).
    ///
    /// **`source: "project_path"` fields are excluded here, and that is the
    /// one judgement in this function.** ADR-011 decision 4 says a governed
    /// call refuses; relay applies that to the whole tool. macMCP applies it
    /// to the *parameter*, because that is a distinction only macMCP can make
    /// and the tool-level reading gives a wrong answer at both tools
    /// `file_dirs` names: `mail_get_source` reads a message inline perfectly
    /// well with nowhere to write, and `mail_save_attachment` is unusable
    /// without a destination anyway -- so the tool-level check would be
    /// redundant where it is right and wrong where it is not. Selecting by
    /// `source` rather than by field name keeps that from being a hardcoded
    /// exception: an operator-set field is a grant of *resources*, and having
    /// none of them means there is nothing for the tool to act on; a
    /// `project_path` field is a filesystem foothold, and having none of it
    /// means one argument is unavailable.
    ///
    /// The old mail-only version carried a `default:` branch that refused a
    /// declared field it did not know how to read -- necessary when the field
    /// name to `Access` mapping was a hand-written `switch`, and impossible to
    /// reach now that a field's value is looked up by its own declared name.
    func presenceRefusal(tool: String) -> String? {
        guard isScopedFlag else { return nil }
        for field in scopeFieldsGoverning(tool: tool) where field.source == .operatorSet {
            if case .refuse = access(field.name) {
                return ResourceScope.refusalNoValue(field: field.name, noun: field.noun, subject: tool)
            }
        }
        return nil
    }

    /// The one sentence for a field a mediated call did not carry a value for.
    ///
    /// Absent and empty say the same thing on purpose (decision 4): an
    /// operator who never set the field and one who set it to `[]` have both
    /// granted nothing, and a client that could tell them apart would learn
    /// only which mistake was made.
    ///
    /// `subject` is the tool name where one is known and "it" where the
    /// refusal is being written by a seam that does not have one.
    static func refusalNoValue(field: String, noun: String, subject: String = "it") -> String {
        "this call carries no `\(field)`, so there is no \(noun) \(subject) may reach. "
        + "An absent or empty resource scope is a refusal rather than \"everything\": "
        + "the access profile making this call needs \(field) set to the "
        + "\(noun)(s) it is allowed to reach."
    }

    // MARK: - A confinement identifies itself

    /// A stable string identifying *this confinement*, for anything keyed on
    /// what a call may reach rather than on what it asked for.
    ///
    /// One consumer today: `MailService.sourceCacheKey`. A held source is
    /// bytes handed back without running a script, and the script is where the
    /// scope is checked -- so the held bytes have to belong to the scope that
    /// fetched them, or a differently-confined caller reaching the same
    /// process is served a message it may not read, with nothing anywhere
    /// having decided that. ADR-011 decision 10 states it generally: **any
    /// memoisation of a scope-governed result must be keyed on the scope.**
    ///
    /// Unscoped is its own value rather than the empty string, and every
    /// declared field gets its own bracketed slot in a fixed order, so no two
    /// different scopes can spell the same fingerprint by rearranging their
    /// contents. **Each value is length-prefixed rather than joined with a
    /// separator.** A `,` join makes `["a,b"]` and `["a","b"]` spell the same
    /// fingerprint, and a mailbox path may contain a comma (Mail's own
    /// separator is `/`, which is no safer -- a path contains those by
    /// construction; so does a `Source/Title` calendar path). There is no
    /// character that cannot occur in a value, so no separator can be chosen;
    /// a byte count in front of each value makes the encoding unambiguous
    /// whatever the values are. The collision is not academic: it is one
    /// process serving profile A bytes that were fetched under profile B,
    /// which is the exact bypass this key exists to prevent.
    ///
    /// A field declared later joins the fingerprint automatically, which is
    /// the point: a cache keyed on three of nine fields would be a bypass the
    /// day a fourth started mattering.
    var cacheFingerprint: String {
        guard isScopedFlag else { return "u" }
        let parts = restrictFields.map { field -> String in
            guard let values = fields[field.name] else { return "[-]" }
            return "[" + values.map(ResourceScope.fold).sorted().map { "\($0.utf8.count):\($0)" }.joined() + "]"
        }
        return "s" + parts.joined()
    }

    // MARK: - Confining a filesystem path

    /// What the containment walk concluded. The *sentences* stay with the
    /// service, because "this client may not write files" is useless advice to
    /// a caller that was trying to attach one; the *rule* is here, because
    /// getting it wrong is ADR-011 decision 10's second seam.
    enum PathBound: Equatable {
        /// Contained. Carries the tilde-expanded path to act on -- the
        /// resolved one is for comparing, not for opening.
        case inside(String)
        /// Resolved, and under none of the bounds.
        case outside
        /// The path being checked is not absolute, so there is nothing to
        /// anchor it to.
        case notAbsolute
        /// A **bound** entry is not an absolute path. An operator mistake
        /// rather than a client reaching outside: `.misconfigured`, not
        /// `.refuse`.
        case rootNotAbsolute(String)
        /// A bound entry resolves to `/`, which bounds nothing.
        case rootIsFilesystemRoot(String)
    }

    /// Whether `path` is inside one of `dirs`.
    ///
    /// The comparison follows fsMCP's `validatePath` in shape -- symlinks and
    /// `..` resolved on both sides before comparing, and a trailing separator
    /// on the prefix so `/foo` does not match `/foobar` -- and is deliberately
    /// stronger in the one place that one is wrong (see `realPath`). A path
    /// that does not exist yet -- the normal case for a `destination`, since
    /// `mail_save_attachment` is documented to create it -- is resolved
    /// component by component with the not-yet-existing tail carried
    /// lexically, which is the most that can be said about a path with nothing
    /// at the end of it.
    ///
    /// **Every bound entry is checked, not just the ones reached before a
    /// match**, so `["/valid", "."]` is refused rather than quietly working
    /// for paths under `/valid` and being a no-op for everything else.
    static func bound(_ path: String, within dirs: [String]) -> PathBound {
        var roots: [String] = []
        for dir in dirs {
            guard let root = realPath((dir as NSString).expandingTildeInPath) else {
                return .rootNotAbsolute(dir)
            }
            guard root != "/" else { return .rootIsFilesystemRoot(dir) }
            roots.append(root)
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realPath(expanded) else { return .notAbsolute }
        for root in roots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if resolved == root || resolved.hasPrefix(prefix) { return .inside(expanded) }
        }
        return .outside
    }

    /// The path with every symlink and every `..` resolved, component by
    /// component, whether or not the whole path exists yet.
    ///
    /// **Deliberately stronger than fsMCP's `validatePath`**, which this
    /// otherwise follows exactly. That one resolves symlinks with
    /// `realpathSync` and falls back to a *lexical* `path.resolve` for a path
    /// that does not exist yet -- and the path here normally does not exist
    /// yet, because `mail_save_attachment` is documented to create its
    /// destination. Measured: with `file_dirs` allowing `<root>` and a symlink
    /// `<root>/way-out` pointing outside it, `<root>/way-out/f.txt` does not
    /// exist, so the lexical fallback compares a string that still begins with
    /// `<root>` and the write escapes.
    ///
    /// A client cannot plant that symlink through macMCP -- these tools create
    /// directories and write files, nothing else -- but it does not have to: a
    /// project directory is an ordinary checkout, and repositories contain
    /// symlinks.
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
    static func realPath(_ path: String) -> String? {
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
}

// MARK: - A container and a leaf make a path

/// The representation a scope value uses for a resource that lives inside
/// something: a calendar in a source, a reminder list in a source, a contact
/// group in a container.
///
/// **A leaf name does not identify a resource; the path does.** This is the
/// mailbox lesson (CLAUDE.md: "Mail flattens an account's mailbox tree and
/// reports leaf names ... `mail_move` to `\"Archive\"` filed into
/// `Projects/Archive`") arriving in EventKit and Contacts, where it is the
/// same bug with a different framework underneath: `EKCalendar.title` is not
/// unique, two calendars in different sources can share one, and
/// `CalendarService` matches with `$0.title == name` -- which returns *both*.
/// A permission value that selects two calendars when an operator picked one
/// is a widening they never saw.
///
/// So the value is `Source/Title` (`iCloud/Work`), and for a contact group
/// `Container/Name`.
///
/// **The path is matched whole and never split.** Mail could rely on `/` being
/// impossible inside a mailbox leaf name (creating `a/b` creates `b` inside
/// `a`); a calendar title or a group name has no such rule and may contain a
/// slash. Splitting a value on `/` would therefore be guessing. Matching the
/// generated string against the generated strings needs no such guess, and the
/// residual case -- two different (container, leaf) pairs generating one
/// string -- is exactly what `ambiguousValues` reports, on the same footing as
/// two calendars genuinely sharing a source and a title.
enum ScopePath {
    struct Row: Equatable {
        let container: String
        let leaf: String

        init(container: String, leaf: String) {
            self.container = container
            self.leaf = leaf
        }

        var path: String { "\(container)/\(leaf)" }
    }

    /// The `context/enumerate` entries for a *container* field
    /// (`calendar_accounts`, `contact_accounts`, `reminder_accounts`), in
    /// first-seen order, one per distinct container.
    static func containerEntries(fromRows rows: [Row]) -> [(value: String, label: String)] {
        containerEntries(fromContainers: rows.map(\.container))
    }

    /// The same, for a service whose account list is read directly rather than
    /// derived from its leaves -- `contact_accounts`, where an account holding
    /// a thousand cards and no group must still be offered.
    static func containerEntries(fromContainers names: [String]) -> [(value: String, label: String)] {
        var seen: Set<String> = []
        var entries: [(value: String, label: String)] = []
        for name in names {
            let key = ResourceScope.fold(name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append((value: name, label: name))
        }
        return entries
    }

    /// The `context/enumerate` entries for a *leaf* field (`calendars`,
    /// `reminder_lists`, `contact_groups`), filtered to the containers the
    /// operator has already chosen.
    ///
    /// **An empty or absent filter means ALL, never none.** That is the
    /// picker's normal initial state -- the dependent field is opened before
    /// its dependency has been chosen -- so reading an empty-but-present
    /// filter as "match nothing" shows an operator zero calendars everywhere
    /// at exactly the moment they are trying to choose one, and is
    /// indistinguishable from a host that holds none. Note this is the
    /// opposite of decision 4's rule for a *scope value*, where empty is a
    /// refusal, and the two are not in tension: a scope value is an
    /// authorisation and must fail closed, while a picker filter is a query
    /// and must fail informative. macMCP got this wrong once already during
    /// the mail work, which is why it is stated here rather than left to each
    /// caller.
    ///
    /// Duplicate paths collapse to one entry. Two calendars really sharing a
    /// source and a title are indistinguishable *by this representation*, so
    /// offering the same string twice would suggest a choice the value cannot
    /// express; one entry says truthfully what selecting it would select.
    /// `ambiguousValues` is how phase 2 finds out that it selects two.
    static func entries(
        fromRows rows: [Row],
        containerFilter: [String]?
    ) -> [(value: String, label: String)] {
        let wanted: Set<String>? = (containerFilter?.isEmpty == false)
            ? Set(containerFilter!.map(ResourceScope.fold))
            : nil
        var seen: Set<String> = []
        var entries: [(value: String, label: String)] = []
        for row in rows {
            if let wanted, !wanted.contains(ResourceScope.fold(row.container)) { continue }
            let path = row.path
            let key = ResourceScope.fold(path)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append((value: path, label: "\(row.leaf) (\(row.container))"))
        }
        return entries
    }

    /// The paths carried by more than one row -- the values that cannot say
    /// which resource an operator meant.
    ///
    /// Phase 2's ambiguity refusal reads this: ADR-011's mailbox rule is that
    /// two carriers of one name is **refused with both named**, because filing
    /// into one of two is a coin toss the response cannot show. Enumeration
    /// deliberately does not refuse -- an operator must still be able to see
    /// what is on the host -- so the detection lives in a seam both can call.
    static func ambiguousValues(in rows: [Row]) -> [String] {
        var counts: [String: (path: String, count: Int)] = [:]
        for row in rows {
            let key = ResourceScope.fold(row.path)
            counts[key] = (path: row.path, count: (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.filter { $0.count > 1 }.map(\.path).sorted()
    }
}
