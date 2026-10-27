import Foundation

/// Persists task receipts, without implicitly restarting providers.
public protocol AgentTaskRepository: Sendable {
    /// Loads recent receipts without opening providers.
    func load() async throws -> [AgentTaskRecord]
    /// Reads a specific receipt, including one outside the recent in-memory history.
    func read(_ id: UUID) async throws -> AgentTaskRecord?
    /// Persists a confirmed transition.
    func save(_ record: AgentTaskRecord) async throws
}

public extension AgentTaskRepository {
    /// Default lookup for small in-memory repositories.
    func read(_ id: UUID) async throws -> AgentTaskRecord? { try await load().first { $0.id == id } }
}
