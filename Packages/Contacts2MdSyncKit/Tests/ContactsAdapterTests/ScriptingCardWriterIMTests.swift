import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Instant messages and refused elements through Contacts.app scripting
/// (spike S16): Contacts.app resolves `instant message id E` but refuses
/// every change to it (`-1719`), so IM edits are skipped up front and no
/// IM event is sent; any element command Contacts.app refuses leaves only
/// that element out (its edit reported skipped with the error) while the
/// rest of the card is applied. Against the fake Contacts.app only: no
/// Apple Event is sent, Contacts.app is never launched.
@Suite("Scripting card writer: instant messages and refused elements")
struct ScriptingCardWriterIMTests {
    static let cardID = ScriptingCardWriterTests.cardID
    typealias Code = ContactsScriptingEvents.CardCode

    static func writer(_ app: FakeScriptingApp) -> ScriptingCardWriter { ScriptingCardWriterTests.writer(app) }

    static let jobTitle = CardEdit.scalar(.jobTitle, "CTO")
    /// The card's home address moves to 2 Oak Ave.
    static let address = CardEdit.list(
        .addresses,
        [
            AppleListElement(
                existing: .address(PostalAddress(street: "1 Main St", city: "Springfield")),
                existingLabel: "home", label: "home",
                value: .address(PostalAddress(street: "2 Oak Ave", city: "Springfield")))
        ])
    /// The card's Skype IM `ann` becomes `ann2`.
    static let instantMessage = CardEdit.list(
        .im,
        [
            AppleListElement(
                existing: .im(IMHandle("ann")), existingLabel: "skype", label: "skype", value: .im(IMHandle("ann2")))
        ])
    /// A new work email.
    static let email = CardEdit.list(
        .emails,
        [
            AppleListElement(
                existing: .text("ann@home.example"), existingLabel: "home", label: "home",
                value: .text("ann@home.example")),
            AppleListElement(label: "work", value: .text("ann@work.example")),
        ])

    static func app(_ configure: (inout FakeScriptingApp.State) -> Void = { _ in }) -> FakeScriptingApp {
        let app = FakeScriptingApp(cards: [Self.cardID: ScriptingCardWriterTests.card()])
        app.withState(configure)
        return app
    }

    // MARK: Instant messages

    @Test("an IM edit is skipped up front (needs the notes entitlement): no IM event, the rest applied")
    func instantMessageSkipped() throws {
        let app = Self.app()
        let edits = [Self.jobTitle, Self.address, Self.instantMessage]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let writer = Self.writer(app)
        let result = try writer.apply([update])
        #expect(result.applied == [update], "partial application: the operation counts as applied")
        #expect(result.scripted == [update])
        #expect(result.failed == [])
        #expect(
            result.skipped == [
                AppleWriteSkip(
                    operation: update, edit: Self.instantMessage, reason: CardScriptingSupport.instantMessageReason)
            ])
        #expect(
            CardScriptingSupport.instantMessageReason
                == "instant messages can't be changed through Contacts.app (needs the notes entitlement)")
        #expect(!app.elementCommands.contains(Code.instantMessage), "no Apple Event is sent for an IM")
        #expect(writer.elementLog.sent[Code.instantMessage] == nil)
        #expect(writer.elementLog.refused == 0)
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.jobTitle == "CTO")
        #expect(saved.postalAddresses.first?.value.street == "2 Oak Ave")
        #expect(saved.instantMessageAddresses.first?.value.username == "ann", "the IM is left as it was")
        #expect(app.saves == 1)
    }

    @Test("IM-only edits (change, add, delete): skipped, card applied, no IM event and nothing to save")
    func instantMessageOnly() throws {
        let edits: [[CardEdit]] = [
            [Self.instantMessage],
            [.list(.im, [AppleListElement(label: "jabber", value: .im(IMHandle("ann@jabber.example")))])],
            [.list(.im, [])],
        ]
        for edit in edits {
            let app = Self.app()
            let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edit)
            let result = try Self.writer(app).apply([update])
            #expect(result.applied == [update])
            #expect(result.failed == [])
            #expect(result.skipped.map(\.edit) == edit)
            #expect(result.skipped.allSatisfy { $0.reason == CardScriptingSupport.instantMessageReason })
            #expect(app.elementCommands.isEmpty)
            #expect(app.events.isEmpty || app.events == ["core/cnte"], "no write event at all")
            #expect(app.saved(Self.cardID)?.instantMessageAddresses.map(\.value.username) == ["ann"])
        }
    }

    @Test("the scripted plan never contains an IM command, even when the IMs differ")
    func planHasNoIMCommands() throws {
        let card = ScriptingCardWriterTests.card()
        let after = try #require(card.mutableCopy() as? CNMutableContact)
        after.instantMessageAddresses = [
            CNLabeledValue(
                label: CNLabelWork,
                value: CNInstantMessageAddress(username: "x", service: CNInstantMessageServiceJabber))
        ]
        #expect(ScriptedCardPlan(before: card, after: after).commands.isEmpty)
    }

    // MARK: Refused elements

    @Test(
        "an element error (-1719, -1728, -10000, -10006, -1708) on the address: only it is skipped, card applied",
        arguments: [-1719, -1728, -10000, -10006, -1708])
    func refusedElementSkipped(error: Int) throws {
        let app = Self.app { $0.elementErrors[Code.address] = error }
        let edits = [Self.jobTitle, Self.address, Self.email]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let writer = Self.writer(app)
        let result = try writer.apply([update])
        #expect(result.applied == [update], "partial application: applied + skipped, not failed")
        #expect(result.scripted == [update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [Self.address])
        let reason = try #require(result.skipped.first?.reason)
        #expect(reason.hasPrefix("Contacts.app could not change this addresses element"))
        #expect(reason.contains("\(error)"), "the error is in the reason")
        #expect(writer.elementLog.refused == 1)
        #expect(writer.elementLog.sent[Code.email] == 1)
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.jobTitle == "CTO")
        #expect(
            saved.emailAddresses.map(\.value) == ["ann@home.example", "ann@work.example"], "later elements still sent")
        #expect(saved.postalAddresses.first?.value.street == "1 Main St")
        #expect(app.events.filter { $0 == "core/getd" }.count == 1, "the person is checked once, after the error")
        #expect(app.saves == 1)
    }

    @Test("a refused element's other commands are not sent (the street set fails: city, label not tried)")
    func refusedElementLeftOut() throws {
        let app = Self.app { $0.elementErrors[Code.address] = -1719 }
        let moved = CardEdit.list(
            .addresses,
            [
                AppleListElement(
                    existing: .address(PostalAddress(street: "1 Main St", city: "Springfield")),
                    existingLabel: "home", label: "work",
                    value: .address(PostalAddress(street: "2 Oak Ave", city: "Shelbyville")))
            ])
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [moved])
        let result = try Self.writer(app).apply([update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [moved])
        #expect(app.elementCommands == [Code.address], "one try, then the element is left out")
    }

    @Test("a refused new element (make) is skipped too; the card applies")
    func refusedMakeSkipped() throws {
        let app = Self.app { $0.elementErrors[Code.email] = -10000 }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [Self.jobTitle, Self.email])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [Self.email])
        #expect(app.saved(Self.cardID)?.jobTitle == "CTO")
        #expect(app.saved(Self.cardID)?.emailAddresses.count == 1)
    }

    @Test("IM skipped up front and a refused address in one batch: both skipped, the rest applied")
    func imAndRefusedTogether() throws {
        let app = Self.app { $0.elementErrors[Code.address] = -1719 }
        let edits = [Self.jobTitle, Self.address, Self.email, Self.instantMessage]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [update])
        #expect(result.failed == [])
        #expect(Set(result.skipped.map(\.edit)) == [Self.address, Self.instantMessage])
        #expect(app.saved(Self.cardID)?.emailAddresses.count == 2)
        #expect(!app.elementCommands.contains(Code.instantMessage))
    }

    // MARK: Person-level failures

    @Test("the person itself does not resolve: the card fails (an element error is not a skip then)")
    func missingPersonFails() throws {
        let app = Self.app { $0.missingPeople = [Self.cardID] }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [.list(.emails, [])])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [])
        #expect(result.failed.map(\.operation) == [update])
        #expect(result.skipped == [])
    }

    @Test("a refused element whose person no longer resolves fails the card")
    func refusedThenPersonGoneFails() throws {
        let app = Self.app {
            $0.elementErrors[Code.address] = -1719
            $0.missingPeople = [Self.cardID]
        }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [Self.address])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [])
        #expect(result.failed.map(\.operation) == [update])
    }

    @Test("a failing save fails the card")
    func saveFails() throws {
        let app = Self.app { $0.saveError = -10000 }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [Self.jobTitle])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [])
        #expect(result.failed.map(\.operation) == [update])
    }

    @Test("a person-level command error (person property, group) fails the card")
    func personCommandFails() throws {
        let app = Self.app { _ = $0.failing.insert(Self.cardID) }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [Self.jobTitle, Self.email])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [])
        #expect(result.failed.map(\.operation) == [update])
        #expect(result.skipped == [])
    }

    @Test("a refused element of no list edit (the stamp URL on unstamp) fails the card")
    func unattributableFails() throws {
        let unit = ScriptingCardWriter.Unit(cardID: Self.cardID, operations: [.removeStamp(cardID: Self.cardID)])
        let error = ContactsScriptingError(number: -1719, message: "Apple Event failed")
        #expect(throws: ContactsScriptingError.self) {
            try ScriptingCardWriter.refusedSkips([Code.url: error], of: unit)
        }
        let withEdit = ScriptingCardWriter.Unit(
            cardID: Self.cardID, operations: [.update(cardID: Self.cardID, edits: [.list(.urls, [])])])
        #expect(try ScriptingCardWriter.refusedSkips([Code.url: error], of: withEdit).count == 1)

        let app = Self.app { $0.elementErrors[Code.url] = -1719 }
        let result = try Self.writer(app).apply([.removeStamp(cardID: Self.cardID)])
        #expect(result.failed.map(\.operation) == [.removeStamp(cardID: Self.cardID)])
    }
}
