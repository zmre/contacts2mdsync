import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Related names through Contacts.app scripting (architecture §6 "Write
/// routing", §8): adding (`make new related name`), deleting (`delete
/// related name id E`), re-pointing in place (`set value of related name id
/// E`) and changing the type (`set label of related name id E`). Against the
/// fake Contacts.app; no Apple Event is sent.
@Suite("Scripted related names: add, delete, re-point, retype")
struct ScriptedRelatedNameTests {
    typealias Code = ContactsScriptingEvents.CardCode
    static let cardID = "C1:ABPerson"

    /// Mara's card as on the user's Mac: `Cora` (child), `Bram` (spouse).
    static func card() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "Mara"
        contact.familyName = "Quill"
        contact.contactRelations = [
            CNLabeledValue(label: CNLabelContactRelationChild, value: CNContactRelation(name: "Cora")),
            CNLabeledValue(label: CNLabelContactRelationSpouse, value: CNContactRelation(name: "Bram")),
        ]
        return contact
    }

    static func existing(_ name: String, _ type: String, label: String? = nil) -> AppleListElement {
        let value = AppleValue.relation(name: name, type: type, label: label)
        return AppleListElement(existing: value, existingLabel: label, label: label, value: value)
    }

    static func after(_ card: CNContact, _ elements: [AppleListElement]) throws -> CNMutableContact {
        let copy = try #require(card.mutableCopy() as? CNMutableContact)
        try CardWriter.apply(.list(.relations, elements), to: copy, includeNote: false)
        return copy
    }

    @Test("a new related name is `make new related name` with its raw Contacts label and name")
    func add() throws {
        let card = Self.card()
        let after = try Self.after(
            card,
            [
                Self.existing("Cora", "child"), Self.existing("Bram", "spouse"),
                AppleListElement(label: nil, value: .relation(name: "Dov Quill", type: "sibling", label: nil)),
            ])
        let plan = ScriptedCardPlan(before: card, after: after)
        #expect(
            plan.commands == [
                .make(
                    Code.relatedName,
                    properties: [
                        ScriptProperty(Code.label, .text(CNLabelContactRelationSibling)),
                        ScriptProperty(Code.value, .text("Dov Quill")),
                    ])
            ])
    }

    @Test("a removed related name is `delete related name id E`; the others are untouched")
    func delete() throws {
        let card = Self.card()
        let after = try Self.after(card, [Self.existing("Cora", "child")])
        let plan = ScriptedCardPlan(before: card, after: after)
        #expect(plan.commands == [.delete(Code.relatedName, id: card.contactRelations[1].identifier)])
    }

    @Test("re-pointing (`Cora` → `Cora Quill`) sets the value in place: no delete, no make")
    func repoint() throws {
        let card = Self.card()
        var cora = Self.existing("Cora", "child")
        cora.value = .relation(name: "Cora Quill", type: "child", label: nil)
        var bram = Self.existing("Bram", "spouse")
        bram.value = .relation(name: "Bram Quill", type: "spouse", label: nil)
        let plan = ScriptedCardPlan(before: card, after: try Self.after(card, [cora, bram]))
        let ids = card.contactRelations.map(\.identifier)
        #expect(
            plan.commands == [
                .setElement(Code.relatedName, id: ids[0], property: ScriptProperty(Code.value, .text("Cora Quill"))),
                .setElement(Code.relatedName, id: ids[1], property: ScriptProperty(Code.value, .text("Bram Quill"))),
            ])
    }

    @Test("a type change (spouse → sibling) or a new label (child → daughter) relabels in place")
    func retype() throws {
        let card = Self.card()
        var cora = Self.existing("Cora", "child")
        cora.label = "daughter"
        cora.value = .relation(name: "Cora", type: "child", label: "daughter")
        var bram = Self.existing("Bram", "spouse")
        bram.value = .relation(name: "Bram", type: "sibling", label: nil)
        let plan = ScriptedCardPlan(before: card, after: try Self.after(card, [cora, bram]))
        let ids = card.contactRelations.map(\.identifier)
        let label = { (text: String) in ScriptProperty(Code.label, .text(text)) }
        #expect(
            plan.commands == [
                .setElement(Code.relatedName, id: ids[0], property: label(CNLabelContactRelationDaughter)),
                .setElement(Code.relatedName, id: ids[1], property: label(CNLabelContactRelationSibling)),
            ])
    }

    @Test("add and delete through the writer: saved as the framework route would, the kept one keeps its id")
    func throughWriter() throws {
        let card = Self.card()
        let app = FakeScriptingApp(cards: [Self.cardID: card])
        let writer = ScriptingCardWriterTests.writer(app)
        let edits: [CardEdit] = [
            .list(
                .relations,
                [
                    Self.existing("Cora", "child"),
                    AppleListElement(label: nil, value: .relation(name: "Dov Quill", type: "sibling", label: nil)),
                ])
        ]
        let update = AppleWriteOperation.update(cardID: Self.cardID, edits: edits)
        let result = try writer.apply([update])
        #expect(result.applied == [update])
        #expect(result.failed == [] && result.skipped == [])
        let saved = try #require(app.saved(Self.cardID))
        #expect(saved.contactRelations.map(\.value.name) == ["Cora", "Dov Quill"])
        #expect(saved.contactRelations.first?.identifier == card.contactRelations.first?.identifier)
        #expect(saved.contactRelations.last?.label == CNLabelContactRelationSibling)
        #expect(ScriptingCardWriterTests.same(saved, try ScriptingCardWriterTests.framework(card, edits)))
    }
}
