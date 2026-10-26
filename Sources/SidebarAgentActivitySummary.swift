import Foundation

enum SidebarAgentActivitySummary {
    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]],
        workingProgramPanelIds: @autoclosure () -> Set<UUID> = [],
        authoritativeActivityByPanelID: @autoclosure () -> [UUID: Bool] = [:]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(
            statesByPanelId: statesByPanelId(),
            workingProgramPanelIds: workingProgramPanelIds(),
            authoritativeActivityByPanelID: authoritativeActivityByPanelID()
        )
    }

    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]],
        workingProgramPanelIds: Set<UUID> = [],
        authoritativeActivityByPanelID: [UUID: Bool] = [:]
    ) -> Int {
        // A stock frontend can switch chats without publishing a new binding.
        // Its positive native signal must beat an older saved chat's idle state.
        let authoritativeActivityByPanelID = authoritativeActivityByPanelID.filter {
            $0.value || !workingProgramPanelIds.contains($0.key)
        }
        let hookCount = statesByPanelId.reduce(0) { partial, entry in
            if authoritativeActivityByPanelID[entry.key] != nil { return partial }
            return partial + entry.value.values.reduce(0) { ($1 == .running || $1 == .backgroundWorkPending) ? $0 + 1 : $0 }
        }
        // Shared-server clients can report native terminal activity without
        // per-terminal hook environments. Count that signal once per pane,
        // and do not double-count a pane whose hooks already report activity.
        let nativeCount = workingProgramPanelIds.filter { panelId in
            authoritativeActivityByPanelID[panelId] == nil && !(statesByPanelId[panelId]?.values.contains {
                $0 == .running || $0 == .backgroundWorkPending
            } ?? false)
        }.count
        return hookCount + nativeCount + authoritativeActivityByPanelID.values.filter { $0 }.count
    }
}
