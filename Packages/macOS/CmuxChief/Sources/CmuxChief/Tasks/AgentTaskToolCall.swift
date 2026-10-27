import Foundation

/// Provider-authenticated identity and arguments for a coordinator dynamic tool call.
public struct AgentTaskToolCall: Sendable {
    /// Exact managed conversation, resolved by the driver rather than model arguments.
    public let taskID: UUID
    /// Provider thread from the live connection.
    public let sessionID: String
    /// Provider turn already accepted by this driver.
    public let providerTurnID: String
    /// Stable provider call identity, used for mutation deduplication.
    public let callID: String
    /// Current transport generation; a replaced connection cannot respond for it.
    public let connectionGeneration: UUID
    /// Bounded JSON arguments without credentials.
    public let arguments: Data
}
