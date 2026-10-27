import Testing
@testable import CmuxTerminal

@Suite("Terminal agent orchestration spawn policy")
struct TerminalSurfaceSpawnPolicyTests {
    private func makePolicy() -> TerminalSurfaceSpawnPolicy {
        TerminalSurfaceSpawnPolicy(
            claudeHooksEnabled: true,
            customClaudePath: nil,
            subagentNotificationEnvironmentKey: "CMUX_TEST_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            suppressSubagentNotifications: false,
            cursorHooksEnabled: true,
            geminiHooksEnabled: true,
            kiroHooksEnabled: true,
            kiroNotificationLevel: "all",
            ampHooksEnabled: true,
            shellIntegrationEnabled: true,
            watchGitStatusEnabled: true,
            showPullRequestsEnabled: true
        )
    }

    @Test func automaticEnrollmentDefaultsOff() {
        let policy = makePolicy()
        #expect(policy.agentOrchestrationEnabled == false)
        #expect(policy.agentOrchestrationEnvironmentValue(isRemoteTerminal: false) == "0")
        #expect(policy.codexQuietFrontendEnabled == false)
        #expect(policy.codexHooksEnabled == true)
        #expect(policy.piHooksEnabled == true)
        #expect(policy.computerUseEnabled == true)
        #expect(policy.enabledAgentCommandShims == Set(TerminalSurfaceAgentCommand.allCases))
    }

    @Test(arguments: [true, false], [true, false])
    func enrollmentEnvironmentIsLocalAndIndependentOfQuietMode(
        enabled: Bool, remote: Bool
    ) {
        for quiet in [true, false] {
            var policy = makePolicy()
            let originalShims = policy.enabledAgentCommandShims
            policy.agentOrchestrationEnabled = enabled
            policy.codexQuietFrontendEnabled = quiet

            #expect(policy.agentOrchestrationEnvironmentValue(isRemoteTerminal: remote) == (enabled && !remote ? "1" : "0"))
            #expect(policy.codexQuietFrontendEnabled == quiet)
            #expect(policy.enabledAgentCommandShims == originalShims)
            #expect(policy.claudeHooksEnabled == true)
            #expect(policy.codexHooksEnabled == true)
            #expect(policy.piHooksEnabled == true)
            #expect(policy.computerUseEnabled == true)
            #expect(policy.socketAuthenticationEnvironment.isEmpty)
            #expect(policy.shellIntegrationEnabled == true)
            #expect(policy.watchGitStatusEnabled == true)
            #expect(policy.showPullRequestsEnabled == true)
        }
    }
}
