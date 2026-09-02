import Foundation

/// The contacts resource scope a caller's `_meta` carries, per ADR-011
/// ("A Client Is an Identity, an Access Profile, and a Resource Scope").
///
/// `MailScope.swift` is the worked example this follows: the mechanism
/// (`Access`, `Decision`, `fold`, `presenceRefusal`, the cache fingerprint)
/// lives in `ResourceScope`; what lives here is only what a *contacts* scope
/// means -- which `_meta` keys it reads, and how ADR-011's reconciliation rule
/// applies to a contacts argument.
///
/// ## What the two fields mean, and why they do not bound the same thing
///
/// `contact_accounts` names containers (`CNContainer`); `contact_groups` names
/// groups inside them, written `Account/Group` and matched whole (`ScopePath`).
///
/// The first pass gave both fields `applies_to: ["contacts_*"]`, copying mail's
/// shape, and enforced exactly that: a card was reachable only as a *member of
/// a group in scope*. The asymmetry that makes it wrong is one sentence long --
/// **a message is always in a mailbox; a card need not be in a group** -- and
/// its consequence is not a tighter confinement but a missing one. With both
/// fields required everywhere, "every card in this account, group or not" was
/// not expressible at all, so an operator could grant only the cards somebody
/// had remembered to file, and a card in no group was unreachable through a
/// profile that named its account. The declaration was wrong; the enforcement
/// was a faithful implementation of it.
///
/// So the two fields bound different things:
///
/// * **`contact_accounts` bounds cards.** A card is reachable when its
///   container is named. `contacts_list`, `contacts_get`,
///   `contacts_search_by_phone`, `contacts_update`, `contacts_delete` and
///   `contacts_create` are confined by this and by nothing else.
/// * **`contact_groups` bounds groups**, and only the four tools that list,
///   create or change the membership of one. A group is reachable when its
///   path is named *and* its container is named in `contact_accounts` -- the
///   same cross-product `mail_accounts`/`mail_mailboxes` form, one level down,
///   and the direction that narrows: naming `iCloud/Family` without naming
///   `iCloud` selects nothing.
///
/// **Both ends of a membership change are still checked, and the contact end
/// is the one that is easy to miss.** `contacts_add_to_group` needs the group
/// (both fields) *and* the card (its account). A client that could add any card
/// in the address book to a group it holds would be able to read that card on
/// the next call -- widening its own scope by writing rather than by being
/// granted anything, which is escalation rather than the exfiltration ADR-011's
/// threat model is mostly about. That reasoning is unchanged by the new shape;
/// only the field the contact end is checked against has moved from
/// `contact_groups` to `contact_accounts`.
///
/// **What an account-scoped profile loses is the group tools, and that is
/// exactly what it was granted.** `contacts_list_groups` refuses rather than
/// answering `[]`: decision 4 says an absent grant is a refusal, and an empty
/// list would be an affirmative claim that this Mac holds no group -- the
/// `total_messages: 0` shape the mail work removed.
///
/// ## Unified contacts: a scoped read does not unify
///
/// `CNContactStore.unifiedContacts` and `unifiedContact(withIdentifier:)` merge
/// *linked* cards across containers into one `CNContact`. That is the right
/// answer for a person and the wrong answer for a confinement, for three
/// reasons that are each sufficient on their own:
///
/// 1. **The merged card carries fields from containers the client may not
///    reach.** A card in an in-scope account linked to one in an out-of-scope
///    account yields a single contact whose phone numbers and addresses are the
///    union of both, and `CNContact` exposes no per-value provenance, so there
///    is nothing to subtract afterwards. A "filtered" result that is not
///    actually confined is worse than no filter, because the operator is shown
///    a confinement that does not hold.
/// 2. **"Which container is this contact in" stops having one answer.** The
///    unified contact's `identifier` is one constituent card's, and
///    `CNContainer.predicateForContainerOfContact` answers about that one card,
///    so the check would be made against a part of what was returned.
/// 3. **The handle a caller gets back would not be the thing that was
///    checked.** An id from a unified read can resolve to a different card's
///    container on the next call.
///
/// So **every read made under a scope sets `unifyResults = false`** and works in
/// raw per-container cards, where each card has exactly one container and
/// exactly one set of group memberships. The cost is visible and honest: a
/// person the user has linked across two accounts appears as two cards, one per
/// account, and only the in-scope ones appear at all. An **unscoped** call --
/// `_meta` absent, nobody mediated, macmcp on a bare stdio pipe -- keeps
/// unifying exactly as it always has, because there is no boundary for a merge
/// to cross.
///
/// The alternative considered and rejected was refusing the contacts tools
/// outright whenever a scope is in play, on the grounds that unification makes
/// them unenforceable. It does not: turning unification off removes the hazard
/// entirely rather than mitigating it, and refusing a tool that *can* be
/// confined would be a capability lost for nothing. `contacts_create_group` is
/// the one tool that genuinely cannot be reconciled with a `contact_groups`
/// value, and that one is refused (see `ContactsService.contactsCreateGroup`,
/// where the reasoning is re-derived for the account/group split rather than
/// inherited from the shape that preceded it).
extension ResourceScope {
    /// `nil` means the request's `_meta` had no `contact_accounts` key at all
    /// (or carried one whose value was not a string or an array of strings).
    /// A present-but-empty array is a distinct, equally-refusing state.
    var contactAccountsValues: [String]? { values(of: "contact_accounts") }

    /// Same contract as `contactAccountsValues`, for `contact_groups`.
    var contactGroupsValues: [String]? { values(of: "contact_groups") }

    /// The two questions a contacts enforcer asks, named. Kept distinct from
    /// mail's `accountsAccess` rather than folded into it: one call carries one
    /// scope, but the fields are separate grants and a profile may hold one
    /// without the other.
    var contactAccountsAccess: Access { access("contact_accounts") }
    var contactGroupsAccess: Access { access("contact_groups") }

    /// The accounts this call may reach, reconciled against the containers this
    /// Mac actually holds.
    ///
    /// **This is the bound on cards, and every contacts tool runs it.**
    /// `.unscoped` means nobody mediated the call and every tool must behave
    /// exactly as it always has; `.use` carries the effective containers, whose
    /// cards are the only cards in play; `.refuse` is a scope violation;
    /// `.misconfigured` is an operator's typo, which ADR-011 decision 11 keeps
    /// out of the security signal a client's probe belongs in.
    ///
    /// An account value is a plain container name and not a path -- it *is* the
    /// container of every path -- so there is no leaf to guess about. It can
    /// still be ambiguous, and not academically: `ContactsService.containerName`
    /// falls back to the container's **type** when `CNContainer.name` is empty,
    /// which macOS routinely leaves it, so two CardDAV accounts can both be
    /// called `CardDAV`. A value carrying two containers is refused rather than
    /// resolved to both, for the reason a two-carrier group path is: a value
    /// that selects two of something grants more than the operator could see it
    /// granting.
    func contactAccountTargets(catalog: [ContactAccountRef]) -> Decision<[ContactAccountRef]> {
        guard isScoped else { return .unscoped }
        let accounts: [String]
        // Exhaustive rather than `guard case .allowed(...) else { .refuse(...) }`:
        // that shape's `else` is the right answer for `.refuse` (which
        // reaches here only as belt-and-braces; `presenceRefusal` already
        // caught it) but the wrong one for `.unrestricted` and
        // `.confirmedEmpty`, both live states now.
        switch contactAccountsAccess {
        case .unscoped, .refuse:
            return .refuse(ResourceScope.refusalNoValue(field: "contact_accounts", noun: "contact account"))
        // Every account this Mac holds -- nothing to resolve, so the whole
        // catalog is the answer with no per-value lookup.
        case .unrestricted:
            return .use(catalog)
        // Zero accounts in scope. `.use([])`, not `.refuse`: this was
        // reviewed, and every card tool should answer emptily rather than
        // error -- `contacts_list` returns `[]`, not a violation.
        case .confirmedEmpty:
            return .use([])
        case .allowed(let allowed):
            accounts = allowed
        }
        let selection = ContactScope.select(containers: catalog, accounts: accounts)
        if !selection.ambiguous.isEmpty {
            return .misconfigured(
                "the contact scope this call carries is not usable: "
                + selection.ambiguous.map { "`contact_accounts` entry \"\($0)\" names more than one account" }
                    .joined(separator: "; ")
                + ". Nothing was read or written. Two contact accounts of one name cannot be told "
                + "apart by a name, so reading one of them would be a guess and reading both would "
                + "grant more than the value says. Name the accounts distinctly in Contacts."
            )
        }
        guard !selection.accounts.isEmpty else {
            return .misconfigured(
                "the contact scope this call carries reaches no account on this Mac: "
                + "`contact_accounts` names \(accounts.joined(separator: ", ")), and no contact "
                + "account of that name exists here. Nothing was read or written. This is a "
                + "configuration mistake rather than a refusal: the values come from "
                + "contacts_list_groups, or from macMCP's own picker, and must be written exactly "
                + "as that reports them."
            )
        }
        return .use(selection.accounts)
    }

    /// The groups this call may reach, reconciled against what this Mac
    /// actually holds.
    ///
    /// **This is the bound on groups, and only the four group tools run it** --
    /// `contacts_list_groups`, `contacts_create_group`, `contacts_add_to_group`
    /// and `contacts_remove_from_group`, which are exactly the tools
    /// `contact_groups` declares in its `applies_to`. A card tool never asks
    /// this question, because a card is bounded by its account and may be in no
    /// group at all.
    ///
    /// A scope value is matched as a **path** and never as a bare group name.
    /// The value comes out of `context/enumerate`'s picker, which emits paths;
    /// a hand-typed `Family` is reported as naming no group rather than
    /// silently resolving to whichever account's `Family` came first, which is
    /// the mailbox lesson (CLAUDE.md: "a leaf name does not identify a mailbox;
    /// the path does") in the one place where guessing would widen a grant.
    ///
    /// A value naming **two** groups -- which Contacts.app permits, two groups
    /// of one name in one account -- is refused rather than resolved, for the
    /// same reason `mail_move` refuses two mailboxes carrying one name: acting
    /// on one of two is a coin toss the response cannot show.
    func contactGroupTargets(catalog: [ContactGroupRef]) -> Decision<[ContactGroupRef]> {
        guard isScoped else { return .unscoped }
        // The account half, resolved first -- the cross-product's narrowing
        // direction. `.unrestricted` is passed through as "every account
        // this group catalog carries" rather than resolved against a
        // separate account catalog: nobody needs to be read, since
        // `ContactScope.select`'s own account filter (`ResourceScope.names`)
        // is then trivially true for every row.
        let accounts: [String]
        switch contactAccountsAccess {
        case .unscoped, .refuse:
            return .refuse(ResourceScope.refusalNoValue(field: "contact_accounts", noun: "contact account"))
        case .unrestricted:
            accounts = catalog.map(\.account)
        case .confirmedEmpty:
            return .use([])
        case .allowed(let allowed):
            accounts = allowed
        }
        let groups: [String]
        switch contactGroupsAccess {
        case .unscoped, .refuse:
            return .refuse(ResourceScope.refusalNoValue(field: "contact_groups", noun: "contact group"))
        // Every group in an in-scope account -- no per-value lookup, so no
        // per-value ambiguity to check either.
        case .unrestricted:
            return .use(catalog.filter { ResourceScope.names($0.account, oneOf: accounts) })
        case .confirmedEmpty:
            return .use([])
        case .allowed(let allowed):
            groups = allowed
        }
        let selection = ContactScope.select(catalog: catalog, accounts: accounts, groups: groups)
        if !selection.ambiguous.isEmpty {
            return .misconfigured(
                "the contact scope this call carries is not usable: "
                + selection.ambiguous.map { "`contact_groups` entry \"\($0)\" names more than one group" }
                    .joined(separator: "; ")
                + ". Nothing was read or written. Two groups of one name in one account cannot be told "
                + "apart by an Account/Group value, so acting on one of them would be a guess. Rename "
                + "one of them in Contacts, or narrow the account this profile names."
            )
        }
        guard !selection.groups.isEmpty else {
            return .misconfigured(
                "the contact scope this call carries reaches no group on this Mac: `contact_groups` "
                + "names \(groups.joined(separator: ", ")) and `contact_accounts` names "
                + "\(accounts.joined(separator: ", ")), and no group with one of those paths exists in "
                + "one of those accounts. Nothing was read or written. This is a configuration mistake "
                + "rather than a refusal: a group is written as Account/Group (for example "
                + "\"iCloud/Family\"), and both halves must match a group Contacts actually holds."
            )
        }
        return .use(selection.groups)
    }
}

// MARK: - What an account is, to a scope

/// A contact account (a `CNContainer`) as a scope value sees it: the
/// operator-facing name that *is* the `contact_accounts` value, and the handle
/// a fetch is predicated on.
///
/// Pure data for the same reason `ContactGroupRef` is: `ContactScope.select`
/// is the whole reconciliation rule and takes a list of these rather than a
/// `CNContactStore`, which is what lets the rule be tested without touching
/// the user's address book.
struct ContactAccountRef: Equatable {
    /// `ContactsService.containerName(container)` -- the name an operator picks
    /// and the first half of every `Account/Group` path.
    let name: String
    /// `CNContainer.identifier`, which is what a card fetch is predicated on
    /// and what a create is filed into. Deliberately not the scope value, for
    /// the reasons `ContactsService.groupRows` states about UUIDs.
    let identifier: String

    init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}

// MARK: - What a group is, to a scope

/// A contact group as a scope value sees it: which account it is filed under,
/// what it is called, and the two framework handles needed to act on it.
///
/// Pure data on purpose -- `ContactScope.select` is the whole reconciliation
/// rule and takes one of these lists rather than a `CNContactStore`, which is
/// what lets the rule be tested without touching the user's address book. The
/// framework read that builds the list (`ContactsService.groupCatalog`) does
/// nothing but read.
struct ContactGroupRef: Equatable {
    /// The container's operator-facing name (`ContactsService.containerName`),
    /// which is the first half of the scope value.
    let account: String
    /// `CNGroup.name`, the second half.
    let name: String
    /// `CNGroup.identifier`. The handle `contacts_add_to_group` is called with
    /// and the one a member fetch is predicated on -- deliberately not the
    /// scope value, for the reasons `ContactsService.groupRows` states at
    /// length (a UUID cannot be reviewed in an audit line or a profile).
    let identifier: String
    /// `CNContainer.identifier`, so a create can be filed in the same container
    /// as the group it is going into.
    let containerIdentifier: String

    init(account: String, name: String, identifier: String, containerIdentifier: String = "") {
        self.account = account
        self.name = name
        self.identifier = identifier
        self.containerIdentifier = containerIdentifier
    }

    /// The scope value, `Account/Group`, built by the one function that builds
    /// every such path so a calendar, a reminder list and a group cannot drift
    /// into three spellings.
    var path: String { ScopePath.Row(container: account, leaf: name).path }

    var row: ScopePath.Row { ScopePath.Row(container: account, leaf: name) }
}

/// The reconciliation rule for contacts, as pure functions.
enum ContactScope {
    /// What a scope selected out of the groups this Mac holds.
    ///
    /// `unknown` and `ambiguous` are kept rather than collapsed into the
    /// selection because they are different events with different audiences:
    /// an operator's typo belongs in relay's editor, a coin-toss between two
    /// groups belongs in a refusal.
    struct Selection: Equatable {
        /// The effective groups: listed in `contact_groups`, and in an account
        /// listed in `contact_accounts`. Deduplicated by group identifier and
        /// in the order the scope named them.
        let groups: [ContactGroupRef]
        /// Scope values matching no group in the accounts in scope.
        let unknown: [String]
        /// Scope values matching more than one group.
        let ambiguous: [String]
    }

    /// What a scope selected out of the containers this Mac holds.
    struct AccountSelection: Equatable {
        /// The effective accounts, deduplicated by container identifier and in
        /// the order the scope named them.
        let accounts: [ContactAccountRef]
        /// Scope values matching no container on this Mac.
        let unknown: [String]
        /// Scope values matching more than one container -- two accounts whose
        /// names are equal under `fold`, which `containerName`'s type fallback
        /// makes reachable for two unnamed CardDAV or Exchange containers.
        let ambiguous: [String]
    }

    /// The account half of the scope, applied.
    ///
    /// The same three outcomes as the group half and for the same reasons: a
    /// value naming nothing narrows rather than widening, a value naming two
    /// contributes **neither**, and one account named twice is one account.
    static func select(containers catalog: [ContactAccountRef], accounts: [String]) -> AccountSelection {
        var chosen: [ContactAccountRef] = []
        var seen: Set<String> = []
        var unknown: [String] = []
        var ambiguous: [String] = []
        for value in accounts {
            let needle = ResourceScope.fold(value)
            let matches = catalog.filter { ResourceScope.fold($0.name) == needle }
            if matches.isEmpty {
                if !unknown.contains(value) { unknown.append(value) }
                continue
            }
            if matches.count > 1 {
                if !ambiguous.contains(value) { ambiguous.append(value) }
                continue
            }
            let match = matches[0]
            guard !seen.contains(match.identifier) else { continue }
            seen.insert(match.identifier)
            chosen.append(match)
        }
        return AccountSelection(accounts: chosen, unknown: unknown, ambiguous: ambiguous)
    }

    /// The cross-product, applied.
    ///
    /// **A value naming a group in an account that is not in scope is
    /// `unknown`, not a match.** That is what makes the two fields a
    /// cross-product rather than a union, and it is the direction that
    /// narrows: an operator who lists `iCloud/Family` and forgets to list
    /// `iCloud` gets nothing rather than everything.
    ///
    /// A value that names several groups goes to `ambiguous` and contributes
    /// **no** group -- not the first one, which would be the coin toss, and not
    /// all of them, which would be a value granting more than an operator could
    /// see it granting.
    static func select(catalog: [ContactGroupRef], accounts: [String], groups: [String]) -> Selection {
        let inAccounts = catalog.filter { ResourceScope.names($0.account, oneOf: accounts) }
        var chosen: [ContactGroupRef] = []
        var seen: Set<String> = []
        var unknown: [String] = []
        var ambiguous: [String] = []
        for value in groups {
            let needle = ResourceScope.fold(value)
            let matches = inAccounts.filter { ResourceScope.fold($0.path) == needle }
            if matches.isEmpty {
                if !unknown.contains(value) { unknown.append(value) }
                continue
            }
            if matches.count > 1 {
                if !ambiguous.contains(value) { ambiguous.append(value) }
                continue
            }
            let match = matches[0]
            guard !seen.contains(match.identifier) else { continue }
            seen.insert(match.identifier)
            chosen.append(match)
        }
        return Selection(groups: chosen, unknown: unknown, ambiguous: ambiguous)
    }

    /// The group a caller named, reconciled against the groups in scope.
    ///
    /// ADR-011's rule, applied to a `group` argument: an **absent** argument
    /// resolves to the scope, which is unambiguous when the scope names exactly
    /// one group and is under-specified when it names several; an **explicit**
    /// argument outside the scope is an error carrying `scope_violation`, never
    /// a silent narrowing.
    ///
    /// The under-specified case is deliberately **not** a violation: the caller
    /// reached outside nothing, it simply did not say which of the groups it
    /// holds it meant. Naming them costs no disclosure -- they are the client's
    /// own grant.
    enum GroupChoice: Equatable {
        case chosen(ContactGroupRef)
        /// The argument named something outside the scope. A violation.
        case outside(String)
        /// No argument, and the scope names more than one group. An ordinary
        /// error naming the choices.
        case underSpecified([String])
    }

    /// The account a caller named, reconciled against the accounts in scope.
    ///
    /// The `group` rule, for the field that bounds cards. `contacts_create` is
    /// the one tool that needs it: a card has to be filed *somewhere*, the
    /// framework's default container may be outside the scope, and under
    /// account scoping there is no group to take the container from. Absent
    /// resolves to the scope when the scope names one account; several is
    /// under-specified rather than a guess; an explicit account outside the
    /// scope is a violation.
    ///
    /// There is no leaf-name fallback here, because an account value **is** a
    /// bare name -- there is nothing to fall back from.
    enum AccountChoice: Equatable {
        case chosen(ContactAccountRef)
        case outside(String)
        case underSpecified([String])
    }

    static func choose(account requested: String?, from accounts: [ContactAccountRef]) -> AccountChoice {
        guard let requested, !requested.isEmpty else {
            if accounts.count == 1 { return .chosen(accounts[0]) }
            return .underSpecified(accounts.map(\.name))
        }
        let needle = ResourceScope.fold(requested)
        if let match = accounts.first(where: { ResourceScope.fold($0.name) == needle }) {
            return .chosen(match)
        }
        return .outside(requested)
    }

    static func choose(group requested: String?, from groups: [ContactGroupRef]) -> GroupChoice {
        guard let requested, !requested.isEmpty else {
            if groups.count == 1 { return .chosen(groups[0]) }
            return .underSpecified(groups.map(\.path))
        }
        let needle = ResourceScope.fold(requested)
        if let match = groups.first(where: { ResourceScope.fold($0.path) == needle }) {
            return .chosen(match)
        }
        // A leaf name is accepted as a *caller's argument* only when exactly
        // one group in scope carries it -- the mailbox rule, one level down.
        // Two carriers is not a match, because filing into one of two is a
        // guess the response cannot show; the caller is told to write the path.
        let byLeaf = groups.filter { ResourceScope.fold($0.name) == needle }
        if byLeaf.count == 1 { return .chosen(byLeaf[0]) }
        return .outside(requested)
    }
}
