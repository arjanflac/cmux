import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Scoped worker rediscovery")
struct AgentTaskWorkerDirectoryRegressionTests {
    @Test func prunedPersistentWorkerCanBeRediscoveredWithoutAProviderRequest() async throws {
        let tasks = TurnFixtureTaskRepository(), backend = TurnFixtureBackend()
        let ownerID = UUID(), childID = UUID(), workspace = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let input = AgentTaskRequest(provider: .claude, prompt: "PRIVATE INITIAL PROMPT", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"), presentation: .background, parentTaskID: ownerID,
            workspaceStableID: workspace, lifecycle: .persistent)
        var child = AgentTaskRecord(id: childID, request: input, now: date)
        child.title = "Architect reviewer"; child.phase = .completed; child.sessionID = "PRIVATE SESSION"
        child.result = "PRIVATE RESULT"
        await tasks.save(child)
        var owner = AgentTaskRecord(id: ownerID, request: input, now: date)
        owner.parentTaskID = nil; owner.phase = .completed
        await tasks.save(owner)
        for index in 1...105 {
            var unrelated = AgentTaskRecord(id: UUID(), request: input, now: date.addingTimeInterval(Double(index)))
            unrelated.parentTaskID = nil; unrelated.phase = .completed
            await tasks.save(unrelated)
        }
        let coordinator = AgentTaskCoordinator(backend: backend, repository: tasks, present: { _, _ in UUID() })
        try await coordinator.restore()
        #expect(coordinator.records[childID] == nil)
        let page = try await coordinator.workers(AgentTaskWorkerDirectoryQuery()) {
            AgentTaskWorkerDirectoryAccess(ownerTaskID: ownerID, workspaceStableID: workspace, allowedTaskIDs: [ownerID, childID])
        }
        #expect(page.workers.map(\.taskID) == [childID])
        #expect(page.workers.first?.reusable == true)
        #expect(page.workers.first?.followUp == .requiresPreflight)
        #expect(await backend.submittedCount == 0)
    }

    @Test func failedCurrentAuthorityCannotReturnDirectoryData() async throws {
        let coordinator = AgentTaskCoordinator(backend: TurnFixtureBackend(), repository: TurnFixtureTaskRepository(), present: { _, _ in UUID() })
        await #expect(throws: AgentTaskScopeError.revoked) {
            try await coordinator.workers(AgentTaskWorkerDirectoryQuery()) { throw AgentTaskScopeError.revoked }
        }
    }
}
