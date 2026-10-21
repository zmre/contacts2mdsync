internal import ContactModel
internal import Contacts
internal import Foundation

/// Turns `AppleWriteOperation`s into one `CNSaveRequest` (architecture §6,
/// "Stamping and write targets").
///
/// Every operation targets an **underlying card** fetched with
/// `unifyResults = false`. A unified contact's mutable copy is never saved:
/// spike S4 showed that writes the change to every linked card.
///
/// List edits keep `CNLabeledValue` identifiers: an element that names its
/// current value (`AppleListElement.existing`) is matched to the card's
/// labeled value with that canonical value and changed with
/// `settingLabel(_:value:)`, which keeps the identifier. Values the canonical
/// model cannot represent, and our `x-c2mdsync:` stamp URL, are always kept.
struct CardWriter {
    let store: CNContactStore
    let includeNote: Bool

    /// What one save produced.
    struct Saved {
        var created: [UUID: String] = [:]
    }

    /// Saves `operations` as one request tagged with `author`.
    func save(_ operations: [AppleWriteOperation], author: String) throws -> Saved {
        var staging = try Staging(writer: self, operations: operations)
        for operation in operations {
            if case .create(let new) = operation {
                try staging.create(new)
            } else {
                try staging.stage(operation)
            }
        }
        staging.request.transactionAuthor = author
        for cardID in staging.updated.subtracting(staging.deleted) {
            if let card = staging.cards[cardID] { staging.request.update(card) }
        }
        try store.execute(staging.request)
        var saved = Saved()
        for (recordID, contact) in staging.created { saved.created[recordID] = contact.identifier }
        return saved
    }

    /// One `CNSaveRequest` being assembled from operations.
    private struct Staging {
        let writer: CardWriter
        let request = CNSaveRequest()
        var cards: [String: CNMutableContact]
        let groups: [String: CNGroup]
        var members: [String: Set<String>] = [:]
        var updated = Set<String>()
        var deleted = Set<String>()
        var created: [(UUID, CNMutableContact)] = []

        init(writer: CardWriter, operations: [AppleWriteOperation]) throws {
            self.writer = writer
            let needsImage = operations.contains { operation in
                guard case .update(_, let edits) = operation else { return false }
                return edits.contains { if case .image = $0 { true } else { false } }
            }
            cards = try writer.fetchCards(Array(Set(operations.compactMap(\.cardID))), includeImage: needsImage)
            let groupIDs = operations.flatMap { operation -> [String] in
                switch operation {
                case .addMember(_, let group), .removeMember(_, let group): [group]
                case .create(let new): new.groupIDs
                default: []
                }
            }
            groups = try writer.fetchGroups(Array(Set(groupIDs)))
        }

        private func card(_ id: String) throws -> CNMutableContact {
            guard let card = cards[id] else { throw ContactStoreError.cardNotFound(id) }
            return card
        }

        private func group(_ id: String) throws -> CNGroup {
            guard let group = groups[id] else { throw ContactStoreError.cardNotFound("group \(id)") }
            return group
        }

        mutating func stage(_ operation: AppleWriteOperation) throws {
            switch operation {
            case .stamp(let cardID, let id):
                CardWriter.setStamp(id, on: try card(cardID))
                updated.insert(cardID)
            case .removeStamp(let cardID):
                let card = try card(cardID)
                card.urlAddresses = card.urlAddresses.filter { !SyncStamp.isStamp($0.value as String) }
                updated.insert(cardID)
            case .update(let cardID, let edits):
                let card = try card(cardID)
                for edit in edits { try writer.apply(edit, to: card) }
                updated.insert(cardID)
            case .delete(let cardID):
                request.delete(try card(cardID))
                deleted.insert(cardID)
            case .addMember(let cardID, let groupID):
                request.addMember(try card(cardID), to: try group(groupID))
            case .removeMember(let cardID, let groupID):
                let group = try group(groupID)
                if members[groupID] == nil { members[groupID] = try writer.memberIDs(of: groupID) }
                if members[groupID]?.contains(cardID) == true { request.removeMember(try card(cardID), from: group) }
            case .create:
                break
            }
        }

        mutating func create(_ new: NewAppleContact) throws {
            let contact = CNMutableContact()
            contact.contactType = new.kind == .organization ? .organization : .person
            for edit in new.edits { try writer.apply(edit, to: contact) }
            if let stamp = new.stamp { CardWriter.setStamp(stamp, on: contact) }
            request.add(contact, toContainerWithIdentifier: new.containerID)
            for groupID in new.groupIDs { request.addMember(contact, to: try group(groupID)) }
            created.append((new.recordID, contact))
        }
    }

    // MARK: - Fetching

    /// Underlying cards (never unified) with every field the writer may touch.
    func fetchCards(_ ids: [String], includeImage: Bool) throws -> [String: CNMutableContact] {
        guard !ids.isEmpty else { return [:] }
        var keys = AppleContactMapper.cardKeys(includeNote: includeNote)
        if includeImage { keys.append(CNContactImageDataKey as NSString) }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        request.unifyResults = false
        var result: [String: CNMutableContact] = [:]
        try store.enumerateContacts(with: request) { contact, _ in
            guard ids.contains(contact.identifier),
                let mutable = contact.mutableCopy() as? CNMutableContact
            else { return }
            result[contact.identifier] = mutable
        }
        return result
    }

    func fetchGroups(_ ids: [String]) throws -> [String: CNGroup] {
        guard !ids.isEmpty else { return [:] }
        let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: ids))
        return Dictionary(groups.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func memberIDs(of groupID: String) throws -> Set<String> {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
        request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
        request.unifyResults = false
        var ids = Set<String>()
        try store.enumerateContacts(with: request) { contact, _ in ids.insert(contact.identifier) }
        return ids
    }

    // MARK: - Edits

    static func setStamp(_ id: UUID, on contact: CNMutableContact) {
        var urls = contact.urlAddresses.filter { !SyncStamp.isStamp($0.value as String) }
        urls.append(CNLabeledValue(label: SyncStamp.label, value: SyncStamp.url(for: id) as NSString))
        contact.urlAddresses = urls
    }

    func apply(_ edit: CardEdit, to contact: CNMutableContact) throws {
        try Self.apply(edit, to: contact, includeNote: includeNote)
    }

    /// Applies one edit to a card (no store access; unit-tested directly).
    static func apply(_ edit: CardEdit, to contact: CNMutableContact, includeNote: Bool) throws {
        switch edit {
        case .scalar(let field, let value):
            Self.set(field, value ?? "", on: contact)
        case .birthday(let date):
            contact.birthday = date.flatMap(Self.components)
        case .note(let text):
            // Never touch the note without the entitlement (the key is not fetched).
            guard includeNote else { throw ContactStoreError.notImplemented("notes entitlement missing") }
            contact.note = text ?? ""
        case .image(let data):
            contact.imageData = data
        case .list(let field, let elements):
            Self.setList(field, elements, on: contact)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func set(_ field: AppleScalarField, _ value: String, on contact: CNMutableContact) {
        switch field {
        case .namePrefix: contact.namePrefix = value
        case .givenName: contact.givenName = value
        case .middleName: contact.middleName = value
        case .familyName: contact.familyName = value
        case .nameSuffix: contact.nameSuffix = value
        case .nickname: contact.nickname = value
        case .previousFamilyName: contact.previousFamilyName = value
        case .organizationName: contact.organizationName = value
        case .departmentName: contact.departmentName = value
        case .jobTitle: contact.jobTitle = value
        case .phoneticGivenName: contact.phoneticGivenName = value
        case .phoneticMiddleName: contact.phoneticMiddleName = value
        case .phoneticFamilyName: contact.phoneticFamilyName = value
        case .phoneticOrganizationName: contact.phoneticOrganizationName = value
        }
    }

    static func components(_ date: PartialDate) -> DateComponents? {
        switch date {
        case .full(let year, let month, let day): DateComponents(year: year, month: month, day: day)
        case .monthDay(let month, let day): DateComponents(month: month, day: day)
        case .yearMonth, .year, .text: nil
        }
    }
}
