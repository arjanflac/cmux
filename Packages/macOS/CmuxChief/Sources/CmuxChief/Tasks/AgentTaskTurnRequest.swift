import Foundation

/// One explicit submission to an existing managed conversation.
public struct AgentTaskTurnRequest: Codable, Equatable, Sendable {
    /// Globally unique idempotency key; reuse requires the identical task and prompt.
    public var operationID: UUID
    /// Provider input, limited by the coordinator to 200,000 UTF-8 bytes.
    public var prompt: String

    /// Creates a submission with a fresh operation identity by default.
    ///
    /// - Parameters:
    ///   - operationID: A caller-retained key for safe receipt lookup and deduplication.
    ///   - prompt: The exact input to submit once.
    public init(operationID: UUID = UUID(), prompt: String) {
        self.operationID = operationID
        self.prompt = prompt
    }
}
