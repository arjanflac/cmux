import Foundation

/// Positive provider acceptance evidence, separate from task admission and completion.
public struct AgentTaskScheduleAcceptance: Codable, Equatable, Sendable {
    /// Confirmed managed task identity.
    public let taskID: UUID
    /// Deterministic occurrence ID passed as the coordinator operation ID.
    public let operationID: UUID
    /// Provider queue, turn or submission receipt; a coordinator `starting` record is insufficient.
    public let providerReference: String

    /// Creates a receipt only after the delivery adapter observes provider acceptance.
    ///
    /// - Parameters:
    ///   - taskID: Confirmed managed task ID.
    ///   - operationID: Occurrence ID supplied to dispatch.
    ///   - providerReference: Nonempty provider evidence, bounded to 4,096 UTF-8 bytes.
    public init(taskID: UUID, operationID: UUID, providerReference: String) {
        self.taskID = taskID
        self.operationID = operationID
        self.providerReference = providerReference
    }
}
