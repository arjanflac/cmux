import Foundation

/// Authority-owned graph state; reservations outlive ephemeral grants.
struct AgentTaskScopeNode {
    let parentTaskID: UUID?
    let rootTaskID: UUID
    let depth: Int
    let budget: AgentTaskScopeBudget
    var children: Set<UUID> = []
}
