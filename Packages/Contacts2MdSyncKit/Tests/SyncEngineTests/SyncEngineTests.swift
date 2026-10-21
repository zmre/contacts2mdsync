import SyncEngine
import SyncTestSupport
import Testing

@Suite("SyncEngine")
struct SyncEngineTests {
    @Test("engine starts idle")
    func initialStatus() {
        #expect(SyncEngine.status == SyncTestSupport.expectedInitialStatus)
        #expect(SyncEngine.schemaVersion == 1)
    }
}
