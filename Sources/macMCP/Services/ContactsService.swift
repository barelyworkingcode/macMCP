import Foundation
import Contacts

enum ContactsService {
    private static let store = CNContactStore()

    // CNContactNoteKey is intentionally omitted. Reading the note field
    // requires the com.apple.developer.contacts.notes entitlement (Apple-
    // restricted, requires distribution review). Without it, accessing
    // contact.note throws an ObjC NSGenericException that Swift can't catch,
    // which SIGABRTs macmcp mid-enumeration and breaks any tool that lists
    // contacts. Notes are dropped from both the read and write surface here.
    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
    ]

    // MARK: - Registration

    static func register(_ registry: ToolRegistry) {
        let cat = "Contacts"

        registry.register(MCPTool(
            name: "contacts_list",
            description: "Search or list contacts. Returns id, name, phones, emails, and addresses. "
                + "When this client's access profile carries a contacts resource scope, this lists the "
                + "members of the contact groups that scope names and nothing else.",
            inputSchema: schema(properties: [
                "query": stringProp("Name to search for. Omit to list all contacts."),
            ]),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsList)

        registry.register(MCPTool(
            name: "contacts_get",
            description: "Get full details for a single contact.",
            inputSchema: schema(properties: [
                "id": stringProp("Contact id from contacts_list results"),
            ], required: ["id"]),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsGet)

        registry.register(MCPTool(
            name: "contacts_create",
            description: "Create a new contact. Returns the new contact id. When this client's access "
                + "profile carries a contacts resource scope, the new contact is filed in the account "
                + "of a group that scope names and added to that group, so the client can read back "
                + "what it wrote; pass `group` to choose which when the scope names more than one.",
            inputSchema: schema(properties: [
                "first_name": stringProp("First name"),
                "last_name": stringProp("Last name"),
                "phone": stringProp("Phone number"),
                "email": stringProp("Email address"),
                "organization": stringProp("Organization name"),
                "job_title": stringProp("Job title"),
                "group": stringProp("Group to file the new contact in, written Account/Group (for "
                    + "example \"iCloud/Family\") as contacts_list_groups reports it. Omit to use the "
                    + "default account and no group, or — under a contacts resource scope naming "
                    + "exactly one group — that group."),
            ], required: ["first_name"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsCreate)

        registry.register(MCPTool(
            name: "contacts_update",
            description: "Update an existing contact. Only provided fields are changed.",
            inputSchema: schema(properties: [
                "id": stringProp("Contact id from contacts_list results"),
                "first_name": stringProp("First name"),
                "last_name": stringProp("Last name"),
                "phone": stringProp("Phone number"),
                "email": stringProp("Email address"),
                "organization": stringProp("Organization name"),
                "job_title": stringProp("Job title"),
            ], required: ["id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsUpdate)

        registry.register(MCPTool(
            name: "contacts_delete",
            description: "Delete a contact permanently.",
            inputSchema: schema(properties: [
                "id": stringProp("Contact id from contacts_list results"),
            ], required: ["id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsDelete)

        registry.register(MCPTool(
            name: "contacts_list_groups",
            description: "List contact groups. Returns id, name, account and path (Account/Group) for "
                + "each. Under a contacts resource scope, only the groups that scope names are listed.",
            inputSchema: emptySchema(),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsListGroups)

        registry.register(MCPTool(
            name: "contacts_create_group",
            description: "Create a contact group. Returns the new group id. Unavailable to a client "
                + "whose access profile carries a contacts resource scope, because a newly created "
                + "group is by construction not one the scope names.",
            inputSchema: schema(properties: [
                "name": stringProp("Group name"),
            ], required: ["name"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsCreateGroup)

        registry.register(MCPTool(
            name: "contacts_add_to_group",
            description: "Add a contact to a group. Both the contact and the group must be within this "
                + "client's contacts resource scope, where it has one.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsAddToGroup)

        registry.register(MCPTool(
            name: "contacts_remove_from_group",
            description: "Remove a contact from a group. Both the contact and the group must be within "
                + "this client's contacts resource scope, where it has one.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsRemoveFromGroup)

        registry.register(MCPTool(
            name: "contacts_search_by_phone",
            description: "Search contacts by phone number. Normalizes formatting before matching. "
                + "Under a contacts resource scope, only the members of the groups that scope names "
                + "are searched.",
            inputSchema: schema(properties: [
                "phone": stringProp("Phone number to search for (any format)"),
            ], required: ["phone"]),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsSearchByPhone)
    }

    // MARK: - Access

    /// Read-only check; see CalendarService.hasAccess for full rationale.
    ///
    /// Not private: it is a default argument of `gate`, and a default argument
    /// expression has to be at least as accessible as the function carrying it.
    /// That is the same reason several Mail helpers are internal (CLAUDE.md,
    /// "several Mail helpers are deliberately not private for that reason").
    static func hasAccess() -> Bool {
        return CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    private static let accessDeniedMsg = "contacts access denied — grant via Relay > Settings > MCP Servers > macMCP > Reset Permissions"

    // MARK: - Serialization

    private static func contactDict(_ contact: CNContact) -> [String: Any] {
        var dict: [String: Any] = [
            "id": contact.identifier,
            "first_name": contact.givenName,
            "last_name": contact.familyName,
        ]
        if !contact.organizationName.isEmpty {
            dict["organization"] = contact.organizationName
        }
        if !contact.jobTitle.isEmpty {
            dict["job_title"] = contact.jobTitle
        }
        // contact.note intentionally not read; see fetchKeys note.
        if !contact.phoneNumbers.isEmpty {
            dict["phones"] = contact.phoneNumbers.map { labeled in
                var entry: [String: String] = ["value": labeled.value.stringValue]
                if let label = labeled.label {
                    entry["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return entry
            }
        }
        if !contact.emailAddresses.isEmpty {
            dict["emails"] = contact.emailAddresses.map { labeled in
                var entry: [String: String] = ["value": labeled.value as String]
                if let label = labeled.label {
                    entry["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return entry
            }
        }
        if !contact.postalAddresses.isEmpty {
            dict["addresses"] = contact.postalAddresses.map { labeled in
                let addr = labeled.value
                var entry: [String: String] = [:]
                if let label = labeled.label {
                    entry["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                if !addr.street.isEmpty { entry["street"] = addr.street }
                if !addr.city.isEmpty { entry["city"] = addr.city }
                if !addr.state.isEmpty { entry["state"] = addr.state }
                if !addr.postalCode.isEmpty { entry["postal_code"] = addr.postalCode }
                if !addr.country.isEmpty { entry["country"] = addr.country }
                return entry
            }
        }
        return dict
    }

    /// A group row, as every listing and every mutation result reports one.
    ///
    /// `path` is the scope value (`Account/Group`) and is what an operator sees
    /// in relay's picker, so a client that has been handed a row can tell which
    /// of its granted groups it is looking at. `id` stays first because it is
    /// the handle `contacts_add_to_group` takes.
    static func groupDict(_ group: ContactGroupRef) -> [String: Any] {
        ["id": group.identifier, "name": group.name, "account": group.account, "path": group.path]
    }

    // MARK: - context/enumerate (ADR-011 decision 6)

    /// An account name for a `CNContainer`.
    ///
    /// `CNContainer.name` is non-optional but is routinely **empty** for the
    /// local container on macOS, and an empty account name is unusable as a
    /// scope value: it would render as a blank row in the operator's picker,
    /// and `Account/Group` would come out as `/Family`. The container's type
    /// is what is left to name it by, and the local one is called `On My Mac`
    /// for the same reason Mail's app-level mailboxes are (CLAUDE.md: "`On My
    /// Mac` is an account name every mail tool accepts") -- it is the name the
    /// user sees in Contacts.app, so an operator recognises it.
    static func containerName(_ container: CNContainer) -> String {
        if !container.name.isEmpty { return container.name }
        switch container.type {
        case .local: return "On My Mac"
        case .exchange: return "Exchange"
        case .cardDAV: return "CardDAV"
        case .unassigned: return "Unassigned"
        @unknown default: return "Unknown"
        }
    }

    /// Every contact group on this Mac, with the handles needed to act on one.
    ///
    /// This is the read half of the enforcement: `ContactScope.select` takes the
    /// list and decides what is in scope, and that function touches no
    /// framework, which is what makes the rule testable without the user's
    /// address book. The read does nothing but read.
    ///
    /// Groups are read per container rather than through `store.groups(matching:
    /// nil)` because that call cannot say which container a group is in, and the
    /// container is half of every scope value.
    static func groupCatalog() -> (groups: [ContactGroupRef], error: String?) {
        guard hasAccess() else { return ([], accessDeniedMsg) }
        do {
            var refs: [ContactGroupRef] = []
            for container in try store.containers(matching: nil) {
                let predicate = CNGroup.predicateForGroupsInContainer(withIdentifier: container.identifier)
                for group in try store.groups(matching: predicate) {
                    refs.append(ContactGroupRef(
                        account: containerName(container),
                        name: group.name,
                        identifier: group.identifier,
                        containerIdentifier: container.identifier
                    ))
                }
            }
            return (refs, nil)
        } catch {
            return ([], "failed to read contact groups: \(error.localizedDescription)")
        }
    }

    /// Every contact group, as a container/leaf row.
    ///
    /// **A group's identity here is `Account/Group`, not `CNGroup.identifier`,
    /// and that is a decision rather than a convenience.** `CNGroup` carries
    /// both, and the identifier is the more precise handle -- it is unique by
    /// construction and survives a rename, which a path does not. It is
    /// nevertheless the wrong value for this field:
    ///
    /// * It is an opaque UUID (`4A2B…`). ADR-011's whole reason for the picker
    ///   (decision 6, constraint 2) is that an operator must be able to *read*
    ///   what they granted; a profile whose scope is a list of UUIDs cannot be
    ///   reviewed, and a review that cannot be done is constraint 2 defeating
    ///   constraint 1. The audit line (decision 7) records the injected scope,
    ///   and a security log naming three UUIDs answers "was this call
    ///   confined?" with a question.
    /// * It is not stable in the way it looks stable. A container that
    ///   re-syncs re-issues identifiers -- the same hazard CLAUDE.md records
    ///   for Mail's numeric ids ("the numeric id dies when the account
    ///   re-uploads") -- so the UUID's advantage over a name is smaller than
    ///   it appears, and it fails *silently*: the scope stops matching and the
    ///   client is confined to nothing, with nothing anywhere saying why. A
    ///   renamed group at least reads as a renamed group.
    /// * Nothing else in this schema is a UUID. `mail_mailboxes` is a path,
    ///   `calendars` is `Source/Title`; one field spelled differently is one
    ///   more thing an operator has to know.
    ///
    /// The bare *name* is refused for the reason `ScopePath` states: it does
    /// not identify a group. Two accounts can each hold a `Family`, and this
    /// is the same "a leaf name does not identify a thing" bug the mailbox
    /// path work fixed. So the container is part of the value, matched whole.
    /// Where a path really is ambiguous -- two groups of one name in one
    /// account, which Contacts.app does not prevent -- `ScopePath.entries`
    /// offers it once and `ContactScope.select` reports it rather than
    /// resolving it, so `contactGroupTargets` refuses exactly as `mail_move`
    /// refuses two mailboxes carrying one name. (The detection is
    /// `ScopePath.ambiguousValues`'s question asked over the values the scope
    /// actually named, rather than over every group on the Mac: a duplicate
    /// pair nobody's profile mentions must not cost every profile its groups.)
    static func groupRows() -> (rows: [ScopePath.Row], error: String?) {
        let (groups, error) = groupCatalog()
        if let error { return ([], error) }
        return (groups.map(\.row), nil)
    }

    /// The containers themselves, read directly rather than derived from
    /// `groupRows`.
    ///
    /// A calendar account with no calendars grants nothing and is left out of
    /// that picker; a contact account with no *groups* is not the same thing,
    /// because `contact_accounts` governs the cards as well -- `contacts_list`
    /// and `contacts_search_by_phone` read contacts, which live in a container
    /// whether or not any group does. Deriving accounts from group rows would
    /// hide an account holding a thousand cards and no group.
    static func enumerateAccounts() -> ScopeEnumeration {
        guard hasAccess() else { return ([], accessDeniedMsg) }
        do {
            let containers = try store.containers(matching: nil)
            return (ScopePath.containerEntries(fromContainers: containers.map(containerName)), nil)
        } catch {
            return ([], "failed to read contact accounts: \(error.localizedDescription)")
        }
    }

    static func enumerateGroups(accountFilter: [String]?) -> ScopeEnumeration {
        let (rows, error) = groupRows()
        if let error { return ([], error) }
        return (ScopePath.entries(fromRows: rows, containerFilter: accountFilter), nil)
    }

    // MARK: - The scope gate every handler runs first

    /// What one contacts call may reach, or the answer it must give instead.
    ///
    /// Three impure steps in a fixed order, and the order is the point:
    ///
    /// 1. **The presence check** (ADR-011 decision 4), read off macMCP's own
    ///    declaration rather than a list re-typed per handler. A mediated call
    ///    carrying no `contact_accounts` or no `contact_groups` refuses here,
    ///    before the address book is touched at all.
    /// 2. **The catalog read.** Only reached when the call is either unmediated
    ///    or carries both values.
    /// 3. **The reconciliation** (`contactGroupTargets`), which is pure.
    ///
    /// **The catalog is read only when a scope is in play.** An unscoped call
    /// must cost exactly what it always did and must not acquire a new way to
    /// fail: reading the containers on every `contacts_get` would make a
    /// container that will not answer break a tool that never needed one. The
    /// two unscoped paths that do need it (`contacts_list_groups`, and
    /// `contacts_create` when a `group` was named) read it themselves.
    enum ContactsGate {
        /// Nobody mediated. Every tool behaves exactly as it always has.
        case unscoped
        /// Confined to these groups, and to their members.
        case scoped([ContactGroupRef])
        /// The call is over. `result` is what it answers.
        case stop(MCPCallResult)
    }

    /// The two impure steps are **injected**, defaulted to the real ones.
    ///
    /// Not for flexibility -- nothing but a test will ever pass either -- but
    /// because this is the single chokepoint all ten tools go through, and the
    /// alternative was a chokepoint that could only be exercised by reading the
    /// user's own address book. With them injected the whole of it is a pure
    /// decision, including the two orderings that matter: that a call with no
    /// authority is refused **before** the store is asked anything, and that an
    /// unmediated one never reads the catalog at all.
    static func gate(
        _ ctx: MCPCallContext,
        authorized: () -> Bool = hasAccess,
        catalog readCatalog: () -> (groups: [ContactGroupRef], error: String?) = groupCatalog
    ) -> ContactsGate {
        // The presence check runs before the TCC check, because it is a
        // question about this client's authority rather than about this Mac:
        // a mediated call carrying no scope has been granted nothing, and that
        // is the answer whether or not Contacts would have talked to us.
        let scope = ResourceScope.parse(ctx.meta)
        if let refusal = scope.presenceRefusal(tool: ctx.toolName) {
            return .stop(scopeViolationResult(refusal))
        }
        guard authorized() else { return .stop(errorResult(accessDeniedMsg)) }
        guard scope.isScoped else { return .unscoped }
        let (catalog, error) = readCatalog()
        if let error { return .stop(errorResult(error)) }
        return gate(for: scope.contactGroupTargets(catalog: catalog))
    }

    /// The last step of `gate`, split out because it carries the one
    /// distinction ADR-011 decision 11 insists on and the rest of `gate` cannot
    /// be reached without an address book.
    ///
    /// **A `.refuse` is a `scope_violation` and a `.misconfigured` is not.** A
    /// violation is a client probing a boundary and belongs in relay's
    /// alerting; a `contact_groups` value naming a group that is not on this
    /// Mac is an operator's typo and belongs in the editor. Conflating them
    /// fills a security signal with configuration mistakes.
    static func gate(for decision: ResourceScope.Decision<[ContactGroupRef]>) -> ContactsGate {
        switch decision {
        case .unscoped:
            return .unscoped
        case .use(let groups):
            return .scoped(groups)
        case .refuse(let message):
            return .stop(scopeViolationResult(message))
        case .misconfigured(let message):
            return .stop(errorResult(message))
        }
    }

    // MARK: - Reading cards, under a scope and without one

    /// Every card that is a member of one of these groups, deduplicated.
    ///
    /// **`unifyResults = false`.** A scoped read never unifies: a unified
    /// contact merges linked cards across containers, so its fields can carry
    /// data from an account this client may not reach and `CNContact` offers no
    /// per-value provenance to subtract it with. See `ContactsScope.swift` for
    /// the whole argument. The consequence a caller sees is that a person
    /// linked across two accounts appears once per account, and only for the
    /// accounts in scope -- which is the truthful rendering of what it may
    /// reach.
    ///
    /// One fetch per group, each predicated on that group, so a scoped read
    /// touches only the cards in scope. It is not a filter over the store: the
    /// store is never enumerated.
    ///
    /// **The account half of the cross-product is already spent by the time
    /// this runs.** A group belongs to a container and its members are cards in
    /// that container, and `ContactScope.select` has already refused any group
    /// whose container is not in `contact_accounts` -- so there is no second
    /// per-card container check here, and adding one would be checking a
    /// property of the group against a list the group has already been checked
    /// against. The confinement a caller was granted is the *group*; that is
    /// what is fetched.
    private static func members(of groups: [ContactGroupRef]) -> (contacts: [CNContact], error: String?) {
        var byID: [String: CNContact] = [:]
        var order: [String] = []
        for group in groups {
            let request = CNContactFetchRequest(keysToFetch: fetchKeys)
            request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
            request.unifyResults = false
            request.sortOrder = .givenName
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    if byID[contact.identifier] == nil {
                        byID[contact.identifier] = contact
                        order.append(contact.identifier)
                    }
                }
            } catch {
                return ([], "failed to read the members of \(group.path): \(error.localizedDescription)")
            }
        }
        return (order.compactMap { byID[$0] }, nil)
    }

    /// Whether a contact id names a card that exists *somewhere* on this Mac,
    /// asked without reading the card.
    ///
    /// ADR-011 decision 11 needs this: a found-but-out-of-scope handle must be
    /// refused as out of scope rather than reported as "not found", because a
    /// "not found" is indistinguishable from a real miss and leaves an operator
    /// nothing to debug. `CNContainer.predicateForContainerOfContact` answers
    /// the existence question **without returning any of the card's data**, so
    /// the check discloses nothing to the caller beyond what the refusal
    /// already says, and the refusal never names the container that came back.
    ///
    /// A probe that throws is read as "it exists": the refusal then says "out
    /// of scope" about an id that may be a typo, which is the harmless
    /// direction, where the other one is the answer decision 11 rules out.
    private static func contactExistsAnywhere(id: String) -> Bool {
        guard let containers = try? store.containers(
            matching: CNContainer.predicateForContainerOfContact(withIdentifier: id)
        ) else { return true }
        return !containers.isEmpty
    }

    private static func groupExistsAnywhere(id: String) -> Bool {
        guard let groups = try? store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id]))
        else { return true }
        return !groups.isEmpty
    }

    /// The answer for a handle the caller named, once it is known whether the
    /// scope covers it and whether it exists at all. `nil` to proceed.
    ///
    /// Pure, and the shape of every scope refusal these tools make: a handle in
    /// scope proceeds; a handle that exists and is not in scope is a
    /// **violation** naming what the client may reach and never where the
    /// handle actually is; a handle that exists nowhere is an ordinary
    /// not-found, which is a fact about the request rather than about a
    /// boundary.
    static func handleRefusal(
        noun: String,
        id: String,
        inScope: Bool,
        existsElsewhere: Bool,
        reachable: [String]
    ) -> MCPCallResult? {
        if inScope { return nil }
        guard existsElsewhere else { return errorResult("\(noun) not found: \(id)") }
        return scopeViolationResult(
            "\(noun) \"\(id)\" is outside the contacts this client may reach. It may reach the "
            + "members of: \(reachable.joined(separator: ", ")). Nothing about where that "
            + "\(noun) is has been read or reported."
        )
    }

    // MARK: - Matching, for the seams the framework cannot be asked

    /// Whether a card matches a `contacts_list` query, for the scoped path.
    ///
    /// **A `CNContactFetchRequest` takes one predicate and the Contacts
    /// framework does not support compound predicates**, so a scoped list
    /// cannot ask for "in this group AND matching this name" in one fetch. Of
    /// the two ways round it, this is the one that reads less: the fetch is
    /// predicated on the **group**, so only cards in scope are ever read, and
    /// the name is matched here. Predicating on the name instead would have
    /// enumerated matches from the whole address book and filtered them after
    /// the fact -- no leak either, since the out-of-scope ones would be
    /// dropped, but a scoped read that touches every card is not a confinement
    /// anyone should have to explain.
    ///
    /// The cost is that the *matching rule* is this one rather than
    /// `CNContact.predicateForContacts(matchingName:)`, whose exact behaviour
    /// is unspecified. This one is deliberately generous within the
    /// confinement -- every whitespace-separated term must appear somewhere in
    /// the given name, family name or organization, compared with diacritics
    /// and case folded -- because being generous inside a set the client is
    /// already allowed to read costs nothing, where being stingy silently hides
    /// a card the caller asked for.
    static func nameMatches(_ query: String, fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { searchFold(String($0)) }
        guard !terms.isEmpty else { return true }
        let haystack = fields.map(searchFold).filter { !$0.isEmpty }
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// Case-, diacritic- and width-insensitive, which is what a human typing a
    /// name into a search box means.
    ///
    /// Deliberately **not** `ResourceScope.fold`. That one is the rule every
    /// *scope* comparison is made in and must stay exactly as strict as it is;
    /// this is a search filter operating inside a confinement that has already
    /// been decided, where a wider net is a convenience rather than a widening.
    static func searchFold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Whether a card carries this phone number, for the scoped path.
    ///
    /// Same reason as `nameMatches`: `CNContact.predicateForContacts(matching:)`
    /// cannot be combined with the group predicate, and predicating on the
    /// number would search the whole address book. The comparison is
    /// `MessagesService.normalizedHandle` -- digits, and the last ten of them
    /// when there are more -- which is the one number-normalising rule this
    /// codebase has, so a number that finds a conversation finds the card too.
    static func phoneMatches(_ query: String, numbers: [String]) -> Bool {
        let want = MessagesService.normalizedHandle(query)
        guard !want.isEmpty else { return false }
        return numbers.contains { MessagesService.normalizedHandle($0) == want }
    }

    /// A create that landed and a membership that did not.
    ///
    /// `isError` is true because the call did not do what was asked, and the
    /// payload names the card anyway: a caller told only "it failed" would have
    /// no handle for a contact that now exists (CLAUDE.md, "a half-written save
    /// says what it wrote").
    private static func halfDoneCreate(id: String, group: String, why: String) -> MCPCallResult {
        let payload: [String: Any] = [
            "id": id,
            "created": true,
            "group": group,
            "added_to_group": false,
            "error": "the contact was created but \(why)"
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return errorResult("the contact was created but \(why)")
        }
        return MCPCallResult(content: [MCPContent(type: "text", text: text)], isError: true)
    }

    // MARK: - Tool Handlers

    private static func contactsList(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        let query = args?["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        switch gate(ctx) {
        case .stop(let result):
            return result

        case .unscoped:
            // Unchanged: the framework's own name predicate, unified results,
            // the whole store. Every call macmcp has ever served over a bare
            // stdio pipe is this one.
            let request = CNContactFetchRequest(keysToFetch: fetchKeys)
            if let query {
                request.predicate = CNContact.predicateForContacts(matchingName: query)
            }
            request.sortOrder = .givenName
            var results: [[String: Any]] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    results.append(contactDict(contact))
                }
            } catch {
                return errorResult("failed to fetch contacts: \(error.localizedDescription)")
            }
            return jsonResult(results)

        case .scoped(let groups):
            let (contacts, error) = members(of: groups)
            if let error { return errorResult(error) }
            let matched = query.map { needle in
                contacts.filter {
                    nameMatches(needle, fields: [$0.givenName, $0.familyName, $0.organizationName])
                }
            } ?? contacts
            return jsonResult(sortedByName(matched).map(contactDict))
        }
    }

    /// The sort `CNContactFetchRequest.sortOrder` gives one fetch, applied
    /// across several. A scoped list is the union of one fetch per group, so
    /// the per-fetch ordering says nothing about the whole.
    private static func sortedByName(_ contacts: [CNContact]) -> [CNContact] {
        contacts.sorted {
            let left = ($0.givenName + " " + $0.familyName, $0.identifier)
            let right = ($1.givenName + " " + $1.familyName, $1.identifier)
            let compared = left.0.localizedCaseInsensitiveCompare(right.0)
            if compared != .orderedSame { return compared == .orderedAscending }
            return left.1 < right.1
        }
    }

    /// What looking a card up came to.
    private enum Resolution {
        case found(CNContact)
        /// Not in scope, or not there at all. Which of the two it is is
        /// `unresolved`'s question, and answering it costs a second probe.
        case missing
        /// The read itself failed. **Kept apart from `missing` deliberately**:
        /// a container that would not answer must not be reported as "that
        /// contact is outside your scope", which is a claim about the caller's
        /// authority made on the strength of a failure.
        case failed(String)
    }

    /// A card the caller named, resolved and scope-checked in one step.
    ///
    /// The resolution *is* the check, which is what makes it sound: under a
    /// scope the card is looked for among the members of the groups in scope
    /// and nowhere else, so a card that comes back is in scope by construction
    /// rather than by a comparison someone remembered to write. Only when it is
    /// **not** found is the store asked whether the id exists at all, and that
    /// question is asked in the one way that returns none of the card's data.
    private static func resolve(id: String, gate: ContactsGate) -> Resolution {
        switch gate {
        case .stop:
            return .missing
        case .unscoped:
            guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys) else {
                return .missing
            }
            return .found(contact)
        case .scoped(let groups):
            let (contacts, error) = members(of: groups)
            if let error { return .failed(error) }
            guard let contact = contacts.first(where: { $0.identifier == id }) else { return .missing }
            return .found(contact)
        }
    }

    /// `resolve`, with the two non-answers already turned into the result they
    /// mean, so a handler is one `switch` rather than three branches it could
    /// get in the wrong order.
    private static func contact(
        id: String,
        gate: ContactsGate,
        noun: String = "contact"
    ) -> (contact: CNContact?, refusal: MCPCallResult?) {
        switch resolve(id: id, gate: gate) {
        case .found(let contact):
            return (contact, nil)
        case .failed(let message):
            return (nil, errorResult(message))
        case .missing:
            return (nil, unresolved(id: id, gate: gate, noun: noun))
        }
    }

    /// The answer when `resolve` came back empty, which is the whole of the
    /// decision-11 shape.
    private static func unresolved(id: String, gate: ContactsGate, noun: String = "contact") -> MCPCallResult {
        switch gate {
        case .stop(let result):
            return result
        case .unscoped:
            return errorResult("\(noun) not found: \(id)")
        case .scoped(let groups):
            return handleRefusal(
                noun: noun,
                id: id,
                inScope: false,
                existsElsewhere: contactExistsAnywhere(id: id),
                reachable: groups.map(\.path)
            ) ?? errorResult("\(noun) not found: \(id)")
        }
    }

    private static func contactsGet(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }
        let (found, refusal) = contact(id: id, gate: access)
        guard let found else { return refusal ?? errorResult("contact not found: \(id)") }
        return jsonResult(contactDict(found))
    }

    private static func contactsCreate(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let firstName = args?["first_name"]?.stringValue else {
            return errorResult("first_name is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }

        // Where the card goes. **A create with no container goes to the
        // default container, which may be outside the scope**, so under a
        // scope the destination is resolved to the scope rather than left to
        // the framework: the card is filed in the account of a group the
        // client may reach and added to that group, which is what makes the
        // confinement closed under creation -- a client can read back what it
        // wrote, and it has written nothing it cannot see.
        let requested = args?["group"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        var destination: ContactGroupRef?
        switch access {
        case .stop:
            return errorResult("unreachable")
        case .unscoped:
            if let requested {
                let (catalog, error) = groupCatalog()
                if let error { return errorResult(error) }
                switch ContactScope.choose(group: requested, from: catalog) {
                case .chosen(let group):
                    destination = group
                case .outside(let name):
                    // Not a scope violation: nothing is confining this call.
                    // The group simply is not there, or is one of two.
                    return errorResult(
                        "no single group named \"\(name)\". Groups are written Account/Group, as "
                        + "contacts_list_groups reports them."
                    )
                case .underSpecified:
                    destination = nil
                }
            }
        case .scoped(let groups):
            switch ContactScope.choose(group: requested, from: groups) {
            case .chosen(let group):
                destination = group
            case .outside(let name):
                return scopeViolationResult(
                    "group \"\(name)\" is outside the contact groups this client may reach. "
                    + "It may reach: \(groups.map(\.path).joined(separator: ", ")). A contact created "
                    + "outside them would be one this client could not read back."
                )
            case .underSpecified(let choices):
                return errorResult(
                    "this client may file a new contact in more than one group, so `group` is "
                    + "required: \(choices.joined(separator: ", "))."
                )
            }
        }

        let contact = CNMutableContact()
        contact.givenName = firstName
        if let v = args?["last_name"]?.stringValue { contact.familyName = v }
        if let v = args?["organization"]?.stringValue { contact.organizationName = v }
        if let v = args?["job_title"]?.stringValue { contact.jobTitle = v }
        if let v = args?["phone"]?.stringValue {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: v))]
        }
        if let v = args?["email"]?.stringValue {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: v as NSString)]
        }

        let saveRequest = CNSaveRequest()
        // `nil` is the framework's "default container", which is exactly what
        // an unscoped create has always used and exactly what a scoped one
        // must never fall back to.
        let container = destination.flatMap { $0.containerIdentifier.isEmpty ? nil : $0.containerIdentifier }
        saveRequest.add(contact, toContainerWithIdentifier: container)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to create contact: \(error.localizedDescription)")
        }

        guard let destination else {
            return jsonResult(["id": contact.identifier, "created": true])
        }

        // The membership is a **second** save request, because a card added
        // and made a member in one request is not a documented shape and a
        // failure there would leave nothing to say. Two requests can half
        // succeed, so what is reported is what happened: the card exists, and
        // whether it reached the group. Silence about a half-done write is the
        // one thing that is not on offer (CLAUDE.md, "a half-written save says
        // what it wrote").
        let membership = CNSaveRequest()
        guard let group = try? store.groups(
            matching: CNGroup.predicateForGroups(withIdentifiers: [destination.identifier])
        ).first else {
            return halfDoneCreate(
                id: contact.identifier,
                group: destination.path,
                why: "group \(destination.path) could not be read back to add it to"
            )
        }
        membership.addMember(contact, to: group)
        do {
            try store.execute(membership)
        } catch {
            return halfDoneCreate(
                id: contact.identifier,
                group: destination.path,
                why: "adding it to \(destination.path) failed: \(error.localizedDescription)"
            )
        }
        return jsonResult([
            "id": contact.identifier,
            "created": true,
            "group": destination.path,
            "added_to_group": true
        ])
    }

    private static func contactsUpdate(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }
        let (found, refusal) = contact(id: id, gate: access)
        guard let found else { return refusal ?? errorResult("contact not found: \(id)") }
        guard let contact = found.mutableCopy() as? CNMutableContact else {
            return errorResult("contact \(id) could not be prepared for writing")
        }

        if let v = args?["first_name"]?.stringValue { contact.givenName = v }
        if let v = args?["last_name"]?.stringValue { contact.familyName = v }
        if let v = args?["organization"]?.stringValue { contact.organizationName = v }
        if let v = args?["job_title"]?.stringValue { contact.jobTitle = v }
        if let v = args?["phone"]?.stringValue {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: v))]
        }
        if let v = args?["email"]?.stringValue {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: v as NSString)]
        }

        let saveRequest = CNSaveRequest()
        saveRequest.update(contact)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to update contact: \(error.localizedDescription)")
        }
        return jsonResult(["id": id, "updated": true])
    }

    private static func contactsDelete(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }
        let (found, refusal) = contact(id: id, gate: access)
        guard let found else { return refusal ?? errorResult("contact not found: \(id)") }
        guard let contact = found.mutableCopy() as? CNMutableContact else {
            return errorResult("contact \(id) could not be prepared for writing")
        }

        let saveRequest = CNSaveRequest()
        saveRequest.delete(contact)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to delete contact: \(error.localizedDescription)")
        }
        return jsonResult(["id": id, "deleted": true])
    }

    private static func contactsListGroups(_ ctx: MCPCallContext) -> MCPCallResult {
        // **An enumerator is scoped too** (ADR-011's reconciliation rule).
        // Listing the machine's real group names to a confined client is a
        // disclosure, and it is also how that client learns what to try next.
        switch gate(ctx) {
        case .stop(let result):
            return result
        case .unscoped:
            let (catalog, error) = groupCatalog()
            if let error { return errorResult(error) }
            return jsonResult(catalog.map(groupDict))
        case .scoped(let groups):
            return jsonResult(groups.map(groupDict))
        }
    }

    private static func contactsCreateGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let name = args?["name"]?.stringValue else {
            return errorResult("name is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }

        // **This is the one contacts tool a scope cannot be honestly applied
        // to, so it is refused rather than filtered.** `contact_groups` is an
        // enumeration of the groups this client may reach; a group that has
        // just been created is by construction not in it. Neither available
        // reading survives contact with the rest of the surface:
        //
        // * Create it anyway, in an in-scope account. The client then holds a
        //   group it cannot list, cannot add anyone to (`contacts_add_to_group`
        //   checks both ends against the scope) and cannot read the members of
        //   -- a capability that always leads to a dead end, advertised as if
        //   it worked.
        // * Treat the new group as in scope. That is a client widening its own
        //   confinement by writing, which is the escalation shape ADR-011
        //   carves out as the one thing worse than exfiltration here.
        //
        // ADR-011's own instruction for exactly this is that refusing a tool is
        // better than returning a filtered-looking result that is not confined.
        // It is a violation rather than a misconfiguration: nothing about the
        // operator's scope is wrong, the client asked to create a resource
        // outside it.
        if case .scoped(let groups) = access {
            return createGroupRefusal(inScope: groups)
        }

        let group = CNMutableGroup()
        group.name = name

        let saveRequest = CNSaveRequest()
        saveRequest.add(group, toContainerWithIdentifier: nil)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to create group: \(error.localizedDescription)")
        }
        return jsonResult(["id": group.identifier, "name": name, "created": true])
    }

    /// The refusal above, as a value, so what a confined client is told can be
    /// pinned by a test that needs no address book.
    static func createGroupRefusal(inScope groups: [ContactGroupRef]) -> MCPCallResult {
        scopeViolationResult(
            "this client may not create contact groups: its access profile confines it to the "
            + "groups named in `contact_groups` (\(groups.map(\.path).joined(separator: ", "))), "
            + "and a group created now would not be one of them — it could not be listed, added "
            + "to, or read back. Nothing was created. An operator can create the group in "
            + "Contacts and name it in the profile."
        )
    }

    /// The two ends of a membership change, each checked against the scope.
    ///
    /// **Both, and the contact end is the one that is easy to miss.** A client
    /// that could add *any* card to a group it holds would be able to read that
    /// card on the next call -- widening its own scope by writing rather than
    /// by being granted anything. So a card must already be reachable (a member
    /// of some group in scope) before it can be moved between the groups in
    /// scope.
    private static func membership(
        _ ctx: MCPCallContext,
        add: Bool
    ) -> MCPCallResult {
        let args = ctx.arguments
        guard let contactId = args?["contact_id"]?.stringValue else {
            return errorResult("contact_id is required")
        }
        guard let groupId = args?["group_id"]?.stringValue else {
            return errorResult("group_id is required")
        }
        let access = gate(ctx)
        if case .stop(let result) = access { return result }

        // The group end. Unscoped this is not a question -- the group is
        // whatever the id names, exactly as it always was -- so the only work
        // here is the scoped case, where a group the scope does not name is a
        // violation and a group nothing names is a miss.
        var target: ContactGroupRef?
        if case .scoped(let groups) = access {
            target = groups.first { $0.identifier == groupId }
            guard target != nil else {
                return handleRefusal(
                    noun: "group",
                    id: groupId,
                    inScope: false,
                    existsElsewhere: groupExistsAnywhere(id: groupId),
                    reachable: groups.map(\.path)
                ) ?? errorResult("group not found: \(groupId)")
            }
        }

        // The contact end.
        let (found, refusal) = contact(id: contactId, gate: access)
        guard let found else { return refusal ?? errorResult("contact not found: \(contactId)") }

        let groups: [CNGroup]
        do {
            groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupId]))
        } catch {
            return errorResult("failed to fetch group: \(error.localizedDescription)")
        }
        guard let group = groups.first else {
            return errorResult("group not found: \(groupId)")
        }

        let saveRequest = CNSaveRequest()
        if add {
            saveRequest.addMember(found, to: group)
        } else {
            saveRequest.removeMember(found, from: group)
        }
        do {
            try store.execute(saveRequest)
        } catch {
            let verb = add ? "add contact to group" : "remove contact from group"
            return errorResult("failed to \(verb): \(error.localizedDescription)")
        }
        var payload: [String: Any] = ["contact_id": contactId, "group_id": groupId]
        // The path only when it was resolved, which is the scoped case: an
        // unscoped result stays byte-for-byte what it has always been.
        if let target { payload["group"] = target.path }
        payload[add ? "added" : "removed"] = true
        return jsonResult(payload)
    }

    private static func contactsAddToGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        membership(ctx, add: true)
    }

    private static func contactsRemoveFromGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        membership(ctx, add: false)
    }

    private static func contactsSearchByPhone(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard let phone = args?["phone"]?.stringValue else {
            return errorResult("phone is required")
        }
        switch gate(ctx) {
        case .stop(let result):
            return result
        case .unscoped:
            // Unchanged, unified, whole store.
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
            do {
                let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fetchKeys)
                return jsonResult(contacts.map(contactDict))
            } catch {
                return errorResult("failed to search contacts by phone: \(error.localizedDescription)")
            }
        case .scoped(let groups):
            // **This is the tool the unified-contact decision matters most
            // for**, because it is the one that called `unifiedContacts`
            // directly: a merged card matching on a number held by an
            // out-of-scope linked card would have been returned whole, fields
            // from both accounts included. Under a scope the search runs over
            // the members of the groups in scope, read raw, and matches here.
            let (contacts, error) = members(of: groups)
            if let error { return errorResult(error) }
            let matched = contacts.filter {
                phoneMatches(phone, numbers: $0.phoneNumbers.map(\.value.stringValue))
            }
            return jsonResult(sortedByName(matched).map(contactDict))
        }
    }
}
