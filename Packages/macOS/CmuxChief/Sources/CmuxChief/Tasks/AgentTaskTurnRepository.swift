import Foundation

/// Stores submission identities and receipts without contacting a provider.
public protocol AgentTaskTurnRepository: Sendable {
    /// Loads unfinished receipts for conservative restart recovery.
    func unfinished() async throws -> [AgentTaskTurnRecord]
    /// Reads an operation even when it is outside the coordinator's bounded history.
    func read(_ operationID: UUID) async throws -> AgentTaskTurnRecord?
    /// Reads the complete ordered receipt history for a conversation on demand.
    func turns(taskID: UUID) async throws -> [AgentTaskTurnRecord]
    /// Saves a transition, rejecting changes to an operation's task, sequence, or exact prompt.
    func save(_ record: AgentTaskTurnRecord) async throws
}

/// Rejects attempts to reuse a durable operation identity for another submission.
public enum AgentTaskTurnRepositoryError: Error {
    /// The existing operation has a different immutable submission payload.
    case conflict
}
