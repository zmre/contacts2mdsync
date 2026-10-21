import ContactModel
import Testing

@Suite("ContactModel")
struct ContactModelTests {
    @Test("schema version starts at 1")
    func schemaVersion() {
        #expect(ContactModel.schemaVersion == 1)
    }
}
