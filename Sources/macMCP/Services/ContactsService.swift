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
            description: "Search or list contacts. Returns id, name, phones, emails, and addresses.",
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
            description: "Create a new contact. Returns the new contact id.",
            inputSchema: schema(properties: [
                "first_name": stringProp("First name"),
                "last_name": stringProp("Last name"),
                "phone": stringProp("Phone number"),
                "email": stringProp("Email address"),
                "organization": stringProp("Organization name"),
                "job_title": stringProp("Job title"),
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
            description: "List all contact groups. Returns id and name for each group.",
            inputSchema: emptySchema(),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsListGroups)

        registry.register(MCPTool(
            name: "contacts_create_group",
            description: "Create a contact group. Returns the new group id.",
            inputSchema: schema(properties: [
                "name": stringProp("Group name"),
            ], required: ["name"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsCreateGroup)

        registry.register(MCPTool(
            name: "contacts_add_to_group",
            description: "Add a contact to a group.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsAddToGroup)

        registry.register(MCPTool(
            name: "contacts_remove_from_group",
            description: "Remove a contact from a group.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"]),
            annotations: MCPAnnotations(readOnlyHint: false)
        ), category: cat, handler: contactsRemoveFromGroup)

        registry.register(MCPTool(
            name: "contacts_search_by_phone",
            description: "Search contacts by phone number. Normalizes formatting before matching.",
            inputSchema: schema(properties: [
                "phone": stringProp("Phone number to search for (any format)"),
            ], required: ["phone"]),
            annotations: MCPAnnotations(readOnlyHint: true)
        ), category: cat, handler: contactsSearchByPhone)
    }

    // MARK: - Access

    /// Read-only check; see CalendarService.hasAccess for full rationale.
    private static func hasAccess() -> Bool {
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

    private static func groupDict(_ group: CNGroup) -> [String: Any] {
        ["id": group.identifier, "name": group.name]
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
    /// offers it once and `ScopePath.ambiguousValues` is what phase 2 refuses
    /// on, exactly as `mail_move` refuses two mailboxes carrying one name.
    ///
    /// Groups are read per container rather than through `store.groups(matching:
    /// nil)` (what `contacts_list_groups` calls) because that call cannot say
    /// which container a group is in, and the container is half the value.
    static func groupRows() -> (rows: [ScopePath.Row], error: String?) {
        guard hasAccess() else { return ([], accessDeniedMsg) }
        do {
            var rows: [ScopePath.Row] = []
            for container in try store.containers(matching: nil) {
                let predicate = CNGroup.predicateForGroupsInContainer(withIdentifier: container.identifier)
                for group in try store.groups(matching: predicate) {
                    rows.append(ScopePath.Row(container: containerName(container), leaf: group.name))
                }
            }
            return (rows, nil)
        } catch {
            return ([], "failed to read contact groups: \(error.localizedDescription)")
        }
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

    // MARK: - Fetch helpers

    private static func fetchContact(id: String) -> CNContact? {
        try? store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys)
    }

    private static func fetchMutableContact(id: String) -> CNMutableContact? {
        guard let contact = fetchContact(id: id) else { return nil }
        return contact.mutableCopy() as? CNMutableContact
    }

    // MARK: - Tool Handlers

    private static func contactsList(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }

        let request = CNContactFetchRequest(keysToFetch: fetchKeys)
        if let query = args?["query"]?.stringValue, !query.isEmpty {
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
    }

    private static func contactsGet(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        guard let contact = fetchContact(id: id) else {
            return errorResult("contact not found: \(id)")
        }
        return jsonResult(contactDict(contact))
    }

    private static func contactsCreate(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let firstName = args?["first_name"]?.stringValue else {
            return errorResult("first_name is required")
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
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to create contact: \(error.localizedDescription)")
        }
        return jsonResult(["id": contact.identifier, "created": true])
    }

    private static func contactsUpdate(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        guard let contact = fetchMutableContact(id: id) else {
            return errorResult("contact not found: \(id)")
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
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        guard let contact = fetchMutableContact(id: id) else {
            return errorResult("contact not found: \(id)")
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
        guard hasAccess() else { return errorResult(accessDeniedMsg) }

        do {
            let groups = try store.groups(matching: nil)
            let results = groups.map { groupDict($0) }
            return jsonResult(results)
        } catch {
            return errorResult("failed to fetch groups: \(error.localizedDescription)")
        }
    }

    private static func contactsCreateGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let name = args?["name"]?.stringValue else {
            return errorResult("name is required")
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

    private static func contactsAddToGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let contactId = args?["contact_id"]?.stringValue else {
            return errorResult("contact_id is required")
        }
        guard let groupId = args?["group_id"]?.stringValue else {
            return errorResult("group_id is required")
        }

        guard let contact = fetchContact(id: contactId) else {
            return errorResult("contact not found: \(contactId)")
        }
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
        saveRequest.addMember(contact, to: group)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to add contact to group: \(error.localizedDescription)")
        }
        return jsonResult(["contact_id": contactId, "group_id": groupId, "added": true])
    }

    private static func contactsRemoveFromGroup(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let contactId = args?["contact_id"]?.stringValue else {
            return errorResult("contact_id is required")
        }
        guard let groupId = args?["group_id"]?.stringValue else {
            return errorResult("group_id is required")
        }

        guard let contact = fetchContact(id: contactId) else {
            return errorResult("contact not found: \(contactId)")
        }
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
        saveRequest.removeMember(contact, from: group)
        do {
            try store.execute(saveRequest)
        } catch {
            return errorResult("failed to remove contact from group: \(error.localizedDescription)")
        }
        return jsonResult(["contact_id": contactId, "group_id": groupId, "removed": true])
    }

    private static func contactsSearchByPhone(_ ctx: MCPCallContext) -> MCPCallResult {
        let args = ctx.arguments
        guard hasAccess() else { return errorResult(accessDeniedMsg) }
        guard let phone = args?["phone"]?.stringValue else {
            return errorResult("phone is required")
        }

        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fetchKeys)
            let results = contacts.map { contactDict($0) }
            return jsonResult(results)
        } catch {
            return errorResult("failed to search contacts by phone: \(error.localizedDescription)")
        }
    }
}
