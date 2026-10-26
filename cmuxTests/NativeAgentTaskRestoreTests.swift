import CmuxChief
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Native managed task restoration")
struct NativeAgentTaskRestoreTests {
    @Test func nativeCodexBindingProjectsItsExactSavedSession() throws {
        let session = UUID().uuidString
        let binding = NativeAgentTaskHost.resumeBinding(provider: .codex, sessionID: session,
            cwd: "/products/lightwell", model: "gpt-6-luna", title: "Fixture")
        #expect(binding.isAgentHookBinding)
        #expect(binding.allowsAutomaticResume)
        let agent = try #require(binding.managedRestorableAgentSnapshot(replacing: nil))
        #expect(agent.sessionId == session)
        #expect(agent.workingDirectory == "/products/lightwell")
        #expect(binding.launchCommand?.arguments == ["codex", "resume", session, "--model", "gpt-6-luna"])
        #expect(binding.command.contains(session))
        #expect(!binding.command.contains("&&"))
    }

    @Test func nativeClaudeBindingResumesWithoutAnInitialPrompt() {
        let session = UUID().uuidString
        let binding = NativeAgentTaskHost.resumeBinding(provider: .claude, sessionID: session,
            cwd: "/repo", model: nil, title: "Fixture prompt must never be submitted")
        #expect(binding.launchCommand?.arguments == ["claude", "--resume", session, "--permission-mode", "bypassPermissions"])
        #expect(!binding.command.contains("Fixture prompt"))
        #expect(binding.isAgentHookBinding)
    }
    @Test func onlyTrustedCompleteCodexBindingsAdmitObservation() {
        var binding = NativeAgentTaskHost.resumeBinding(provider: .codex,
            sessionID: "01a176fc-d044-7e62-92bb-de6c5c50c0d1", cwd: "/tmp", model: nil, title: "Fixture")
        #expect(NativeAgentTaskRuntime.observedSession(binding) == "01a176fc-d044-7e62-92bb-de6c5c50c0d1")
        binding.source = "session-import"
        #expect(NativeAgentTaskRuntime.observedSession(binding) == nil)
        binding.source = "cli"
        #expect(NativeAgentTaskRuntime.observedSession(binding) == nil)
    }

}
