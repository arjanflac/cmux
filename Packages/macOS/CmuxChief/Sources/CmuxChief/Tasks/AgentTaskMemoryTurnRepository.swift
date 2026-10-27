import Foundation

/// An isolated receipt store for tests and callers that do not request restart persistence.
public actor AgentTaskMemoryTurnRepository: AgentTaskTurnRepository {
    private var records: [UUID: AgentTaskTurnRecord] = [:]

    /// Creates an empty in-memory store.
    public init() {}

    /// Returns receipts without a confirmed terminal state.
    public func unfinished() -> [AgentTaskTurnRecord] { records.values.filter { !$0.phase.isFinished } }

    /// Reads a saved operation.
    /// - Parameter operationID: The exact submission identity.
    /// - Returns: Its receipt, if admitted.
    public func read(_ operationID: UUID) -> AgentTaskTurnRecord? { records[operationID] }

    /// Returns a conversation's receipts in submission order.
    /// - Parameter taskID: The stable conversation identity.
    /// - Returns: All saved turns for this conversation.
    public func turns(taskID: UUID) -> [AgentTaskTurnRecord] {
        records.values.filter { $0.taskID == taskID }.sorted { $0.sequence < $1.sequence }
    }

    /// Saves a transition without allowing identity reuse.
    /// - Parameter record: A newly admitted or updated receipt.
    /// - Throws: ``AgentTaskTurnRepositoryError/conflict`` for a changed payload.
    public func save(_ record: AgentTaskTurnRecord) throws {
        if let old = records[record.operationID] {
            guard old.matches(taskID: record.taskID, prompt: record.prompt), old.sequence == record.sequence else {
                throw AgentTaskTurnRepositoryError.conflict
            }
        }
        records[record.operationID] = record
    }
}
