import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Durable orchestration delivery")
struct AgentTaskDeliveryTests {
    private func request(parent: UUID? = nil) -> AgentTaskRequest {
        AgentTaskRequest(provider: .codex, prompt: "Fixture", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/"), presentation: .background,
                         parentTaskID: parent, workspaceStableID: UUID())
    }

    @Test func enrollmentDoesNotSubmitAndArchivedLineageSurvivesCachePruning() async throws {
        let repository = TurnFixtureTaskRepository(), backend = TurnFixtureBackend()
        let owner = UUID(), child = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var childRecord = AgentTaskRecord(id: child, request: request(parent: owner), now: date)
        childRecord.phase = .completed; childRecord.result = "Archived result"
        await repository.save(childRecord)
        for offset in 1...101 {
            var recent = AgentTaskRecord(id: UUID(), request: request(), now: date.addingTimeInterval(Double(offset)))
            recent.phase = .completed; recent.result = "Recent"
            await repository.save(recent)
        }
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: { _, _ in UUID() })
        try await coordinator.restore()
        #expect(coordinator.records[child] == nil)
        #expect(coordinator.childTaskIDs(of: owner) == [child])
        #expect(try await coordinator.record(child)?.result == "Archived result")
        let enrollment = try await coordinator.enrollSession(request(), sessionID: "existing-session", id: owner)
        #expect(enrollment.turnCount == 0)
        #expect(enrollment.latestOperationID == nil)
        #expect(await backend.submittedCount == 0)
    }

    @Test func replayRepairsSupersededTurnAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let turns = AgentTaskFileTurnRepository(directory: directory.appendingPathComponent("turns"))
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"))
        let owner = UUID(), child = UUID()
        var first = AgentTaskTurnRecord(taskID: child, request: .init(prompt: "First"), sequence: 1,
                                        sessionID: "same-session", now: Date())
        first.phase = .completed; first.result = "First result"
        var second = AgentTaskTurnRecord(taskID: child, request: .init(prompt: "Second"), sequence: 2,
                                         sessionID: "same-session", now: Date())
        second.phase = .completed; second.result = "Second result"
        try await turns.save(first)
        try await turns.save(second)
        // Simulates a crash after a newer projection replaced the first operation.
        // Repair visits saved operations rather than the current task projection.
        for _ in 0..<2 {
            try await turns.visitReceipts { turn in
                _ = try await journal.appendInbox(ownerTaskID: owner, taskID: turn.taskID,
                    operationID: turn.operationID, phase: .completed, result: turn.result.map(AgentTaskInboxResult.body))
            }
        }
        let events = try await journal.inbox(ownerTaskID: owner)
        #expect(Set(events.map(\.operationID)) == [first.operationID, second.operationID])
        #expect(events.count == 2)
        #expect(Set(events.compactMap { event -> String? in
            if case .body(let text) = event.result { return text }; return nil
        }) == ["First result", "Second result"])
    }

    @Test func passiveReceiptMustPersistBeforeAnotherTurnIsAdmitted() async throws {
        let backend = TurnFixtureBackend(), gate = TurnFixtureGate()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TurnFixtureTaskRepository(), present: { _, _ in UUID() })
        let task = try await coordinator.start(request())
        _ = await backend.submission(task.id)
        try await coordinator.receive(.session("exact-session"), id: task.id)
        coordinator.setReceiptHandler { _, turn in
            if turn.phase == .completed { await gate.hold() }
        }
        let delivery = Task { try await coordinator.receive(.completed("Done"), id: task.id) }
        await gate.waitUntilEntered()
        await #expect(throws: (any Error).self) { try await coordinator.send(task.id, prompt: "Too early") }
        #expect(await backend.submittedCount == 1)
        await gate.open()
        try await delivery.value
        _ = try await coordinator.send(task.id, prompt: "After durable delivery")
        #expect(try await coordinator.record(task.id)?.turnCount == 2)
    }
}
