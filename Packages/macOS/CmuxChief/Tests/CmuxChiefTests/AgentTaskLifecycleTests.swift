import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Managed worker lifetime and resource budgets")
struct AgentTaskLifecycleTests {
    private func request(_ provider: AgentTaskRequest.Provider = .codex,
                         parent: UUID? = nil, lifecycle: AgentTaskRequest.Lifecycle = .persistent) -> AgentTaskRequest {
        AgentTaskRequest(provider: provider, prompt: "Fixture work", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), presentation: .background,
                         parentTaskID: parent, lifecycle: lifecycle)
    }

    private func coordinator(_ backend: TurnFixtureBackend, tasks: TurnFixtureTaskRepository = TurnFixtureTaskRepository(),
                             turns: any AgentTaskTurnRepository = AgentTaskMemoryTurnRepository(),
                             limits: AgentTaskExecutionLimits = AgentTaskExecutionLimits()) -> AgentTaskCoordinator {
        let owner = AgentTaskCoordinator(backend: backend, repository: tasks, present: { _, _ in
            Issue.record("Fixture worker must remain headless"); return UUID()
        }, turnRepository: turns, executionLimits: limits)
        owner.setRetirementPermit { _ in true }
        return owner
    }

    private func savedWorker(_ lifecycle: AgentTaskRequest.Lifecycle = .oneShot,
                             tasks: TurnFixtureTaskRepository, turns: AgentTaskMemoryTurnRepository) async throws -> AgentTaskRecord {
        let id = UUID(), parent = UUID(), now = Date()
        var record = AgentTaskRecord(id: id, request: request(parent: parent, lifecycle: lifecycle), now: now)
        record.phase = .completed; record.sessionID = "fixture-exact-session"; record.result = "Durable result"
        var turn = AgentTaskTurnRecord(taskID: id, request: AgentTaskTurnRequest(operationID: id, prompt: "Fixture work"),
                                       sequence: 1, sessionID: record.sessionID, now: now)
        turn.phase = .completed; turn.result = record.result
        await tasks.save(record); try await turns.save(turn)
        return record
    }

    private func acknowledgement(_ worker: AgentTaskRecord, operation: UUID? = nil, acknowledged: Bool = true) -> AgentTaskInboxEvent {
        var event = AgentTaskInboxEvent(ownerTaskID: worker.parentTaskID!, taskID: worker.id,
            operationID: operation ?? worker.id, phase: .completed, result: nil, now: Date())
        if acknowledged { event.acknowledgedAt = Date() }
        return event
    }

    @Test func oneShotRetirementKeepsExactProviderAndDurableResultsWithoutProviderArchive() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let worker = try await savedWorker(tasks: tasks, turns: turns)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        #expect(try await owner.retireAcknowledgedWorker(acknowledgement(worker)))
        let retired = try #require(try await owner.record(worker.id))
        #expect(retired.isRetired)
        #expect(retired.retirement?.scope == "localOnly")
        #expect(retired.retirement?.operationID == worker.id)
        #expect(retired.sessionID == worker.sessionID)
        #expect(retired.result == "Durable result")
        #expect(try await owner.turn(worker.id)?.result == "Durable result")
        #expect(await backend.released == [worker.id])
        #expect(await backend.submittedCount == 0)
        #expect(try await owner.retireAcknowledgedWorker(acknowledgement(worker)))
        #expect(await backend.released == [worker.id])
        await #expect(throws: (any Error).self) { try await owner.send(worker.id, prompt: "Retired workers cannot submit") }
    }

    @Test func persistentWorkersAndUnacknowledgedOrStaleResultsDoNotRetire() async throws {
        for lifecycle in [AgentTaskRequest.Lifecycle.persistent, .oneShot] {
            let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
            let worker = try await savedWorker(lifecycle, tasks: tasks, turns: turns)
            let owner = coordinator(backend, tasks: tasks, turns: turns)
            try await owner.restore()
            #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker, acknowledged: false)))
            #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker, operation: UUID())))
            if lifecycle == .persistent { #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker))) }
            #expect(await backend.released.isEmpty)
            #expect(try await owner.record(worker.id)?.retirement == nil)
        }
    }

    @Test func anotherParentsAcknowledgementCannotRetireWorker() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let worker = try await savedWorker(tasks: tasks, turns: turns)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        var forged = AgentTaskInboxEvent(ownerTaskID: UUID(), taskID: worker.id, operationID: worker.id,
                                         phase: .completed, result: nil, now: Date())
        forged.acknowledgedAt = Date()
        #expect(try await !owner.retireAcknowledgedWorker(forged))
        #expect(await backend.released.isEmpty)
    }

    @Test func futureSchedulesAndUnknownScheduleStorageKeepWorkerReusable() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let worker = try await savedWorker(tasks: tasks, turns: turns)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        owner.setRetirementPermit { _ in false }
        #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker)))
        #expect(try await owner.record(worker.id)?.retirement == nil)
        owner.setRetirementPermit { _ in throw CocoaError(.fileReadUnknown) }
        await #expect(throws: (any Error).self) { try await owner.retireAcknowledgedWorker(acknowledgement(worker)) }
        #expect(try await owner.record(worker.id)?.retirement == nil)
        #expect(await backend.released.isEmpty)
    }

    @Test func unretiredDescendantsKeepAncestorUsableForFollowupsAndFutureSchedules() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-descendant-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let worker = try await savedWorker(tasks: tasks, turns: turns)
        var root = AgentTaskRecord(id: try #require(worker.parentTaskID), request: request(), now: Date())
        root.phase = .completed; root.turnCount = 0; root.latestOperationID = nil
        await tasks.save(root)
        var child = AgentTaskRecord(id: UUID(), request: request(parent: worker.id), now: Date())
        child.phase = .completed; child.sessionID = "persistent-child"
        var grandchild = AgentTaskRecord(id: UUID(), request: request(parent: child.id), now: Date())
        grandchild.phase = .completed; grandchild.sessionID = "persistent-grandchild"
        await tasks.save(child); await tasks.save(grandchild)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        owner.setRetirementPermit { try await !journal.preventsRetirement(of: $0) }
        try await owner.restore()
        #expect(owner.descendantTaskIDs(of: worker.id) == [child.id, grandchild.id])
        #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker)))
        #expect(try await owner.record(worker.id)?.retirement == nil)
        #expect(await backend.released.isEmpty)
        // Completion is not permission to strand a reusable descendant between turns.
        let followup = try await owner.send(child.id, prompt: "Continue the child")
        let submission = await backend.submission(followup.operationID)
        #expect(submission.record?.sessionID == "persistent-child")
        let scheduler = try AgentTaskScheduler(journal: journal, authorize: { _ in },
            dispatch: { _, _, _ in throw CocoaError(.featureUnsupported) })
        let future = AgentTaskScheduleRequest(ownerTaskID: child.id, target: .existingTask(grandchild.id),
            prompt: "Future followup", dueAt: Date().addingTimeInterval(60))
        _ = try await owner.withScheduleAdmission(taskIDs: [child.id, grandchild.id]) {
            try await scheduler.create(future, callerID: UUID())
        }
        #expect(try await journal.schedules(ownerTaskID: child.id).count == 1)
        #expect(try await owner.record(worker.id)?.retirement == nil)
        await backend.finish(followup.operationID)
        await journal.close()
    }

    @Test func pendingIdleResourceReleaseSurvivesRestartWithoutProviderReplay() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        var worker = try await savedWorker(tasks: tasks, turns: turns)
        worker.retirement = AgentTaskRetirement(operationID: worker.id, acknowledgedAt: Date())
        await tasks.save(worker)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        try await owner.finishPendingRetirements()
        #expect(try await owner.record(worker.id)?.isRetired == true)
        #expect(await backend.released == [worker.id])
        #expect(await backend.submittedCount == 0)
    }

    @Test func retirementAdmissionFencesConcurrentFollowupAndReleasesResourcesOnce() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        let worker = try await savedWorker(tasks: tasks, turns: turns), gate = TurnFixtureGate()
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        await backend.holdRelease(gate)
        let event = acknowledgement(worker)
        let retirement = Task { try await owner.retireAcknowledgedWorker(event) }
        await gate.waitUntilEntered()
        await #expect(throws: (any Error).self) { try await owner.send(worker.id, prompt: "Too late") }
        #expect(try await !owner.retireAcknowledgedWorker(event))
        await gate.open()
        #expect(try await retirement.value)
        #expect(await backend.released == [worker.id])
        #expect(await backend.submittedCount == 0)
    }

    @Test func legacyDecodeDoesNotTurnExistingSessionIntoOneShot() throws {
        let record = AgentTaskRecord(id: UUID(), request: request(), now: Date())
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        value.removeValue(forKey: "lifecycle"); value.removeValue(forKey: "retirement")
        let decoded = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONSerialization.data(withJSONObject: value))
        #expect(decoded.lifecycle == nil)
        #expect(!decoded.isRetired)
    }

    @Test func independentProviderAndGlobalLimitsReleaseOnlyOnConfirmedTerminalState() async throws {
        let backend = TurnFixtureBackend(), owner = coordinator(backend, limits: AgentTaskExecutionLimits(total: 2, codex: 1, claude: 1, opencode: 1))
        let codex = try await owner.start(request())
        _ = await backend.submission(codex.id)
        await #expect(throws: (any Error).self) { try await owner.start(request()) }
        let claude = try await owner.start(request(.claude))
        _ = await backend.submission(claude.id)
        await #expect(throws: (any Error).self) { try await owner.start(request(.opencode)) }
        try await owner.receive(.needsInput("Approval"), id: codex.id)
        await #expect(throws: (any Error).self) { try await owner.start(request()) }
        try await owner.receive(.disconnected("Unknown acceptance"), id: codex.id)
        await #expect(throws: (any Error).self) { try await owner.start(request()) }
        try await owner.receive(.completed("Confirmed"), id: codex.id)
        let next = try await owner.start(request(.opencode))
        _ = await backend.submission(next.id)
        #expect(await backend.submittedCount == 3)
        await backend.finish(codex.id); await backend.finish(claude.id); await backend.finish(next.id)
    }

    @Test func overlappingAdmissionsReserveCapacityBeforePersistenceAwaits() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = TurnFixtureRepository(), gate = TurnFixtureGate(), id = UUID()
        let owner = coordinator(backend, tasks: tasks, turns: turns, limits: AgentTaskExecutionLimits(total: 1))
        await turns.holdAdmission(id, gate: gate)
        let first = Task { try await owner.start(request(), id: id) }
        await gate.waitUntilEntered()
        await #expect(throws: (any Error).self) { try await owner.start(request(.claude)) }
        #expect(await backend.submittedCount == 0)
        await gate.open()
        _ = try await first.value
        _ = await backend.submission(id)
        #expect(await backend.submittedCount == 1)
        await backend.finish(id)
    }

    @Test func restoredUncertaintyStillReservesIndependentWorkerCapacity() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository()
        var record = AgentTaskRecord(id: UUID(), request: request(), now: Date())
        record.phase = .running
        await tasks.save(record)
        let owner = coordinator(backend, tasks: tasks, limits: AgentTaskExecutionLimits(total: 1))
        try await owner.restore()
        await #expect(throws: (any Error).self) { try await owner.start(request(.claude)) }
        #expect(await backend.submittedCount == 0)
    }
    @Test func oneShotCannotRetireAnUnparentedOrInteractiveSession() async throws {
        let backend = TurnFixtureBackend(), owner = coordinator(backend)
        await #expect(throws: (any Error).self) { try await owner.start(request(lifecycle: .oneShot)) }
        var interactive = request(parent: UUID(), lifecycle: .oneShot)
        interactive.presentation = .terminal
        await #expect(throws: (any Error).self) { try await owner.start(interactive) }
        #expect(await backend.submittedCount == 0)
    }

    @Test func freshWorkerSchedulesRejectHundredRunPromiseWhileExistingWorkerSupportsIt() throws {
        let owner = UUID()
        var fresh = request(parent: owner)
        fresh.workspaceStableID = UUID()
        let tooMany = AgentTaskScheduleRequest(ownerTaskID: owner, target: .newTask(fresh), prompt: fresh.prompt,
            dueAt: Date(), recurrence: .interval(seconds: 60), maxRuns: 100)
        #expect(throws: AgentTaskJournalError.invalidRequest) { try tooMany.validate() }
        let existing = AgentTaskScheduleRequest(ownerTaskID: owner, target: .existingTask(UUID()), prompt: "Follow up",
            dueAt: Date(), recurrence: .interval(seconds: 60), maxRuns: 100)
        try existing.validate()
    }

    @Test func explicitlyAttachedWorkerRemainsOwnedByItsInteractiveUser() async throws {
        let backend = TurnFixtureBackend(), tasks = TurnFixtureTaskRepository(), turns = AgentTaskMemoryTurnRepository()
        var worker = try await savedWorker(tasks: tasks, turns: turns)
        worker.presentation = .terminal; worker.surfaceID = UUID()
        await tasks.save(worker)
        let owner = coordinator(backend, tasks: tasks, turns: turns)
        try await owner.restore()
        #expect(try await !owner.retireAcknowledgedWorker(acknowledgement(worker)))
        #expect(try await owner.record(worker.id)?.retirement == nil)
        #expect(await backend.released.isEmpty)
    }


}
