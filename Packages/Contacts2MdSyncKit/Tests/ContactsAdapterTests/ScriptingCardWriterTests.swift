import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

// MARK: - Tests

/// Card writes through Contacts.app scripting (architecture §6 "Write
/// routing", spike S15), against the fake Contacts.app above. No real Apple
/// Event is sent, no store is opened, Contacts.app is never launched.
@Suite("Scripting card writer (CardEdit → Contacts.app Apple Events)")
struct ScriptingCardWriterTests {
    static let cardID = "C1:ABPerson"

    static func card() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "Ann"
        contact.familyName = "One"
        contact.jobTitle = "Engineer"
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "ann@home.example" as NSString)]
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 415 555 0100")),
            CNLabeledValue(label: "Summer House", value: CNPhoneNumber(stringValue: "+1 415 555 0199")),
        ]
        contact.urlAddresses = [
            CNLabeledValue(label: SyncStamp.label, value: SyncStamp.url(for: UUID()) as NSString),
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://ann.example" as NSString),
        ]
        let address = CNMutablePostalAddress()
        address.street = "1 Main St"
        address.city = "Springfield"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        contact.contactRelations = [
            CNLabeledValue(label: CNLabelContactRelationSister, value: CNContactRelation(name: "Bea"))
        ]
        contact.instantMessageAddresses = [
            CNLabeledValue(
                label: nil, value: CNInstantMessageAddress(username: "ann", service: CNInstantMessageServiceSkype))
        ]
        return contact
    }

    static func writer(_ app: FakeScriptingApp) -> ScriptingCardWriter {
        ScriptingCardWriter(
            session: ContactsAppSession(sender: app, app: app, sleep: { _ in }, refusals: NotesRefusalMemo()),
            reader: app, visibleTimeout: 0.2, sleep: { _ in })
    }

    /// The framework route: the same edits applied with `CardWriter` to a copy.
    static func framework(_ card: CNContact, _ edits: [CardEdit]) throws -> CNMutableContact {
        let copy = try #require(card.mutableCopy() as? CNMutableContact)
        for edit in edits { try CardWriter.apply(edit, to: copy, includeNote: false) }
        return copy
    }

    /// Both routes' cards compared as the engine sees them (lists as sets: scripting appends at the end).
    static func same(_ lhs: CNContact, _ rhs: CNContact) -> Bool {
        func normalized(_ contact: CNContact) -> CanonicalContact {
            var canonical = AppleContactMapper.canonical(from: contact)
            canonical.emails.sort { "\($0)" < "\($1)" }
            canonical.phones.sort { "\($0)" < "\($1)" }
            canonical.urls.sort { "\($0)" < "\($1)" }
            canonical.addresses.sort { "\($0)" < "\($1)" }
            canonical.im.sort { "\($0)" < "\($1)" }
            canonical.social.sort { "\($0)" < "\($1)" }
            canonical.relationships.sort { "\($0)" < "\($1)" }
            return canonical
        }
        return normalized(lhs) == normalized(rhs)
            && AppleContactMapper.stampID(of: lhs) == AppleContactMapper.stampID(of: rhs)
    }

    @Test("names, job title, in-place phone edit, new email, removed URL: same result as the framework, ids kept")
    func equivalence() throws {
        let card = Self.card()
        let app = FakeScriptingApp(cards: [Self.cardID: card])
        let edits: [CardEdit] = [
            .scalar(.familyName, "Smith"), .scalar(.jobTitle, "CTO"), .scalar(.namePrefix, "Dr."),
            .scalar(.previousFamilyName, "Jones"), .scalar(.phoneticGivenName, "An"), .scalar(.nickname, "Annie"),
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
            .list(
                .emails,
                [
                    AppleListElement(
                        existing: .text("ann@home.example"), existingLabel: "home", label: "home",
                        value: .text("ann@home.example")),
                    AppleListElement(label: "work", value: .text("ann@work.example")),
                ]),
            .list(.urls, []),
        ]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [update])
        #expect(result.failed == [])
        #expect(result.skipped == [])
        let saved = try #require(app.saved(Self.cardID))
        #expect(Self.same(saved, try Self.framework(card, edits)))
        #expect(saved.phoneNumbers.map(\.identifier) == card.phoneNumbers.map(\.identifier), "edited in place")
        #expect(saved.emailAddresses.first?.identifier == card.emailAddresses.first?.identifier)
        #expect(saved.emailAddresses.last?.label == CNLabelWork, "a new value gets the raw Contacts label")
        #expect(saved.urlAddresses.map(\.value) == [card.urlAddresses[0].value], "the stamp URL is kept")
        #expect(app.saves == 1, "one save per card")
    }

    @Test("a value-only edit sends no label; a relabel sends the raw Contacts label")
    func labels() throws {
        let card = Self.card()
        let after = try Self.framework(
            card,
            [
                .list(
                    .phones,
                    [
                        AppleListElement(
                            existing: .text("+1 415 555 0100"), existingLabel: "mobile", label: "mobile",
                            value: .text("+1 415 555 0177")),
                        AppleListElement(
                            existing: .text("+1 415 555 0199"), existingLabel: "summer_house", label: "work",
                            value: .text("+1 415 555 0199")),
                    ])
            ])
        let plan = ScriptedCardPlan(before: card, after: after)
        typealias Code = ContactsScriptingEvents.CardCode
        let mobile = card.phoneNumbers[0].identifier
        let summer = card.phoneNumbers[1].identifier
        #expect(
            Set(plan.commands) == [
                .setElement(Code.phone, id: summer, property: ScriptProperty(Code.label, .text(CNLabelWork))),
                .setElement(Code.phone, id: mobile, property: ScriptProperty(Code.value, .text("+1 415 555 0177"))),
            ])
        #expect(plan.commands.count == 2)
    }

    @Test("stamp, unstamp and group changes through Contacts.app; membership checked first")
    func stampAndGroups() throws {
        let card = Self.card()
        let app = FakeScriptingApp(cards: [Self.cardID: card], groups: ["G1": [Self.cardID], "G2": []])
        let stamp = UUID()
        let operations: [AppleWriteOperation] = [
            .stamp(cardID: Self.cardID, id: stamp),
            .removeMember(cardID: Self.cardID, groupID: "G1"),
            .addMember(cardID: Self.cardID, groupID: "G2"),
            .removeMember(cardID: Self.cardID, groupID: "G2-not-member"),
        ]
        let result = try Self.writer(app).apply(operations)
        #expect(Set(result.applied) == Set(operations))
        #expect(result.scripted.count == operations.count)
        #expect(app.members("G1").isEmpty)
        #expect(app.members("G2") == [Self.cardID])
        let saved = try #require(app.saved(Self.cardID))
        #expect(AppleContactMapper.stampID(of: saved) == stamp)
        #expect(saved.urlAddresses.filter { SyncStamp.isStamp($0.value as String) }.count == 1)
        #expect(saved.urlAddresses.last?.label == SyncStamp.label)
        let unstamped = try Self.writer(app).apply([.removeStamp(cardID: Self.cardID)])
        #expect(unstamped.failed == [])
        #expect(app.saved(Self.cardID).flatMap(AppleContactMapper.stampID(of:)) == nil)
    }

    @Test("addresses, related names and social profiles keep ids; the IM edit is skipped (not scriptable)")
    func structured() throws {
        let card = Self.card()
        card.socialProfiles = [
            CNLabeledValue(
                label: nil,
                value: CNSocialProfile(
                    urlString: nil, username: "ann", userIdentifier: nil, service: CNSocialProfileServiceTwitter))
        ]
        let app = FakeScriptingApp(cards: [Self.cardID: card])
        let sister = try #require(AppleContactMapper.relation(card.contactRelations[0]))
        let edits = Self.structuredEdits(sister)
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let result = try Self.writer(app).apply([update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [edits[3]], "Contacts.app refuses every IM change (S16)")
        #expect(result.skipped.first?.reason == CardScriptingSupport.instantMessageReason)
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.postalAddresses.first?.identifier == card.postalAddresses.first?.identifier)
        #expect(saved.postalAddresses.first?.value.street == "2 Oak Ave")
        #expect(saved.postalAddresses.first?.value.country == "USA")
        #expect(saved.contactRelations.first?.identifier == card.contactRelations.first?.identifier)
        #expect(saved.contactRelations.first?.value.name == "Beatrice")
        #expect(saved.socialProfiles.first?.identifier == card.socialProfiles.first?.identifier)
        #expect(saved.socialProfiles.first?.value.username == "ann2")
        #expect(saved.instantMessageAddresses.map(\.value.username) == ["ann"], "the IMs are left as they were")
    }

    /// An address moved, a relation renamed, a social handle changed, an IM kept plus a new one.
    static func structuredEdits(_ sister: RelationshipRef) -> [CardEdit] {
        [
            .list(
                .addresses,
                [
                    AppleListElement(
                        existing: .address(PostalAddress(street: "1 Main St", city: "Springfield")),
                        existingLabel: "home", label: "home",
                        value: .address(PostalAddress(street: "2 Oak Ave", city: "Springfield", country: "USA")))
                ]),
            .list(
                .relations,
                [
                    AppleListElement(
                        existing: .relation(name: "Bea", type: sister.type, label: sister.label), existingLabel: nil,
                        label: nil, value: .relation(name: "Beatrice", type: sister.type, label: sister.label))
                ]),
            .list(
                .social,
                [
                    AppleListElement(
                        existing: .social(SocialHandle("ann")), existingLabel: "twitter", label: "twitter",
                        value: .social(SocialHandle("ann2")))
                ]),
            .list(
                .im,
                [
                    AppleListElement(
                        existing: .im(IMHandle("ann")), existingLabel: "skype", label: "skype",
                        value: .im(IMHandle("ann"))),
                    AppleListElement(label: "matrix", value: .im(IMHandle("@ann:matrix.org"))),
                ]),
        ]
    }

    @Test(
        "image, birthday, dates, phonetic organization and the note are skipped (needs entitlement or not scriptable)")
    func unsupported() throws {
        let card = Self.card()
        let app = FakeScriptingApp(cards: [Self.cardID: card])
        let edits: [CardEdit] = [
            .image(Data([0xFF, 0xD8])), .birthday(.full(year: 1990, month: 1, day: 2)),
            .list(.dates, [AppleListElement(label: "anniversary", value: .date(.monthDay(month: 3, day: 4)))]),
            .scalar(.phoneticOrganizationName, "Akme"), .note("hi"), .scalar(.jobTitle, "CTO"),
        ]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [update])
        #expect(result.skipped.map(\.edit) == Array(edits.dropLast()))
        #expect(result.skipped.allSatisfy { $0.reason.hasPrefix(CardScriptingSupport.reason) })
        #expect(app.saved(Self.cardID)?.jobTitle == "CTO")
    }
}

/// Sessions, errors and the events themselves.
@Suite("Scripting card writer: session, errors, events")
struct ScriptingCardWriterSessionTests {
    static let cardID = ScriptingCardWriterTests.cardID
    static func card() -> CNMutableContact { ScriptingCardWriterTests.card() }
    static func writer(_ app: FakeScriptingApp) -> ScriptingCardWriter { ScriptingCardWriterTests.writer(app) }

    @Test("a person-level error fails that card (named, via Contacts.app) but still saves; other cards are written")
    func perCardFailure() throws {
        let first = Self.card()
        let second = Self.card()
        let app = FakeScriptingApp(cards: [Self.cardID: first, "C2:ABPerson": second], groups: ["G1": []])
        app.withState { _ = $0.failing.insert(Self.cardID) }
        let edits: [CardEdit] = [
            .list(.emails, [AppleListElement(label: "work", value: .text("ann@work.example"))])
        ]
        let failing = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let join = AppleWriteOperation.addMember(cardID: Self.cardID, groupID: "G1")
        let fine = AppleWriteOperation.update(cardID: "C2:ABPerson", edits: edits)
        let result = try Self.writer(app).apply([failing, join, fine])
        #expect(result.applied == [fine])
        #expect(result.failed.map(\.operation) == [failing, join])
        #expect(result.failed.first?.message.contains("update (emails) via Contacts.app") == true)
        #expect(
            app.saved(Self.cardID)?.emailAddresses.map(\.value) == ["ann@work.example"],
            "what was set before the error is saved, never left pending")
        #expect(app.members("G1").isEmpty)
        #expect(app.saves == 2)
    }

    @Test("no permission (headless, never asked): throws permissionDenied before any write event")
    func notPermitted() throws {
        let app = FakeScriptingApp(cards: [Self.cardID: Self.card()])
        app.withState { $0.permission = -1744 }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [.scalar(.jobTitle, "CTO")])
        #expect {
            try Self.writer(app).apply([update])
        } throws: { error in
            (error as? NotesUnavailableError)?.permissionDenied == true
        }
        #expect(app.events.isEmpty, "not even a count: permission is checked first")
        #expect(app.saved(Self.cardID)?.jobTitle == "Engineer")
    }

    @Test("notes and card writes share one Contacts.app session: one launch, one quit")
    func sharedSession() throws {
        let app = FakeScriptingApp(cards: [Self.cardID: Self.card()], running: false)
        let session = ContactsAppSession(sender: app, app: app, sleep: { _ in }, refusals: NotesRefusalMemo())
        let notes = ScriptingNotesProvider(session: session)
        let cards = ScriptingCardWriter(session: session, reader: app, visibleTimeout: 0.2, sleep: { _ in })
        _ = try cards.apply([.update(cardID: Self.cardID, edits: [.scalar(.jobTitle, "CTO")])])
        _ = try cards.apply([.update(cardID: Self.cardID, edits: [.scalar(.jobTitle, "CEO")])])
        notes.finishSession()
        cards.finishSession()
        #expect(app.withState { $0.launches } == 1)
        #expect(app.withState { $0.quits } == 1)
        #expect(app.events.filter { $0 == "core/cnte" }.count == 1, "readiness checked once per session")
    }

    @Test("a refusal moments ago: write availability answers without launching Contacts.app again")
    func refusalMemo() {
        let app = FakeScriptingApp(cards: [:], running: false)
        app.withState { $0.permission = -1744 }
        let session = ContactsAppSession(sender: app, app: app, sleep: { _ in }, refusals: NotesRefusalMemo())
        let writer = ScriptingCardWriter(session: session, reader: app, visibleTimeout: 0, sleep: { _ in })
        #expect(writer.availability() == .scripting(.notDetermined))
        #expect(app.withState { $0.launches } == 1)
        writer.finishSession()
        #expect(app.withState { $0.quits } == 1, "quit: this session launched it")
        #expect(writer.availability() == .scripting(.notDetermined))
        #expect(app.withState { $0.launches } == 1, "not launched again just to be told again")
    }

    @Test("the framework's 134092 is recognized as a refusal for the card's note")
    func rejection() {
        let operation = AppleWriteOperation.update(cardID: "x", edits: [.scalar(.jobTitle, "CTO")])
        let refused = CNContactStoreAdapter.failure(operation, NSError(domain: NSCocoaErrorDomain, code: 134_092))
        #expect(refused.rejectedForNote)
        #expect(refused.message.contains("134092"))
        #expect(refused.message.hasPrefix("update (job title)"))
        let other = CNContactStoreAdapter.failure(operation, NSError(domain: NSCocoaErrorDomain, code: 134_030))
        #expect(!other.rejectedForNote)
    }

    @Test("events are raw Apple Events with the sdef codes and descriptors (no script source)")
    func eventShapes() throws {
        typealias Code = ContactsScriptingEvents.CardCode
        let set = ScriptCommand.setElement(Code.phone, id: "PH-1", property: ScriptProperty(Code.value, .text("+1")))
            .event(person: "P-1")
        #expect(set.eventClass == ContactsScriptingEvents.fourCC("core"))
        #expect(set.eventID == ContactsScriptingEvents.fourCC("setd"))
        #expect(
            Spec.decode(set.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----")))
                == .property(Code.value, parent: .element(Code.phone, id: "PH-1", parent: .person("P-1"))))
        let add = ScriptCommand.addToGroup("G-1").event(person: "P-1")
        #expect(add.eventClass == ContactsScriptingEvents.fourCC("az00"))
        #expect(add.eventID == ContactsScriptingEvents.fourCC("az44"))
        #expect(Spec.decode(add.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("az45"))) == .group("G-1"))
        let remove = ScriptCommand.removeFromGroup("G-1").event(person: "P-1")
        #expect(remove.eventID == ContactsScriptingEvents.fourCC("az46"))
        #expect(
            Spec.decode(remove.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("az47"))) == .group("G-1"))
    }
}
