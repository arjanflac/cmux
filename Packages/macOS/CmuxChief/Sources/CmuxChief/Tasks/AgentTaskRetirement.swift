import Foundation

/// Durable local retirement intent following acknowledgement of an exact one-shot result.
///
/// This hides a worker from cmux's active list and releases idle owned resources.
/// It never archives or deletes provider histories: Codex's shared-server archive
/// can shut down loaded threads and their descendants, so it is not used here.
public struct AgentTaskRetirement: Codable, Equatable, Sendable {
    /// The completed operation whose durable result the parent acknowledged.
    public let operationID: UUID
    /// First durable parent acknowledgement time.
    public let acknowledgedAt: Date
    /// Local retirement completion time, nil until idle-resource release succeeds.
    public internal(set) var retiredAt: Date?
    /// Explicit scope; provider sessions and their saved histories remain intact.
    public let scope: String

    init(operationID: UUID, acknowledgedAt: Date) {
        self.operationID = operationID
        self.acknowledgedAt = acknowledgedAt
        scope = "localOnly"
    }
}
