import Foundation

/// The provider's identity for the live turn of a managed task.
public struct AgentManagedTurnIdentity: Sendable, Equatable {
    /// The cmux operation this turn submitted.
    public let operationID: UUID
    /// The exact provider session (Codex thread).
    public let sessionID: String
    /// The provider-confirmed turn identity returned by acceptance.
    public let providerTurnID: String
    /// Whether the provider steered the input into a turn that started before this submission.
    ///
    /// Codex `turn/start` starts or steers; a concurrent client (for example the
    /// phone) can win the idle check. The returned turn is still the provider's
    /// actual turn for this input, so its outcome is reported, flagged here.
    public let joinedExistingTurn: Bool
}
