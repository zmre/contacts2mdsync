internal import SyncEngine

/// Fixtures, in-memory fakes of the contact store and vault, and helpers
/// shared by the package's test targets. Never linked into the app.
public enum SyncTestSupport {
    /// Engine status a freshly constructed engine is expected to report.
    public static let expectedInitialStatus = SyncEngine.status
}
