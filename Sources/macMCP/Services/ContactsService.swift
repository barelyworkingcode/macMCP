import Foundation
import Contacts

enum ContactsService {
    private static let store = CNContactStore()

    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
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
                "note": stringProp("Note"),
            ], required: ["first_name"])
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
                "note": stringProp("Note"),
            ], required: ["id"])
        ), category: cat, handler: contactsUpdate)

        registry.register(MCPTool(
            name: "contacts_delete",
            description: "Delete a contact permanently.",
            inputSchema: schema(properties: [
                "id": stringProp("Contact id from contacts_list results"),
            ], required: ["id"])
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
            ], required: ["name"])
        ), category: cat, handler: contactsCreateGroup)

        registry.register(MCPTool(
            name: "contacts_add_to_group",
            description: "Add a contact to a group.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"])
        ), category: cat, handler: contactsAddToGroup)

        registry.register(MCPTool(
            name: "contacts_remove_from_group",
            description: "Remove a contact from a group.",
            inputSchema: schema(properties: [
                "contact_id": stringProp("Contact id from contacts_list results"),
                "group_id": stringProp("Group id from contacts_list_groups results"),
            ], required: ["contact_id", "group_id"])
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

    private static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(for: .contacts) { ok, _ in
            granted = ok
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    }

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
        if !contact.note.isEmpty {
            dict["note"] = contact.note
        }
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

    // MARK: - Fetch helpers

    private static func fetchContact(id: String) -> CNContact? {
        try? store.unifiedContact(withIdentifier: id, keysToFetch: fetchKeys)
    }

    private static func fetchMutableContact(id: String) -> CNMutableContact? {
        guard let contact = fetchContact(id: id) else { return nil }
        return contact.mutableCopy() as? CNMutableContact
    }

    // MARK: - Tool Handlers

    private static func contactsList(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }

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

    private static func contactsGet(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
        guard let id = args?["id"]?.stringValue else {
            return errorResult("id is required")
        }
        guard let contact = fetchContact(id: id) else {
            return errorResult("contact not found: \(id)")
        }
        return jsonResult(contactDict(contact))
    }

    private static func contactsCreate(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
        guard let firstName = args?["first_name"]?.stringValue else {
            return errorResult("first_name is required")
        }

        let contact = CNMutableContact()
        contact.givenName = firstName
        if let v = args?["last_name"]?.stringValue { contact.familyName = v }
        if let v = args?["organization"]?.stringValue { contact.organizationName = v }
        if let v = args?["job_title"]?.stringValue { contact.jobTitle = v }
        if let v = args?["note"]?.stringValue { contact.note = v }
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

    private static func contactsUpdate(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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
        if let v = args?["note"]?.stringValue { contact.note = v }
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

    private static func contactsDelete(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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

    private static func contactsListGroups(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }

        do {
            let groups = try store.groups(matching: nil)
            let results = groups.map { groupDict($0) }
            return jsonResult(results)
        } catch {
            return errorResult("failed to fetch groups: \(error.localizedDescription)")
        }
    }

    private static func contactsCreateGroup(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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

    private static func contactsAddToGroup(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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

    private static func contactsRemoveFromGroup(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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

    private static func contactsSearchByPhone(_ args: JSONObject?) -> MCPCallResult {
        guard requestAccess() else { return errorResult("contacts access denied") }
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
