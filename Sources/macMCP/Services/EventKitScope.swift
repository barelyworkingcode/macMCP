import Foundation

/// ADR-011's reconciliation rule for a service whose resources are
/// **(container, leaf) rows**: EventKit's calendars and its reminder lists.
///
/// `MailScope.swift` is the same rule for mail, and the two are deliberately
/// not one file. Mail reconciles inside generated JavaScript, against an object
/// graph it can only reach through Apple Events, and its arguments are strings
/// Mail itself resolves; EventKit hands back an array of objects in one call,
/// so the whole of the rule is a function from rows and a scope to a set of row
/// indices. What they share -- `fold`, `names`, `Access`, `refusalNoValue`, the
/// presence check -- is already in `ResourceScope`, which neither of them
/// modifies.
///
/// **Indices rather than rows or objects.** The caller reads
/// `store.calendars(for:)` once, maps it to rows positionally, and gets back
/// positions; so the framework objects the handler acts on are the very ones
/// the scope was decided against, and two calendars that generate the same
/// `Source/Title` path stay two things rather than collapsing into one. That
/// collapse is not hypothetical -- it is what `ScopePath.ambiguousValues`
/// exists to report -- and a seam that returned paths would have to guess which
/// object a path meant, which is the bug this whole representation replaced.
///
/// **Nothing here touches EventKit.** That is what makes it testable: the
/// framework read is one line in each handler, and every way the rule can be
/// wrong is reachable from a literal array of rows.
enum ScopedRows {
    /// The words one service's refusals are written in.
    ///
    /// Written here rather than at each refusal so a sentence cannot drift
    /// between two tools of one service, and passed in rather than switched on
    /// so this file names neither "calendar" nor "reminder list" in any branch.
    struct Fields {
        /// `calendar_accounts` / `reminder_accounts`.
        let containerField: String
        /// "calendar account" / "reminder account", singular.
        let containerNoun: String
        /// `calendars` / `reminder_lists`.
        let leafField: String
        /// "calendar" / "reminder list", singular.
        let leafNoun: String
        /// The tool argument that names one: `calendar_name` / `list_name`.
        let argument: String
        /// The enumerating tool a caller gets real values from.
        let listTool: String
    }

    /// What a scope admits, before any argument has been reconciled against it.
    ///
    /// Four states, and collapsing any two of them loses something ADR-011
    /// requires be kept apart. `.unscoped` is "nobody mediated this call", which
    /// must behave exactly as macMCP always has. `.refused` is decision 4's
    /// absent-or-empty refusal, which is a scope violation. `.misconfigured` is
    /// decision 11's operator typo, which is an error and explicitly **not** a
    /// violation, so a mistyped calendar name cannot fill the signal a client
    /// probing a boundary belongs in. `.confined` is the answer.
    enum RowScope: Equatable {
        case unscoped
        case confined([Int])
        case refused(String)
        case misconfigured(String)

        /// The indices to reconcile arguments against, or `nil` for unscoped.
        /// Only meaningful once the two refusing cases have been answered.
        var indices: [Int]? {
            switch self {
            case .unscoped: return nil
            case .confined(let indices): return indices
            case .refused, .misconfigured: return []
            }
        }
    }

    /// What one argument resolved to.
    ///
    /// `ResourceScope.Decision` is deliberately not reused. Its `.refuse` means
    /// "always a scope violation", and three of the five answers here are not
    /// violations at all: a name that is on no calendar in this Mac is a caller
    /// mistake, an ambiguous name is a request that cannot be carried out, and
    /// a scope with no way to pick a default is a configuration the caller can
    /// work around by naming one. Squeezing them into `.refuse` would tag every
    /// one of them `scope_violation: true`, which is the same conflation
    /// decision 11 refuses one level up.
    enum RowMatch: Equatable {
        /// Proceed, on these rows.
        case rows([Int])
        /// No resource of this kind carries that name at all -- `errorResult`.
        case notFound(String)
        /// More than one does, and nothing in the request says which --
        /// `errorResult`.
        case ambiguous(String)
        /// The argument was omitted and the scope cannot pick for the caller
        /// -- `errorResult`. Nothing was probed, so this is not a violation.
        case needsChoice(String)
        /// One carries that name, and it is outside the scope --
        /// `scopeViolationResult`.
        ///
        /// ADR-011 decision 11: a found-but-out-of-scope resource is a refusal
        /// and not a "not found", because saying "not found" is
        /// indistinguishable from a real miss and leaves an operator with
        /// nothing to debug. The disclosure -- that *some* calendar carries
        /// that name -- is the accepted cost, and the sentence never says which
        /// account holds it.
        case outOfScope(String)
    }

    // MARK: - Which rows a scope admits

    /// The cross-product ADR-011's worked example describes, applied to rows.
    ///
    /// Accounts `[iCloud]` with calendars `[iCloud/Work]` means the calendars
    /// in those accounts that are also in that list. The account field is not
    /// redundant beside the leaf field: it is what an operator narrows the
    /// picker with, and it is the field that governs a tool taking no leaf
    /// argument at all.
    ///
    /// **An empty intersection is a misconfiguration, never an empty result.**
    /// Returning `[]` here would make `calendars_list` answer a confined client
    /// with `[]` and `isError: false` -- an affirmative claim that this Mac
    /// holds no calendar the client may reach, which is the same shape as the
    /// `total_messages: 0` the mail scan work removed. Which of the two
    /// mistakes was made is named: a value naming something this Mac does not
    /// hold, or two values that hold nothing in common.
    ///
    /// **One scope value admits at most one resource, and a value that names
    /// two admits NEITHER.** This walks the scope's values and counts their
    /// carriers, rather than walking the rows and keeping every row a value
    /// matches, and the difference is a real hole rather than a style: two
    /// reminder lists both called `ZSECDUP` under `Default` gave
    /// `reminder_lists: ["Default/ZSECDUP"]` the contents of **both**, every
    /// row labelled `list_path: "Default/ZSECDUP"`, and the operator saw one
    /// entry in the picker because `ScopePath.entries` dedupes by path. Two
    /// `Work` calendars in one account -- an import, or a shared-calendar
    /// subscription -- do the same, which is the very collapse the
    /// `Source/Title` path work was introduced to fix one level up.
    ///
    /// `ScopePath.ambiguousValues` had reported this condition for the
    /// picker since it was written, and its own doc-comment said the
    /// enforcement read it. Nothing did. It is read here now, in the sense
    /// that this is the enforcement half of that pair; `ContactsScope` has
    /// answered the same way since it was written (`ContactScope.select` puts
    /// a two-carrier value in `ambiguous` and contributes no group), and the
    /// two services disagreeing about what one permission value means is
    /// worse than either answer.
    ///
    /// The whole call is refused rather than the ambiguous value being
    /// dropped from an otherwise usable scope, for the reason contacts
    /// refuses: a profile that reads as granting three calendars and silently
    /// grants two is a confinement an operator cannot review. It is
    /// `.misconfigured` and not `.refused` -- nobody probed anything, two
    /// resources were given one name -- so it stays out of the security
    /// signal, exactly as decision 11 requires.
    static func allowed(
        rows: [ScopePath.Row],
        containers: ResourceScope.Access,
        leaves: ResourceScope.Access,
        fields: Fields
    ) -> RowScope {
        // `access` answers `.unscoped` for every field of an unmediated call,
        // so a mixed pair cannot occur; reading either one is enough.
        if case .unscoped = containers { return .unscoped }
        if case .unscoped = leaves { return .unscoped }

        // Belt-and-braces. `presenceRefusal` turns these into a refusal in the
        // handler, before EventKit is touched. Mapping them to "no restriction"
        // here anyway is the mistake `MailService.allowedList` documents: one
        // missing check at one call site must not be able to widen a
        // confinement into its opposite.
        if case .refuse = containers {
            return .refused(ResourceScope.refusalNoValue(
                field: fields.containerField, noun: fields.containerNoun))
        }
        if case .refuse = leaves {
            return .refused(ResourceScope.refusalNoValue(
                field: fields.leafField, noun: fields.leafNoun))
        }

        // Confirmed-empty on either axis makes the cross-product empty by
        // construction, whatever the other axis says -- an operator who
        // explicitly confirmed "nothing here" for one has already answered
        // the whole question. `.confined([])`, not `.misconfigured`: this was
        // reviewed, not omitted, and `calendars_list` etc. should answer `[]`
        // rather than error.
        //
        // This used to be `guard case .allowed(let a) = containers, case
        // .allowed(let b) = leaves else { return .unscoped }` -- a shape
        // whose `else` was safe only because `.unscoped` and `.refuse` were
        // the sole other states, and both were already peeled off above.
        // `.unrestricted` and `.confirmedEmpty` are two more states that
        // reach that same `else`, and `.unscoped` is the wrong answer for
        // both (fail-open: unrestricted on *every* axis rather than the one
        // that earned it). Written as two exhaustive switches instead, so a
        // future case fails to compile here rather than falling through.
        if case .confirmedEmpty = containers { return .confined([]) }
        if case .confirmedEmpty = leaves { return .confined([]) }

        let wantContainers: Set<String>?
        switch containers {
        case .unscoped, .refuse, .confirmedEmpty:
            // Handled above; kept so the switch is exhaustive against a case
            // added to `Access` later.
            return .refused(ResourceScope.refusalNoValue(
                field: fields.containerField, noun: fields.containerNoun))
        case .unrestricted:
            wantContainers = nil
        case .allowed(let containerValues):
            wantContainers = Set(containerValues.map(ResourceScope.fold))
        }
        // The container half first, because a leaf value is only reachable
        // through an account the scope also names -- the cross-product, which
        // is the direction that narrows. `wantContainers == nil` is
        // `.unrestricted`: nothing to resolve, so nothing filters.
        let inContainers = rows.indices.filter {
            wantContainers == nil || wantContainers!.contains(ResourceScope.fold(rows[$0].container))
        }

        let leafValues: [String]
        switch leaves {
        case .unscoped, .refuse, .confirmedEmpty:
            return .refused(ResourceScope.refusalNoValue(field: fields.leafField, noun: fields.leafNoun))
        // Every row already admitted by the container half is admitted,
        // full stop -- no per-value lookup, so no per-value ambiguity to
        // check either.
        case .unrestricted:
            return .confined(inContainers.sorted())
        case .allowed(let values):
            leafValues = values
        }

        var admitted: Set<Int> = []
        var ambiguous: [String] = []
        for value in leafValues {
            let needle = ResourceScope.fold(value)
            let carriers = inContainers.filter { ResourceScope.fold(rows[$0].path) == needle }
            if carriers.count > 1 {
                if !ambiguous.contains(value) { ambiguous.append(value) }
                continue
            }
            // Zero carriers is not reported here: `misconfiguration` already
            // names every value this Mac does not hold, and it says it in the
            // operator's terms.
            admitted.formUnion(carriers)
        }
        if !ambiguous.isEmpty {
            return .misconfigured(ambiguousScope(ambiguous, fields: fields))
        }
        // Sorted so the admitted set is in EventKit's own order whatever
        // order the scope named its values in: this list is what
        // `calendars_list` reports and what every refusal prints as "it may
        // reach", and neither should reshuffle when an operator edits a
        // profile.
        let indices = admitted.sorted()
        if indices.isEmpty {
            guard case .allowed(let containerValues) = containers else {
                // `.unrestricted` containers with an `.allowed` (but
                // non-matching) leaves value: every row is in `inContainers`
                // by construction, so an empty `indices` here means no row's
                // path matched any leaf value -- a leaf typo, not a missing
                // container.
                return .misconfigured(misconfiguration(
                    rows: rows, containerValues: rows.map(\.container),
                    leafValues: leafValues, fields: fields))
            }
            return .misconfigured(misconfiguration(
                rows: rows, containerValues: containerValues,
                leafValues: leafValues, fields: fields))
        }
        return .confined(indices)
    }

    /// What an operator is told when one of their values names two resources.
    ///
    /// It names the value rather than the two resources, because they are the
    /// same string -- printing it twice would suggest a choice between them
    /// that no value, and no tool argument, can express. The remedy is
    /// therefore in the app that owns them and nowhere else, which is what
    /// `ambiguityMessage` says for the same condition met from the other
    /// side.
    private static func ambiguousScope(_ values: [String], fields: Fields) -> String {
        "the \(fields.leafNoun) scope this call carries is not usable: "
        + values.map {
            "`\(fields.leafField)` entry \"\($0)\" names more than one \(fields.leafNoun)"
        }.joined(separator: "; ")
        + ". Nothing was read or written. Two \(fields.leafNoun)s filed under one account with "
        + "one name cannot be told apart by an Account/Name value, so reading one of them would "
        + "be a guess and reading both would grant more than the value says. Rename one of them "
        + "in the app that owns it, or remove it — there is no scope value and no "
        + "`\(fields.argument)` that selects one of two."
    }

    /// Why a scope admitted nothing, in the operator's terms rather than the
    /// client's -- this sentence is read by whoever wrote the access profile.
    private static func misconfiguration(
        rows: [ScopePath.Row],
        containerValues: [String],
        leafValues: [String],
        fields: Fields
    ) -> String {
        let haveContainers = Set(rows.map { ResourceScope.fold($0.container) })
        let havePaths = Set(rows.map { ResourceScope.fold($0.path) })
        let missingContainers = containerValues.filter { !haveContainers.contains(ResourceScope.fold($0)) }
        let missingLeaves = leafValues.filter { !havePaths.contains(ResourceScope.fold($0)) }

        let tail = " Nothing was read or written. This is a configuration mistake rather than a "
            + "refusal, and a client cannot do anything about it: the values come from "
            + "\(fields.listTool), or from macMCP's own picker, and must be written exactly as "
            + "that reports them."

        if missingContainers.isEmpty && missingLeaves.isEmpty {
            return "the \(fields.leafNoun) scope this call carries grants nothing: "
                + "`\(fields.containerField)` names \(quoted(containerValues)) and "
                + "`\(fields.leafField)` names \(quoted(leafValues)), and no \(fields.leafNoun) on "
                + "this Mac is in both. The two fields combine as a cross-product, so a "
                + "\(fields.leafNoun) is reachable only when its account is listed too." + tail
        }
        var named: [String] = []
        if !missingContainers.isEmpty {
            named.append("`\(fields.containerField)` names \(quoted(missingContainers)), which is "
                + "not a \(fields.containerNoun) on this Mac")
        }
        if !missingLeaves.isEmpty {
            named.append("`\(fields.leafField)` names \(quoted(missingLeaves)), which is not a "
                + "\(fields.leafNoun) on this Mac")
        }
        return "the \(fields.leafNoun) scope this call carries is not usable: "
            + named.joined(separator: ", and ") + "." + tail
    }

    private static func quoted(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    // MARK: - Reconciling an explicit argument

    /// ADR-011's rule for an argument the caller actually wrote.
    ///
    /// The two-step is the mailbox one: a value is matched against the **paths**
    /// first, and only then against bare **leaf names**, so `Trash` means the
    /// account's own Trash rather than `Projects/Trash` and a bare name is a
    /// path with one component. A leaf name that only one row carries still
    /// works, because refusing it would make every existing caller of
    /// `calendar_name: "Work"` an error for no gain when there is only one
    /// Work; two carriers is refused **with both named**, exactly as
    /// `mail_move` refuses two same-named mailboxes, because acting on one of
    /// two is a coin toss the response cannot show.
    ///
    /// **Matching runs inside the scope first.** With `calendars: [iCloud/Work]`
    /// on a Mac that also holds `Exchange/Work`, `calendar_name: "Work"` is not
    /// ambiguous -- only one of the two is reachable, so there is nothing to
    /// choose between. Only when nothing in scope carries the name are all rows
    /// consulted, and then solely to tell decision 11's two answers apart: a
    /// name on a real out-of-scope calendar is a violation, a name on nothing
    /// at all is a plain miss.
    static func resolve(
        _ requested: String,
        rows: [ScopePath.Row],
        allowed: [Int]?,
        fields: Fields
    ) -> RowMatch {
        let needle = ResourceScope.fold(requested)
        let byPath = rows.indices.filter { ResourceScope.fold(rows[$0].path) == needle }
        let byLeaf = rows.indices.filter { ResourceScope.fold(rows[$0].leaf) == needle }

        func pick(_ pool: Set<Int>) -> [Int] {
            let paths = byPath.filter(pool.contains)
            if !paths.isEmpty { return paths }
            return byLeaf.filter(pool.contains)
        }

        guard let allowed else {
            let candidates = pick(Set(rows.indices))
            if candidates.isEmpty { return .notFound(notFoundMessage(requested, fields: fields)) }
            if candidates.count > 1 {
                return .ambiguous(ambiguityMessage(requested, candidates, rows: rows, fields: fields))
            }
            return .rows(candidates)
        }

        let inScope = pick(Set(allowed))
        if !inScope.isEmpty {
            if inScope.count > 1 {
                return .ambiguous(ambiguityMessage(requested, inScope, rows: rows, fields: fields))
            }
            return .rows(inScope)
        }
        if !pick(Set(rows.indices)).isEmpty {
            return .outOfScope(
                "\(fields.leafNoun) \"\(requested)\" is outside the \(fields.leafNoun)s this client "
                + "may reach. It may reach: \(allowed.map { rows[$0].path }.joined(separator: ", ")). "
                + "Omit `\(fields.argument)` to use every \(fields.leafNoun) it may reach."
            )
        }
        return .notFound(notFoundMessage(requested, fields: fields))
    }

    private static func notFoundMessage(_ requested: String, fields: Fields) -> String {
        "no \(fields.leafNoun) named \"\(requested)\" on this Mac. A \(fields.leafNoun) is named "
        + "Account/Name — \(fields.listTool) reports the exact strings — and a bare name works "
        + "only when one \(fields.leafNoun) carries it."
    }

    /// Two shapes of ambiguity, and they are not the same problem.
    ///
    /// A bare name carried by two rows is answered by naming the paths, which
    /// the caller can then pass. Two rows carrying the *same path* cannot be
    /// told apart by any argument this tool takes, so the sentence says that
    /// rather than printing one string twice and inviting a retry that lands in
    /// the same place. `ScopePath.ambiguousValues` reports the same condition
    /// for the operator's picker.
    private static func ambiguityMessage(
        _ requested: String,
        _ candidates: [Int],
        rows: [ScopePath.Row],
        fields: Fields
    ) -> String {
        let paths = candidates.map { rows[$0].path }
        let distinct = Set(paths.map(ResourceScope.fold))
        if distinct.count == paths.count {
            return "\(fields.leafNoun) \"\(requested)\" is ambiguous: \(paths.count) "
                + "\(fields.leafNoun)s carry that name — \(quoted(paths)). Name one of those in "
                + "full. A bare name is not an identity here, and acting on both is not something "
                + "the answer could show you."
        }
        // **The advice has to be something an operator can carry out.** This
        // used to end "or narrow the scope to the one this client should
        // reach", and there is no such scope: a `\(fields.leafField)` value is
        // the same `Account/Name` path both of these carry, so it selects
        // both or neither -- which is why `allowed` refuses such a value
        // outright rather than admitting two resources under one name. The
        // only place the two can be told apart is the app that owns them.
        return "\(fields.leafNoun) \"\(requested)\" cannot be resolved: \(paths.count) "
            + "\(fields.leafNoun)s on this Mac are all filed as \"\(paths[0])\", and nothing in a "
            + "request can tell them apart. Rename one of them in the app that owns it, or remove "
            + "it. Narrowing the scope cannot help: `\(fields.leafField)` takes that same path, so "
            + "a scope naming it is refused for this reason too."
    }

    // MARK: - The argument that was not passed

    /// What a **write** does when the caller named nothing and the framework
    /// has a default of its own.
    ///
    /// EventKit answers `defaultCalendarForNewEvents` /
    /// `defaultCalendarForNewReminders()` regardless of any scope, and writing
    /// there is how a confined client silently puts an event on a calendar its
    /// profile never granted. So a scoped write resolves to the scope or
    /// refuses -- the same shape as mail refusing a `from` no account owns
    /// rather than letting Mail substitute the default account.
    ///
    /// Preferring the default *when it is in scope* is the reconciliation rule
    /// and not a concession: an absent argument resolves to the scope, and a
    /// default that is inside the scope satisfies it, so an operator who
    /// granted the calendar the user already writes to gets exactly what they
    /// meant. A scope of exactly one calendar (or list) also resolves, because
    /// there is only one answer. Anything else is a choice this call cannot make, and
    /// making it would be picking a calendar for the caller out of several --
    /// so it asks, naming them, which the caller can act on immediately.
    static func defaultTarget(
        defaultIndex: Int?,
        allowed: [Int],
        rows: [ScopePath.Row],
        fields: Fields
    ) -> RowMatch {
        if let defaultIndex, allowed.contains(defaultIndex) { return .rows([defaultIndex]) }
        if allowed.count == 1 { return .rows(allowed) }
        let paths = allowed.map { rows[$0].path }
        return .needsChoice(
            "this client may reach \(paths.count) \(fields.leafNoun)s — \(quoted(paths)) — and this "
            + "Mac's default \(fields.leafNoun) is not one of them, so there is nothing to write to "
            + "by default. Pass `\(fields.argument)` naming one of them. macMCP will not write to "
            + "the default \(fields.leafNoun) instead: an event filed somewhere the access profile "
            + "never granted is worse than a refusal the caller can answer."
        )
    }

    // MARK: - Where a globally-found resource ended up

    /// Whether a (container, leaf) pair a framework object reports is one the
    /// scope admits.
    ///
    /// `reminders_complete` matches on a title across every list, which is the
    /// same shape as mail's `messages.byId` resolving globally: the handle does
    /// not carry the scope, so where the thing *is* has to be read back off it
    /// and checked. Comparing the path rather than the leaf is the other half
    /// of that lesson -- every account has a `Reminders`, so a leaf-name
    /// comparison would admit another account's list.
    static func admits(container: String, leaf: String, allowed: [Int], rows: [ScopePath.Row]) -> Bool {
        let path = ResourceScope.fold(ScopePath.Row(container: container, leaf: leaf).path)
        return allowed.contains { ResourceScope.fold(rows[$0].path) == path }
    }
}
