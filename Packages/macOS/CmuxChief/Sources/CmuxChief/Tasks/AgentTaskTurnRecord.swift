import Foundation

/// A durable receipt for one submission, independent of the conversation's latest result.
public struct AgentTaskTurnRecord: Codable, Equatable, Sendable {
    /// Submission progress; disconnected means acceptance or execution is uncertain.
    public enum Phase: String, Codable, Sendable {
        /// Input has been saved but submission has not begun.
        case admitted
        /// Submission intent was saved before calling the provider.
        case dispatching
        /// The provider confirmed active execution.
        case running
        /// The provider explicitly requested attention; this is not transport uncertainty.
        case needsInput
        /// The provider confirmed successful completion.
        case completed
        /// The provider confirmed cancellation.
        case cancelled
        /// The provider reported failure.
        case failed
        /// Provider acceptance or execution cannot be established; never automatically retry.
        case disconnected

        /// Whether the provider confirmed a terminal state.
        public var isFinished: Bool { self == .completed || self == .cancelled || self == .failed }
        /// Whether a wait can immediately return useful completion or attention information.
        public var isSettled: Bool { isFinished || self == .disconnected || self == .needsInput }
    }

    /// Globally unique submission identity; the initial turn uses its task ID.
    public var operationID: UUID
    /// Stable conversation identity shared by all its turns.
    public var taskID: UUID
    /// One-based position in this conversation.
    public var sequence: Int
    /// Confirmed provider session, when known.
    public var sessionID: String?
    /// Last durable progress state.
    public var phase: Phase
    /// Bounded provider result belonging only to this turn.
    public var result: String?
    /// Bounded diagnostic or attention detail.
    public var detail: String?
    /// Admission time.
    public var createdAt: Date
    /// Most recent transition time.
    public var updatedAt: Date
    // Exact input is private to the receipt store, not a public read-model property.
    let prompt: String

    init(taskID: UUID, request: AgentTaskTurnRequest, sequence: Int, sessionID: String?, now: Date) {
        operationID = request.operationID
        self.taskID = taskID
        self.sequence = sequence
        self.sessionID = sessionID
        prompt = request.prompt
        phase = .admitted
        createdAt = now
        updatedAt = now
    }

    func matches(taskID: UUID, prompt: String) -> Bool { self.taskID == taskID && self.prompt == prompt }

    func disconnectedAfterRestart() -> Self {
        guard !phase.isFinished else { return self }
        var copy = self
        copy.phase = .disconnected
        copy.detail = "restart_unreconciled"
        return copy
    }
}
