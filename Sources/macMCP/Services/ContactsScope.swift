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
/// ## What the two fields mean, and why a group bounds a card
///
/// `contact_accounts` names containers (`CNContainer`) and `contact_groups`
/// names groups inside them, written `Account/Group` and matched whole
/// (`ScopePath`). They combine as a **cross-product**, exactly as
/// `mail_accounts` and `mail_mailboxes` do: a group is in scope when its path
/// is listed *and* its container is listed.
///
/// The question that has no mail analogue is what a *card* is confined by. A
/// message is always in a mailbox, so scoping mailboxes scopes messages; a
/// card need not be in any group at all. Two readings were available:
///
/// * **accounts confine cards, groups confine only the group tools.** A
///   profile naming `iCloud/Family` would then still read every card in
///   iCloud. That is the confinement ADR-011 decision 9 forbids -- advertised
///   in relay's editor as "this client may reach Family", held as "this client
///   may reach the whole address book". It is also the exact failure phase 1
///   left open by declaring these fields without enforcing them.
/// * **a card is reachable when it is a member of a group in scope.** Narrower,
///   fail-closed, and it makes the value an operator picked mean what it says.
///
/// The second is what is implemented. **A card in no in-scope group is not
/// reachable at all**, and the whole surface follows from that: `contacts_list`
/// enumerates the in-scope groups' members and never the store;
/// `contacts_get` / `_update` / `_delete` resolve an id against those members;
/// `contacts_create` places the new card in an in-scope group so the client can
/// read back what it wrote; `contacts_add_to_group` requires the card to be in
/// scope *already*, because otherwise a client could add any card in the
/// address book to its own group and then read it -- widening its own scope by
/// writing, which is escalation rather than the exfiltration this ADR's threat
/// model is mostly about.
///
/// **The limitation this leaves is real and is named rather than papered
/// over:** "every card in this account, group or not" is not expressible. It is
/// the same shape as ADR-011's own accepted limitation for mail ("Alice's INBOX
/// and Bob's Archive is not expressible in one profile and is two profiles"),
/// and it arrives for the same reason -- the wildcard keyword was dropped
/// deliberately, so a scope is an enumeration someone typed. An operator who
/// wants a client to see a set of cards puts those cards in a group and names
/// it. Widening `contact_groups` to mean "or no group at all" would be a scope
/// value that grants more than it names, which is the one thing a permission
/// value must never do.
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
/// value, and that one is refused (see `ContactsService.contactsCreateGroup`).
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

    /// The groups this call may reach, reconciled against what this Mac
    /// actually holds.
    ///
    /// This is the single gate every contacts tool runs first. `.unscoped`
    /// means nobody mediated the call and every tool must behave exactly as it
    /// always has; `.use` carries the effective groups, whose members are the
    /// only cards in play; `.refuse` is a scope violation; `.misconfigured` is
    /// an operator's typo, which ADR-011 decision 11 keeps out of the security
    /// signal a client's probe belongs in.
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
        guard case .allowed(let accounts) = contactAccountsAccess else {
            return .refuse(ResourceScope.refusalNoValue(field: "contact_accounts", noun: "contact account"))
        }
        guard case .allowed(let groups) = contactGroupsAccess else {
            return .refuse(ResourceScope.refusalNoValue(field: "contact_groups", noun: "contact group"))
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
