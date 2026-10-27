import Foundation

/// A replayable passive owner inbox event, retained independently of task-cache pruning.
public struct AgentTaskInboxEvent: Codable, Equatable, Sendable {
    /// Stable event ID used for acknowledgement.
    public let id: UUID
    /// Monotonic journal cursor; gaps between an owner's events are expected.
    public internal(set) var sequence: Int64
    /// Managed owner allowed to read and acknowledge the event.
    public let ownerTaskID: UUID
    /// Managed child reporting the event.
    public let taskID: UUID
    /// Exact child turn operation, never the task's currently selected turn.
    public let operationID: UUID
    /// Event kind; uniqueness includes this phase so different phases remain distinct.
    public let phase: AgentTaskRecord.Phase
    /// Optional bounded private result.
    public let result: AgentTaskInboxResult?
    /// First append time, unchanged by duplicate appends.
    public let createdAt: Date
    /// Owner acknowledgement time, without provider effects.
    public internal(set) var acknowledgedAt: Date?

    init(ownerTaskID: UUID, taskID: UUID, operationID: UUID, phase: AgentTaskRecord.Phase,
         result: AgentTaskInboxResult?, now: Date) {
        id = UUID()
        sequence = 0
        self.ownerTaskID = ownerTaskID
        self.taskID = taskID
        self.operationID = operationID
        self.phase = phase
        self.result = result
        createdAt = now
    }
}
