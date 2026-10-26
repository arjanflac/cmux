import Foundation

/// Small, thread-local guidance for an explicitly managed conversation.
/// Unrelated sessions receive neither this context nor coordinator tools.
enum AgentTaskContext {
    static func text(id: UUID, request: AgentTaskRequest, command: [String]) -> String {
        "This is a coordinator-owned worker. Use cmux_tasks when available for authorized coordination. Inherited environment variables do not identify your terminal or grant coordination access."
    }
}
