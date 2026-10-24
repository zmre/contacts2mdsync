import ContactModel
import Contacts
import Foundation
import Testing

@testable import ContactsAdapter

/// Random edits: the scripting route ends where the framework route does.
@Suite("Scripting card writer: property")
struct ScriptingCardWriterPropertyTests {
    /// Random edits: the scripting route ends where the framework route does.
    @Test("random edits: scripting and framework routes agree (property)")
    func randomEquivalence() throws {
        var random = SplitMix(seed: 42)
        for round in 0..<60 {
            let card = ScriptingCardWriterTests.card()
            let app = FakeScriptingApp(cards: [ScriptingCardWriterTests.cardID: card])
            let edits = Self.randomEdits(&random, round: round)
            let result = try ScriptingCardWriterTests.writer(app).apply([
                .update(cardID: ScriptingCardWriterTests.cardID, edits: edits)
            ])
            #expect(result.failed == [], "round \(round)")
            let saved = try #require(app.saved(ScriptingCardWriterTests.cardID))
            let expected = try ScriptingCardWriterTests.framework(card, edits)
            #expect(ScriptingCardWriterTests.same(saved, expected), "round \(round): \(edits)")
            let kept = Set(expected.phoneNumbers.map(\.identifier)).intersection(card.phoneNumbers.map(\.identifier))
            #expect(kept.isSubset(of: Set(saved.phoneNumbers.map(\.identifier))), "round \(round): ids kept")
        }
    }

    static func randomEdits(_ random: inout SplitMix, round: Int) -> [CardEdit] {
        var edits: [CardEdit] = []
        if Bool.random(using: &random) {
            edits.append(.scalar(.jobTitle, Bool.random(using: &random) ? "T\(round)" : nil))
        }
        if Bool.random(using: &random) { edits.append(.scalar(.givenName, "G\(round)")) }
        var phones = [
            AppleListElement(
                existing: .text("+1 415 555 0100"), existingLabel: "mobile",
                label: Bool.random(using: &random) ? "mobile" : "home", value: .text("+1 415 555 0100")),
            AppleListElement(
                existing: .text("+1 415 555 0199"), existingLabel: "summer_house", label: "summer_house",
                value: .text(Bool.random(using: &random) ? "+1 415 555 0199" : "+1 415 555 01\(round % 90 + 10)")),
        ]
        if Bool.random(using: &random) { phones.removeFirst() }
        if Bool.random(using: &random) {
            phones.append(AppleListElement(label: "work", value: .text("+1 212 555 0\(100 + round)")))
        }
        if Bool.random(using: &random) { edits.append(.list(.phones, phones)) }
        if Bool.random(using: &random) {
            edits.append(
                .list(
                    .emails,
                    Bool.random(using: &random)
                        ? [] : [AppleListElement(label: "other", value: .text("n\(round)@x.example"))]))
        }
        return edits
    }
}

/// Deterministic random numbers (SplitMix64).
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
