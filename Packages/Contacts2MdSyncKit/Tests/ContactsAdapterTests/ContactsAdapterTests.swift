import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Mapping tests over in-memory `CNMutableContact`s. Nothing here opens a
/// `CNContactStore`, so the user's address book is never read.
@Suite("CNContact → canonical")
struct MapperTests {
    private func labeled<Value>(_ label: String?, _ value: Value) -> CNLabeledValue<Value> {
        CNLabeledValue(label: label, value: value)
    }

    @Test("names, organization, phonetics and aliases")
    func names() {
        let contact = CNMutableContact()
        contact.namePrefix = "Dr."
        contact.givenName = " Jane "
        contact.middleName = "Quinn"
        contact.familyName = "Doe"
        contact.nickname = "JJ"
        contact.previousFamilyName = "Smith"
        contact.organizationName = "Acme Corp"
        contact.departmentName = "R&D"
        contact.jobTitle = "CTO"
        contact.phoneticFamilyName = "ドウ"
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(mapped.kind == .person)
        #expect(mapped.title.isEmpty)
        #expect(mapped.name == PersonName(prefix: "Dr.", given: "Jane", middle: "Quinn", family: "Doe"))
        #expect(mapped.aliases == [.nickname("JJ"), .maidenName("Smith")])
        #expect(mapped.company == .plain("Acme Corp"))
        #expect(mapped.department == "R&D")
        #expect(mapped.jobTitle == "CTO")
        #expect(mapped.apple.phoneticFamily == "ドウ")
    }

    @Test("labels map Apple → markdown; custom labels snake_case; nil stays bare")
    func labels() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [
            labeled(CNLabelPhoneNumberMobile, CNPhoneNumber(stringValue: "+1 415 555 0100")),
            labeled(CNLabelPhoneNumberiPhone, CNPhoneNumber(stringValue: "415-555-0101")),
            labeled(CNLabelPhoneNumberHomeFax, CNPhoneNumber(stringValue: "415-555-0102")),
            labeled(nil, CNPhoneNumber(stringValue: "415-555-0103")),
        ]
        contact.emailAddresses = [
            labeled(CNLabelEmailiCloud, "a@icloud.com" as NSString),
            labeled("Summer House", "b@example.com" as NSString),
        ]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(mapped.phones.map(\.label) == ["mobile", "iphone", "home_fax", nil])
        #expect(mapped.emails == [Labeled("icloud", "a@icloud.com"), Labeled("summer_house", "b@example.com")])
    }

    @Test("the x-mdsync stamp URL is filtered out and exposed as the stamp id")
    func stampFiltered() throws {
        let id = try #require(UUID(uuidString: "6f1c2e0a-8c1b-4b0e-9a57-2d0d4a1c9f13"))
        let contact = CNMutableContact()
        contact.urlAddresses = [
            labeled(CNLabelURLAddressHomePage, "https://janedoe.example" as NSString),
            labeled(SyncStamp.label, SyncStamp.url(for: id) as NSString),
            labeled("other", "X-MDSYNC:garbage" as NSString),
        ]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(mapped.urls == [Labeled("homepage", "https://janedoe.example")])
        #expect(AppleContactMapper.stampID(of: contact) == id)
    }

    @Test("social profiles and IM use the service as label")
    func social() {
        let contact = CNMutableContact()
        contact.socialProfiles = [
            labeled(
                nil,
                CNSocialProfile(
                    urlString: "https://www.linkedin.com/in/jane", username: "jane", userIdentifier: nil,
                    service: CNSocialProfileServiceLinkedIn)),
            labeled(
                nil, CNSocialProfile(urlString: nil, username: "@jane", userIdentifier: nil, service: "Twitter")),
        ]
        contact.instantMessageAddresses = [
            labeled(CNLabelHome, CNInstantMessageAddress(username: "jane.doe", service: CNInstantMessageServiceSkype))
        ]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(
            mapped.social == [
                Labeled("linkedin", SocialHandle("https://www.linkedin.com/in/jane")),
                Labeled("twitter", SocialHandle("@jane")),
            ])
        #expect(mapped.im == [Labeled("skype", IMHandle("jane.doe"))])
    }

    @Test("postal addresses: components, ISO country code uppercased, multi-line street")
    func addresses() {
        let address = CNMutablePostalAddress()
        address.street = "1 Main St\nApt 4"
        address.city = "Springfield"
        address.state = "IL"
        address.postalCode = "62701"
        address.country = "USA"
        address.isoCountryCode = "us"
        let contact = CNMutableContact()
        contact.postalAddresses = [labeled(CNLabelHome, address as CNPostalAddress)]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(
            mapped.addresses == [
                Labeled(
                    "home",
                    PostalAddress(
                        street: "1 Main St\nApt 4", city: "Springfield", region: "IL", postcode: "62701",
                        country: "USA", countryCode: "US"))
            ])
    }

    @Test("birthday with and without year; dates; unlabeled date becomes other")
    func dates() {
        let contact = CNMutableContact()
        contact.birthday = DateComponents(month: 12, day: 25)
        contact.dates = [
            labeled(CNLabelDateAnniversary, DateComponents(year: 2005, month: 6, day: 10) as NSDateComponents),
            labeled(nil, DateComponents(month: 1, day: 2) as NSDateComponents),
        ]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(
            mapped.dates == [
                Labeled("birthday", .monthDay(month: 12, day: 25)),
                Labeled("anniversary", .full(year: 2005, month: 6, day: 10)),
                Labeled("other", .monthDay(month: 1, day: 2)),
            ])
    }

    @Test("relations become name-only relationships with mbr types")
    func relations() {
        let contact = CNMutableContact()
        contact.contactRelations = [
            labeled(CNLabelContactRelationFather, CNContactRelation(name: "Bob Smith")),
            labeled(CNLabelContactRelationManager, CNContactRelation(name: "Alex Boss")),
            labeled("Old Roommate", CNContactRelation(name: "Pat")),
            labeled(CNLabelContactRelationFriend, CNContactRelation(name: "  ")),
        ]
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(
            mapped.relationships == [
                RelationshipRef(type: "parent", label: "father", target: .name("Bob Smith")),
                RelationshipRef(type: "reports_to", target: .name("Alex Boss")),
                RelationshipRef(type: "old_roommate", target: .name("Pat")),
            ])
    }

    @Test("organization contacts and notes")
    func organization() {
        let contact = CNMutableContact()
        contact.contactType = .organization
        contact.organizationName = "Acme Corp"
        contact.note = "Line one\n"
        let mapped = AppleContactMapper.canonical(from: contact)
        #expect(mapped.kind == .organization)
        #expect(mapped.body == "Line one\n")
    }

    @Test("image data only when available")
    func image() {
        let contact = CNMutableContact()
        #expect(AppleContactMapper.imageData(of: contact) == nil)
        contact.imageData = Data([0xFF, 0xD8, 0xFF])
        #expect(AppleContactMapper.imageData(of: contact) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test("the fetch key set includes the note key only when entitled")
    func keys() {
        let withNote = AppleContactMapper.keysToFetch(includeNote: true).compactMap { $0 as? String }
        let without = AppleContactMapper.keysToFetch(includeNote: false).compactMap { $0 as? String }
        #expect(withNote.contains(CNContactNoteKey))
        #expect(!without.contains(CNContactNoteKey))
        #expect(without.contains(CNContactUrlAddressesKey))
    }
}

@Suite("Containers")
struct ContainerTests {
    @Test("account kind from container type and name")
    func kinds() {
        #expect(CNContactStoreAdapter.accountKind(type: .cardDAV, name: "iCloud") == .iCloud)
        #expect(CNContactStoreAdapter.accountKind(type: .cardDAV, name: "Google") == .google)
        #expect(CNContactStoreAdapter.accountKind(type: .cardDAV, name: "me@gmail.com") == .google)
        #expect(CNContactStoreAdapter.accountKind(type: .cardDAV, name: "Fastmail") == .cardDAV)
        #expect(CNContactStoreAdapter.accountKind(type: .local, name: "On My Mac") == .local)
        #expect(CNContactStoreAdapter.accountKind(type: .exchange, name: "Work") == .exchange)
    }
}
