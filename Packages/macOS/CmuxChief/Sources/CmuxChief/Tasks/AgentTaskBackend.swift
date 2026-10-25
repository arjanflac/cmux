import Foundation

/// Executes a managed task through a harness's supported interface.
public protocol AgentTaskBackend: Sendable {
    /// Starts exactly this requested task. Implementations must not silently retry input.
    func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error>
    /// Interrupts only the task identified by `id`.
    func cancel(id: UUID) async throws
}
