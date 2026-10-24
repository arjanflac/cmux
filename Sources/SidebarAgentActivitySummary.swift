import Foundation

enum SidebarAgentActivitySummary {
    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]],
        workingProgramPanelIds: @autoclosure () -> Set<UUID> = []
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(
            statesByPanelId: statesByPanelId(),
            workingProgramPanelIds: workingProgramPanelIds()
        )
    }

    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]],
        workingProgramPanelIds: Set<UUID> = []
    ) -> Int {
        let hookCount = statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { ($1 == .running || $1 == .backgroundWorkPending) ? $0 + 1 : $0 }
        }
        // Shared-server clients can report native terminal activity without
        // per-terminal hook environments. Count that signal once per pane,
        // and do not double-count a pane whose hooks already report activity.
        let nativeCount = workingProgramPanelIds.filter { panelId in
            !(statesByPanelId[panelId]?.values.contains {
                $0 == .running || $0 == .backgroundWorkPending
            } ?? false)
        }.count
        return hookCount + nativeCount
    }
}
