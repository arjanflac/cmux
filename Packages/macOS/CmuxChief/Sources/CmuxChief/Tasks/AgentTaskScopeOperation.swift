/// An operation that an enrolled provider session may perform on granted tasks.
public enum AgentTaskScopeOperation: String, Sendable, Codable, CaseIterable, Hashable {
    /// Observe status without reading task content or starting provider work.
    case status
    /// Read task content or results.
    case read
    /// Submit an explicit message to an owned task.
    case send
    /// Request cancellation of an owned task.
    case cancel
    /// Inspect an owned task's details.
    case inspect
    /// Reserve a child under the caller's own task identity.
    case createChild
    /// Report progress or a result for an owned task.
    case report
}
