import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Persistent managed conversation turns")
struct AgentTaskTurnTests {
    private func request() -> AgentTaskRequest {
        AgentTaskRequest(provider: .codex, prompt: "Initial prompt", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), model: "fixture-model",
                         effort: "high", presentation: .background)
    }

    private func makeCoordinator(_ backend: TurnFixtureBackend, tasks: TurnFixtureTaskRepository = TurnFixtureTaskRepository(),
                             turns: any AgentTaskTurnRepository = AgentTaskMemoryTurnRepository()) -> AgentTaskCoordinator {
        AgentTaskCoordinator(backend: backend, repository: tasks, present: { _, _ in
            Issue.record("Background turns must not open terminals")
            return UUID()
        }, turnRepository: turns)
    }

    private func completed(_ coordinator: AgentTaskCoordinator, backend: TurnFixtureBackend) async throws -> UUID {
        let record = try await coordinator.start(request())
        _ = await backend.submission(record.id)
        try await coordinator.receive(.session("fixed-provider-session"), id: record.id)
        try await coordinator.receive(.completed("First result"), id: record.id)
        return record.id
    }

    private func observe(_ event: AgentTaskEvent, operationID: UUID, taskID: UUID,
                         phase: AgentTaskRecord.Phase, coordinator: AgentTaskCoordinator,
                         backend: TurnFixtureBackend) async {
        let changes = coordinator.changes()
        await backend.emit(event, operationID: operationID)
        for await record in changes where record.id == taskID && record.latestOperationID == operationID && record.phase == phase { return }
    }

    @Test func twoTurnsKeepConversationSessionAndOptionsAndIndependentResults() async throws {
        let backend = TurnFixtureBackend(), turns = AgentTaskMemoryTurnRepository()
        let coordinator = makeCoordinator(backend, turns: turns)
        let taskID = try await completed(coordinator, backend: backend)
        let operationID = UUID()
        let next = try await coordinator.send(taskID, prompt: "Follow up", operationID: operationID)
        let submission = await backend.submission(operationID)
        #expect(submission.taskID == taskID)
        #expect(submission.record?.sessionID == "fixed-provider-session")
        #expect(submission.record?.model == "fixture-model")
        #expect(submission.record?.effort == "high")
        #expect(submission.prompt == "Follow up")
        #expect(next.sequence == 2)
        #expect(next.phase == .dispatching)
        await observe(.completed("Second result"), operationID: operationID, taskID: taskID,
                      phase: .completed, coordinator: coordinator, backend: backend)
        #expect(try await coordinator.turn(taskID)?.result == "First result")
        #expect(try await coordinator.turn(operationID)?.result == "Second result")
        #expect(try await coordinator.record(taskID)?.result == "Second result")
        #expect(try await coordinator.record(taskID)?.sessionID == "fixed-provider-session")
        #expect(try await coordinator.turns(taskID: taskID).map(\.operationID) == [taskID, operationID])
        #expect(await backend.submittedCount == 2)
    }

    @Test func deduplicationIncludesInitialTurnAndRejectsPayloadOrTaskReuse() async throws {
        let backend = TurnFixtureBackend(), coordinator = makeCoordinator(backend)
        let taskID = try await completed(coordinator, backend: backend)
        #expect(try await coordinator.send(taskID, prompt: request().prompt, operationID: taskID).result == "First result")
        let operationID = UUID()
        _ = try await coordinator.send(taskID, prompt: "Once", operationID: operationID)
        _ = await backend.submission(operationID)
        let duplicate = try await coordinator.send(taskID, prompt: "Once", operationID: operationID)
        #expect(duplicate.operationID == operationID)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Different", operationID: operationID) }
        await #expect(throws: (any Error).self) { try await coordinator.send(UUID(), prompt: "Once", operationID: operationID) }
        await #expect(throws: (any Error).self) { try await coordinator.start(request(), id: operationID) }
        #expect(await backend.submittedCount == 2)
        try await coordinator.cancel(taskID)
    }

    @Test func admissionReservesConversationBeforePersistenceAwaitsAndJoinsIdenticalRetries() async throws {
        let backend = TurnFixtureBackend(), turns = TurnFixtureRepository()
        let coordinator = makeCoordinator(backend, turns: turns)
        let taskID = try await completed(coordinator, backend: backend)
        let gate = TurnFixtureGate(), operationID = UUID()
        await turns.holdAdmission(operationID, gate: gate)
        let first = Task { try await coordinator.send(taskID, prompt: "One operation", operationID: operationID) }
        await gate.waitUntilEntered()
        let retry = Task { try await coordinator.send(taskID, prompt: "One operation", operationID: operationID) }
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Overlapping operation") }
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Conflict", operationID: operationID) }
        await #expect(throws: (any Error).self) { try await coordinator.cancel(taskID) }
        #expect(await backend.submittedCount == 1)
        await gate.open()
        let admitted = try await first.value
        let retried = try await retry.value
        #expect(admitted == retried)
        _ = await backend.submission(operationID)
        #expect(await backend.submittedCount == 2)
        try await coordinator.cancel(taskID)
    }

    @Test func oldEventsAndOldStreamCleanupCannotOverwriteOrRemoveNewTurn() async throws {
        let backend = TurnFixtureBackend(), coordinator = makeCoordinator(backend)
        let taskID = try await completed(coordinator, backend: backend)
        let next = try await coordinator.send(taskID, prompt: "Next")
        _ = await backend.submission(next.operationID)
        try await coordinator.receive(.failed("Late old failure"), id: taskID, operationID: taskID)
        try await coordinator.receive(.completed("Late bare initial event"), id: taskID)
        await backend.emit(.session("wrong-old-session"), operationID: taskID)
        await backend.finish(taskID)
        await observe(.running, operationID: next.operationID, taskID: taskID,
                      phase: .running, coordinator: coordinator, backend: backend)
        #expect(coordinator.records[taskID]?.latestOperationID == next.operationID)
        #expect(coordinator.records[taskID]?.sessionID == "fixed-provider-session")
        #expect(coordinator.records[taskID]?.result == nil)
        #expect(try await coordinator.turn(taskID)?.result == "First result")
        try await coordinator.cancel(taskID)
        #expect(await backend.cancelled == [taskID])
        #expect(try await coordinator.turn(next.operationID)?.phase == .cancelled)
    }

    @Test(arguments: [AgentTaskTurnRecord.Phase.admitted, .dispatching])
    func turnPersistenceFailurePreventsSubmission(_ failure: AgentTaskTurnRecord.Phase) async throws {
        let backend = TurnFixtureBackend(), turns = TurnFixtureRepository()
        let coordinator = makeCoordinator(backend, turns: turns)
        let taskID = try await completed(coordinator, backend: backend)
        await turns.fail(on: failure)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Must not submit") }
        #expect(await backend.submittedCount == 1)
    }

    @Test func initialTurnPersistenceFailurePreventsInitialDispatch() async throws {
        let backend = TurnFixtureBackend(), turns = TurnFixtureRepository()
        await turns.fail(on: .dispatching)
        let coordinator = makeCoordinator(backend, turns: turns)
        await #expect(throws: (any Error).self) { try await coordinator.start(request()) }
        #expect(await backend.submittedCount == 0)
    }

    @Test func restartWithIntentNewerThanTaskProjectionIsUncertainAndNeverReplayed() async throws {
        let tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository(), backend = TurnFixtureBackend()
        let taskID = UUID(), operationID = UUID()
        var record = AgentTaskRecord(id: taskID, request: request(), now: Date())
        record.sessionID = "saved-session"; record.phase = .completed; record.result = "Old result"
        await tasks.save(record)
        var pending = AgentTaskTurnRecord(taskID: taskID, request: AgentTaskTurnRequest(operationID: operationID, prompt: "Possibly accepted"),
                                          sequence: 2, sessionID: record.sessionID, now: Date())
        pending.phase = .dispatching
        try await turns.save(pending)
        let coordinator = makeCoordinator(backend, tasks: tasks, turns: turns)
        try await coordinator.restore()
        #expect(coordinator.records[taskID]?.phase == .disconnected)
        #expect(coordinator.records[taskID]?.latestOperationID == operationID)
        #expect(try await coordinator.waitTurn(operationID).phase == .disconnected)
        #expect(try await coordinator.send(taskID, prompt: "Possibly accepted", operationID: operationID).phase == .disconnected)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "New input") }
        await #expect(throws: (any Error).self) { try await coordinator.cancel(taskID) }
        #expect(await backend.submittedCount == 0)
        #expect(await backend.cancelled.isEmpty)
    }

    @Test func completedConversationResumesAfterRestartAndOldTurnRemainsReadable() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let first = makeCoordinator(backend, tasks: tasks, turns: turns)
        let taskID = try await completed(first, backend: backend)
        let restoredBackend = TurnFixtureBackend(), restored = makeCoordinator(restoredBackend, tasks: tasks, turns: turns)
        try await restored.restore()
        let receipt = try await restored.send(taskID, prompt: "After restart")
        let submission = await restoredBackend.submission(receipt.operationID)
        #expect(submission.record?.sessionID == "fixed-provider-session")
        #expect(try await restored.turn(taskID)?.result == "First result")
        try await restored.cancel(taskID)
        #expect(await restoredBackend.submittedCount == 1)
    }

    @Test func needsInputIsAttentionWhileStreamLossIsUncertaintyAndNeitherAllowsNewInput() async throws {
        let backend = TurnFixtureBackend(), coordinator = makeCoordinator(backend)
        let taskID = try await completed(coordinator, backend: backend)
        let next = try await coordinator.send(taskID, prompt: "Ask a question")
        _ = await backend.submission(next.operationID)
        await observe(.needsInput("Approval required"), operationID: next.operationID, taskID: taskID,
                      phase: .needsInput, coordinator: coordinator, backend: backend)
        #expect(try await coordinator.waitTurn(next.operationID).phase == .needsInput)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Overlap") }
        let changes = coordinator.changes()
        await backend.finish(next.operationID)
        for await record in changes where record.id == taskID && record.phase == .disconnected { break }
        #expect(try await coordinator.waitTurn(next.operationID).phase == .disconnected)
        #expect(try await coordinator.send(taskID, prompt: "Ask a question", operationID: next.operationID).phase == .disconnected)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Automatic retry forbidden") }
        #expect(await backend.submittedCount == 2)
    }

    @Test func waitObservesOnlyItsOperationAndCancelDoesNotChangeOldReceipt() async throws {
        let backend = TurnFixtureBackend(), coordinator = makeCoordinator(backend)
        let taskID = try await completed(coordinator, backend: backend)
        let next = try await coordinator.send(taskID, prompt: "Long turn")
        _ = await backend.submission(next.operationID)
        let waiter = Task { try await coordinator.waitTurn(next.operationID) }
        try await coordinator.receive(.needsInput("Question"), id: taskID, operationID: next.operationID)
        #expect(try await waiter.value.phase == .needsInput)
        #expect(try await coordinator.waitTurn(taskID).result == "First result")
        try await coordinator.cancel(taskID)
        #expect(try await coordinator.turn(next.operationID)?.phase == .cancelled)
        #expect(try await coordinator.turn(taskID)?.phase == .completed)
    }

    @Test func receiptFailureAfterProviderCompletionFailsClosed() async throws {
        let backend = TurnFixtureBackend(), turns = TurnFixtureRepository()
        let coordinator = makeCoordinator(backend, turns: turns)
        let taskID = try await completed(coordinator, backend: backend)
        let next = try await coordinator.send(taskID, prompt: "Write failure")
        _ = await backend.submission(next.operationID)
        await turns.fail(on: .completed)
        await #expect(throws: (any Error).self) {
            try await coordinator.receive(.completed("Not durably recorded"), id: taskID, operationID: next.operationID)
        }
        #expect(coordinator.records[taskID]?.phase == .disconnected)
        await #expect(throws: (any Error).self) { try await coordinator.send(taskID, prompt: "Must not dispatch") }
        #expect(await backend.submittedCount == 2)
    }

    @Test func legacyRecordDecodingKeepsOptionsOptionalAndDoesNotInventSession() throws {
        let record = AgentTaskRecord(id: UUID(), request: request(), now: Date())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in ["effort", "latestOperationID", "turnCount"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.effort == nil)
        #expect(legacy.latestOperationID == nil)
        #expect(legacy.turnCount == nil)
        #expect(legacy.sessionID == nil)
    }

    @Test func fileReceiptsArePrivateRoundTripAndRejectCrossTaskPayloadReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileTurnRepository(directory: directory)
        let taskID = UUID(), operationID = UUID()
        var receipt = AgentTaskTurnRecord(taskID: taskID, request: AgentTaskTurnRequest(operationID: operationID, prompt: "Exact private input"),
                                          sequence: 1, sessionID: "session", now: Date())
        try await repository.save(receipt)
        #expect(try await repository.unfinished() == [receipt])
        receipt.phase = .completed; receipt.result = "Preserved result"
        try await repository.save(receipt)
        let reopened = AgentTaskFileTurnRepository(directory: directory)
        #expect(try await reopened.read(operationID) == receipt)
        #expect(try await reopened.turns(taskID: taskID) == [receipt])
        #expect(try await reopened.unfinished().isEmpty)
        let path = directory.appendingPathComponent(operationID.uuidString + ".json").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let conflict = AgentTaskTurnRecord(taskID: UUID(), request: AgentTaskTurnRequest(operationID: operationID, prompt: "Exact private input"),
                                           sequence: 1, sessionID: "session", now: Date())
        await #expect(throws: (any Error).self) { try await reopened.save(conflict) }
        #expect(try await reopened.read(operationID) == receipt)
    }

    @Test func archivedTurnsAreReadOnDemandBeyondRecentResultCache() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let taskID = UUID()
        var oldest: UUID?
        for index in 1...105 {
            let operationID = index == 1 ? taskID : UUID()
            if oldest == nil { oldest = operationID }
            var receipt = AgentTaskTurnRecord(taskID: taskID, request: AgentTaskTurnRequest(operationID: operationID, prompt: "Turn \(index)"),
                                              sequence: index, sessionID: "archive-session", now: Date(timeIntervalSince1970: Double(index)))
            receipt.phase = .completed; receipt.result = "Result \(index)"
            try await turns.save(receipt)
        }
        let coordinator = makeCoordinator(backend, tasks: tasks, turns: turns)
        try await coordinator.restore()
        #expect(try await coordinator.turn(try #require(oldest))?.result == "Result 1")
        #expect(try await coordinator.turns(taskID: taskID).count == 105)
        #expect(await backend.submittedCount == 0)
    }
}
