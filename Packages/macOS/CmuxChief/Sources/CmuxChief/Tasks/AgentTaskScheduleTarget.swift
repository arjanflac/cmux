import Foundation

/// An exact managed task or an explicit request for a new managed task.
public enum AgentTaskScheduleTarget: Codable, Equatable, Sendable {
    /// A known cmux-owned task ID; the authorizer must verify current ownership before every dispatch.
    case existingTask(UUID)
    /// A new task whose workspace, provider and permissions require authorization before dispatch.
    case newTask(AgentTaskRequest)
}
