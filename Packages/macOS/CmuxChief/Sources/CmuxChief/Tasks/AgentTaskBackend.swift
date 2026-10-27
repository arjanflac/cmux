import Foundation

/// Executes a managed task through a harness's supported interface.
public protocol AgentTaskBackend: Sendable {
    /// Starts exactly this requested task. Implementations must not silently retry input.
    func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error>
    /// Submits once to the exact saved session; implementations must never create a fallback session.
    ///
    /// - Parameters:
    ///   - id: Stable conversation identity used by start and cancel.
    ///   - record: Saved provider identity and original execution options.
    ///   - request: Explicit input and operation identity for this turn.
    /// - Returns: Events scoped to this submission, never a replay of previous turns.
    /// - Throws: Submission errors, including unsupported continuation.
    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error>
    /// Releases resources only after the exact managed worker is idle; never deletes provider history.
    func releaseIdleResources(id: UUID) async throws
    /// Interrupts only the task identified by `id`.
    func cancel(id: UUID) async throws
}

public extension AgentTaskBackend {
    /// Legacy backends retain no resources; releasing them has no provider effect.
    func releaseIdleResources(id: UUID) async throws {}

    /// Rejects continuation for legacy backends instead of silently starting a fresh session.
    /// - Parameters:
    ///   - id: Existing conversation identity.
    ///   - record: Its confirmed provider session and options.
    ///   - request: The proposed submission.
    /// - Returns: No stream; this default always throws.
    /// - Throws: ``AgentTaskContinuationError/unsupported``.
    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        throw AgentTaskContinuationError.unsupported
    }
}

/// A backend cannot safely continue this saved conversation.
public enum AgentTaskContinuationError: Error {
    /// This backend only implements initial submission.
    case unsupported
}
