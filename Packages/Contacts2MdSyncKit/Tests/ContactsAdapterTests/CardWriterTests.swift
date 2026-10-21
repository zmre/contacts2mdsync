import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Card edits applied to in-memory `CNMutableContact`s. Nothing here
/// creates a `CNContactStore` or executes a save request.
@Suite("Card writer (CardEdit → CNMutableContact)")
struct CardWriterTests {
    private func card() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "Ann"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 415 555 0100")),
            CNLabeledValue(label: "Summer House", value: CNPhoneNumber(stringValue: "+1 415 555 0199")),
        ]
        contact.urlAddresses = [
            CNLabeledValue(label: SyncStamp.label, value: SyncStamp.url(for: UUID()) as NSString),
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://ann.example" as NSString),
        ]
        return contact
    }

    @Test("an edited element keeps its labeled-value identifier; an unchanged custom label keeps its casing")
    func inPlaceEdit() throws {
        let contact = card()
        let ids = contact.phoneNumbers.map(\.identifier)
        try CardWriter.apply(
            .list(
                .phones,
                [
                    AppleListElement(
                        existing: .text("+1 415 555 0100"), existingLabel: "mobile", label: "mobile",
                        value: .text("+1 415 555 0177")),
                    AppleListElement(
                        existing: .text("+1 415 555 0199"), existingLabel: "summer_house", label: "summer_house",
                        value: .text("+1 415 555 0199")),
                ]),
            to: contact, includeNote: false)
        #expect(contact.phoneNumbers.map(\.identifier) == ids)
        #expect(contact.phoneNumbers.map(\.value.stringValue) == ["+1 415 555 0177", "+1 415 555 0199"])
        #expect(contact.phoneNumbers.map(\.label) == [CNLabelPhoneNumberMobile, "Summer House"])
    }

    @Test("relabel keeps the identifier; a new element is added; an omitted one is removed")
    func relabelAddRemove() throws {
        let contact = card()
        let mobileID = contact.phoneNumbers[0].identifier
        try CardWriter.apply(
            .list(
                .phones,
                [
                    AppleListElement(
                        existing: .text("+1 415 555 0100"), existingLabel: "mobile", label: "work",
                        value: .text("+1 415 555 0100")),
                    AppleListElement(label: "home", value: .text("+1 212 555 0100")),
                ]),
            to: contact, includeNote: false)
        #expect(contact.phoneNumbers.count == 2)
        #expect(contact.phoneNumbers[0].identifier == mobileID)
        #expect(contact.phoneNumbers[0].label == CNLabelWork)
        #expect(contact.phoneNumbers[1].label == CNLabelHome)
        #expect(contact.phoneNumbers[1].value.stringValue == "+1 212 555 0100")
    }

    @Test("the sync stamp URL is always kept when URLs are rewritten")
    func stampKept() throws {
        let contact = card()
        try CardWriter.apply(.list(.urls, []), to: contact, includeNote: false)
        #expect(contact.urlAddresses.count == 1)
        #expect(SyncStamp.isStamp(contact.urlAddresses[0].value as String))
    }

    @Test("values the canonical model cannot represent are kept")
    func unmappableKept() throws {
        let contact = card()
        contact.socialProfiles = [
            CNLabeledValue(
                label: nil,
                value: CNSocialProfile(urlString: nil, username: nil, userIdentifier: "42", service: "Twitter"))
        ]
        try CardWriter.apply(
            .list(.social, [AppleListElement(label: "linkedin", value: .social(SocialHandle("https://in.example/a")))]),
            to: contact, includeNote: false)
        #expect(contact.socialProfiles.count == 2)
        #expect(contact.socialProfiles.contains { $0.value.service == CNSocialProfileServiceLinkedIn })
    }

    @Test("relations: an equivalent existing Apple label is kept; a new one is mapped")
    func relations() throws {
        let contact = card()
        contact.contactRelations = [CNLabeledValue(label: "Best Friend", value: CNContactRelation(name: "Bob"))]
        try CardWriter.apply(
            .list(
                .relations,
                [
                    AppleListElement(
                        existing: .relation(name: "Bob", type: "best_friend", label: nil), existingLabel: nil,
                        label: nil, value: .relation(name: "Bob", type: "best_friend", label: nil)),
                    AppleListElement(label: "mother", value: .relation(name: "Cara", type: "parent", label: "mother")),
                ]),
            to: contact, includeNote: false)
        #expect(contact.contactRelations.map(\.label) == ["Best Friend", "_$!<Mother>!$_"])
    }

    @Test("scalars set and clear; birthday without a year; notes need the entitlement")
    func scalars() throws {
        let contact = card()
        try CardWriter.apply(.scalar(.jobTitle, "CTO"), to: contact, includeNote: false)
        try CardWriter.apply(.scalar(.givenName, nil), to: contact, includeNote: false)
        try CardWriter.apply(.birthday(.monthDay(month: 6, day: 10)), to: contact, includeNote: false)
        #expect(contact.jobTitle == "CTO" && contact.givenName.isEmpty)
        #expect(contact.birthday?.month == 6 && contact.birthday?.day == 10 && contact.birthday?.year == nil)
        #expect(throws: (any Error).self) { try CardWriter.apply(.note("x"), to: contact, includeNote: false) }
    }

    @Test("a failed batch is retried card by card; creates alone")
    func units() {
        let operations: [AppleWriteOperation] = [
            .update(cardID: "a", edits: []), .stamp(cardID: "b", id: UUID()), .addMember(cardID: "a", groupID: "g"),
            .create(NewAppleContact(recordID: UUID(), containerID: "icloud", kind: .person, edits: [])),
        ]
        let units = CNContactStoreAdapter.units(of: operations)
        #expect(units.map(\.count) == [2, 1, 1])
        #expect(units[0].compactMap(\.cardID) == ["a", "a"])
    }
}
