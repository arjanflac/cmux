import Foundation
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarWorkspaceSnapshotTests {
    @Test func nativeWorkingPaneShowsActivityWithoutHookState() {
        #expect(SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [:], workingProgramPanelIds: [UUID()]
        ) == 1)
    }

    @Test func nativeAndHookActivityInSamePaneIsNotDoubleCounted() {
        let pane = UUID()
        #expect(SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [pane: ["codex": .running]], workingProgramPanelIds: [pane]
        ) == 1)
    }

    @Test func hiddenSpinnerDoesNotReadNativeProgramStates() {
        var didRead = false
        func nativePanes() -> Set<UUID> { didRead = true; return [UUID()] }
        #expect(SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
            showsAgentActivity: false, statesByPanelId: [:], workingProgramPanelIds: nativePanes()
        ) == 0)
        #expect(!didRead)
    }

    @MainActor
    @Test func workspaceAgentSpinnerFeatureFlagDefaultsOff() throws {
        let definition = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-workspace-agent-spinner-experiment"
        })
        let suiteName = "cmux.feature.flags.sidebar-workspace-agent-spinner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })

        #expect(!flags.effectiveValue(for: definition))
    }

    @Test func presentationKeyChangesWhenAgentActivityVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentActivity: false)
        let visible = Self.presentationKey(showsAgentActivity: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentActivity)
        #expect(visible.showsAgentActivity)
    }

    @Test func disabledSpinnerDoesNotReadAgentLifecycleStates() {
        var didReadAgentLifecycleStates = false
        let agentLifecycleStates: () -> [UUID: [String: AgentHibernationLifecycleState]] = {
            didReadAgentLifecycleStates = true
            return [
                UUID(): [
                    "codex": .running,
                    "claude_code": .running,
                ],
            ]
        }

        let count = SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
            showsAgentActivity: false,
            statesByPanelId: agentLifecycleStates()
        )

        #expect(count == 0)
        #expect(!didReadAgentLifecycleStates)
    }
}
