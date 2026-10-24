import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Instant messages through Contacts.app scripting (spike S16): Contacts.app
/// answers `-1728` for `instant message id E`, so the writer falls back to
/// `first instant message whose user name = … and service type = …`; an
/// element that resolves neither way is left out (its edit reported
/// skipped) while the rest of the card is applied. Against the fake
/// Contacts.app only: no Apple Event is sent, Contacts.app is never launched.
@Suite("Scripting card writer: instant messages and unresolvable elements")
struct ScriptingCardWriterIMTests {
    static let cardID = ScriptingCardWriterTests.cardID
    typealias Code = ContactsScriptingEvents.CardCode

    static func writer(_ app: FakeScriptingApp) -> ScriptingCardWriter { ScriptingCardWriterTests.writer(app) }

    /// The card's Skype IM `ann` (label `skype`) becomes `value`/`label`, and its address moves.
    static func edits(im value: String, label: String = "skype") -> [CardEdit] {
        [
            .scalar(.jobTitle, "CTO"),
            .list(
                .addresses,
                [
                    AppleListElement(
                        existing: .address(PostalAddress(street: "1 Main St", city: "Springfield")),
                        existingLabel: "home", label: "home",
                        value: .address(PostalAddress(street: "2 Oak Ave", city: "Springfield")))
                ]),
            .list(
                .im,
                [
                    AppleListElement(
                        existing: .im(IMHandle("ann")), existingLabel: "skype", label: label,
                        value: .im(IMHandle(value)))
                ]),
        ]
    }

    static func app(_ configure: (inout FakeScriptingApp.State) -> Void = { _ in }) -> FakeScriptingApp {
        let app = FakeScriptingApp(cards: [Self.cardID: ScriptingCardWriterTests.card()])
        app.withState(configure)
        return app
    }

    @Test("IM unresolvable by id: edited in place through `first instant message whose`, id kept")
    func whoseFallback() throws {
        let app = Self.app { $0.imByIDUnresolvable = true }
        let before = try #require(app.saved(Self.cardID)?.instantMessageAddresses.first)
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: Self.edits(im: "ann2"))
        let writer = Self.writer(app)
        let result = try writer.apply([update])
        #expect(result.applied == [update])
        #expect(result.scripted == [update])
        #expect(result.failed == [])
        #expect(result.skipped == [])
        #expect(writer.elementLog == ScriptingCardWriter.ElementLog(byMatch: 1, unresolved: 0))
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.instantMessageAddresses.map(\.identifier) == [before.identifier], "edited in place")
        #expect(saved.instantMessageAddresses.first?.value.username == "ann2")
        #expect(saved.instantMessageAddresses.first?.value.service == CNInstantMessageServiceSkype)
        #expect(saved.postalAddresses.first?.value.street == "2 Oak Ave")
        #expect(saved.jobTitle == "CTO")
        #expect(app.saves == 1)
    }

    @Test("several commands on one IM: each `whose` uses the values the previous command set")
    func whoseFollowsChanges() throws {
        let app = Self.app { $0.imByIDUnresolvable = true }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: Self.edits(im: "ann3", label: "jabber"))
        let result = try Self.writer(app).apply([update])
        #expect(result.failed == [])
        #expect(result.skipped == [])
        let saved = try #require(app.saved(Self.cardID)?.instantMessageAddresses.first?.value)
        #expect(saved.username == "ann3")
        #expect(saved.service == CNInstantMessageServiceJabber)
        let byID = app.events.filter { $0 == "core/setd" }.count
        #expect(byID == 1 + 1 + 1 + 2, "job title, address street, the failed IM-by-id try, then two `whose` sets")
    }

    @Test("an IM removed while unresolvable by id: deleted through `whose`")
    func whoseDelete() throws {
        let app = Self.app { $0.imByIDUnresolvable = true }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [.list(.im, [])])
        let result = try Self.writer(app).apply([update])
        #expect(result.failed == [])
        #expect(result.skipped == [])
        #expect(app.saved(Self.cardID)?.instantMessageAddresses.isEmpty == true)
    }

    @Test("IM unresolvable either way: only the IM edit is skipped; the other edits are applied, card not failed")
    func unresolvableSkipped() throws {
        let app = Self.app {
            $0.imByIDUnresolvable = true
            $0.imWhoseUnresolvable = true
        }
        let edits = Self.edits(im: "ann2")
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let writer = Self.writer(app)
        let result = try writer.apply([update])
        #expect(writer.elementLog == ScriptingCardWriter.ElementLog(byMatch: 0, unresolved: 1))
        #expect(result.applied == [update], "partial application: the operation counts as applied")
        #expect(result.scripted == [update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [edits[2]])
        #expect(result.skipped.first?.reason == "\(ScriptingCardWriter.unresolvedReason) (im)")
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.jobTitle == "CTO")
        #expect(saved.postalAddresses.first?.value.street == "2 Oak Ave")
        #expect(saved.instantMessageAddresses.first?.value.username == "ann", "the IM is left as it was")
        #expect(!app.events.contains("core/getd"), "the job title already showed that the person resolves")
        #expect(app.saves == 1)
    }

    @Test("only an unresolvable IM edit: the person is checked first, then the IM edit is skipped")
    func unresolvableOnly() throws {
        let app = Self.app {
            $0.imByIDUnresolvable = true
            $0.imWhoseUnresolvable = true
        }
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [.list(.im, [])])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [.list(.im, [])])
        #expect(app.events.filter { $0 == "core/getd" }.count == 1)
        #expect(app.saved(Self.cardID)?.instantMessageAddresses.count == 1)
    }

    @Test("two IMs with the same user name and service: no `whose` form (it could pick the other); skipped")
    func duplicatesNotMatched() throws {
        let card = ScriptingCardWriterTests.card()
        card.instantMessageAddresses.append(
            CNLabeledValue(
                label: CNLabelWork,
                value: CNInstantMessageAddress(username: "ann", service: CNInstantMessageServiceSkype)
            ))
        let app = FakeScriptingApp(cards: [Self.cardID: card])
        app.withState { $0.imByIDUnresolvable = true }
        let after = try ScriptingCardWriterTests.framework(card, [.list(.im, [])])
        #expect(ScriptedCardPlan(before: card, after: after).matches.isEmpty)
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: [.list(.im, [])])
        let result = try Self.writer(app).apply([update])
        #expect(result.failed == [])
        #expect(result.skipped.map(\.edit) == [.list(.im, [])])
        #expect(app.saved(Self.cardID)?.instantMessageAddresses.count == 2)
    }

    @Test("the person itself does not resolve: the card fails (an element -1728 is not a skip then)")
    func missingPersonFails() throws {
        let app = Self.app { $0.missingPeople = [Self.cardID] }
        let update = AppleWriteOperation.update(
            cardID: Self.cardID, edits: [.list(.im, []), .list(.emails, [])])
        let result = try Self.writer(app).apply([update])
        #expect(result.applied == [])
        #expect(result.failed.map(\.operation) == [update])
        #expect(result.skipped == [])
    }

    @Test("an unresolvable element of no list edit (the stamp URL on unstamp) fails the card")
    func unattributableFails() throws {
        let unit = ScriptingCardWriter.Unit(cardID: Self.cardID, operations: [.removeStamp(cardID: Self.cardID)])
        let error = ContactsScriptingError(number: -1728, message: "Can't get url.")
        #expect(throws: ContactsScriptingError.self) {
            try ScriptingCardWriter.unresolvedSkips([Code.url: error], of: unit)
        }
        let withEdit = ScriptingCardWriter.Unit(
            cardID: Self.cardID, operations: [.update(cardID: Self.cardID, edits: [.list(.urls, [])])])
        #expect(try ScriptingCardWriter.unresolvedSkips([Code.url: error], of: withEdit).count == 1)
    }

    @Test("the `whose` event is AppleScript's `first <element> whose a = x and b = y` specifier")
    func whoseEventShape() throws {
        let match = ElementMatch(
            element: Code.instantMessage,
            terms: [
                ScriptProperty(Code.serviceType, .enumerated(Code.serviceSkype)),
                ScriptProperty(Code.userName, .text("ann")),
            ])
        let command = ScriptCommand.setElement(
            Code.instantMessage, id: "IM-1", property: ScriptProperty(Code.userName, .text("ann2")))
        let event = try #require(command.event(person: "P-1", matching: match))
        #expect(event.eventID == ContactsScriptingEvents.fourCC("setd"))
        #expect(
            Spec.decode(event.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----")))
                == .property(
                    Code.userName, parent: .firstWhose(Code.instantMessage, terms: match.terms, parent: .person("P-1")))
        )
        let delete = try #require(
            ScriptCommand.delete(Code.instantMessage, id: "IM-1").event(person: "P-1", matching: match))
        #expect(
            Spec.decode(delete.paramDescriptor(forKeyword: ContactsScriptingEvents.fourCC("----")))
                == .firstWhose(Code.instantMessage, terms: match.terms, parent: .person("P-1")))
        #expect(ScriptCommand.make(Code.instantMessage, properties: []).event(person: "P-1", matching: match) == nil)
    }
}
