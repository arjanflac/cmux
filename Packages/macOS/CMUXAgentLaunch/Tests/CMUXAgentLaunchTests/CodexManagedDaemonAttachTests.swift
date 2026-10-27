import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexManagedDaemonAttachTests {
    private let session = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
    private func plan(_ arguments: [String]? = nil, accepted: Bool = true) -> CodexManagedDaemonAttachPlan? {
        CodexManagedDaemonAttachPlan.verified(invocation: AgentRestoreInvocation(
            arguments: arguments ?? ["/stock/codex", "resume", session], workingDirectory: "/project",
            environment: ["CODEX_HOME": "/account"], codexResumeSessionID: session),
            sessionID: session, frontendExecutable: "/cmux/Contents/Resources/bin/cmux-codex-quiet",
            stockExecutable: "/stock/codex", workingDirectory: "/project", fallbackHome: "/home",
            verify: { _ in accepted })
    }

    @Test("A verified frontend attaches despite the daemon's writer lock, without granting a stock writer")
    func heldWriterOnlyAdmitsVerifiedFrontend() throws {
        let frontend = try #require(plan())
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: false, indexComplete: true,
            writerLock: .active, managedFrontend: frontend) == .claimLaunch)
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: false, indexComplete: true,
            writerLock: .active) == .refreshEvidence)
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: true, indexComplete: true,
            writerLock: .active, managedFrontend: frontend) == .observeOwner)
        #expect(frontend.arguments == [frontend.frontendExecutable, "resume", session])
        #expect(frontend.environment["CODEX_HOME"] == "/account")
        #expect(frontend.environment["CMUX_QUIET_STOCK_CODEX"] == "/stock/codex")
    }

    @Test("Missing proof and unsupported launches never become attach plans")
    func unsupportedInputFailsClosed() {
        #expect(plan(accepted: false) == nil)
        for tail in [["resume", "other"], ["resume", session, "hello"], ["fork", session],
                     ["resume", session, "--no-daemon"], ["resume", session, "--remote", "unix://other"],
                     ["resume", session, "--cd", "/other"], ["resume", session, "-c", "model_provider=other"]] {
            #expect(plan(["/stock/codex"] + tail) == nil)
        }
        #expect(plan(["/stock/codex", "--model", "gpt-6.1-sol", "resume", session, "-c", "model_reasoning_effort=\"high\""]) != nil)
    }
}
