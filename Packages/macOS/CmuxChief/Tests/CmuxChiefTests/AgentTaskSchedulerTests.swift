import Foundation
import Testing
@testable import CmuxChief

@Suite("Durable finite app-owned scheduling")
struct AgentTaskSchedulerTests {
    @Test func futureWorkCanBeAdmittedWhileItsTargetIsBusyButCannotDispatchUntilReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_800_000_000), owner = UUID()
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"))
        let probe = AgentTaskScheduleTestProbe()
        await probe.configure(deny: true)
        let scheduler = try AgentTaskScheduler(journal: journal, now: { date }, authorize: { _ in },
            preflight: { try await probe.authorize($0) }, dispatch: { try await probe.dispatch($0, prompt: $1, operationID: $2) })
        let schedule = try await scheduler.create(.init(ownerTaskID: owner, target: .existingTask(owner), prompt: "Later", dueAt: date), callerID: UUID())
        try await scheduler.runDue()
        #expect(await probe.operations.isEmpty)
        await probe.configure(deny: false)
        _ = try await scheduler.resume(schedule.id, ownerTaskID: owner)
        try await scheduler.runDue()
        #expect(await probe.operations.count == 1)
    }

    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() -> URL {
        FileManager().temporaryDirectory.appendingPathComponent("cmux-schedule-\(UUID())", isDirectory: true)
    }

    private func makeScheduler(_ journal: AgentTaskJournal, _ probe: AgentTaskScheduleTestProbe) throws -> AgentTaskScheduler {
        let date = self.date
        return try AgentTaskScheduler(journal: journal, now: { date }, authorize: { try await probe.authorize($0) },
                                      dispatch: { try await probe.dispatch($0, prompt: $1, operationID: $2) })
    }

    private func request(owner: UUID, target: UUID = UUID(), due: Date? = nil,
                         misfire: AgentTaskScheduleRequest.MisfirePolicy = .hold,
                         recurrence: AgentTaskScheduleRequest.Recurrence = .once, maxRuns: Int = 1,
                         prompt: String = "Review the saved work") -> AgentTaskScheduleRequest {
        AgentTaskScheduleRequest(ownerTaskID: owner, target: .existingTask(target), prompt: prompt,
                                 dueAt: due ?? date, recurrence: recurrence, misfire: misfire, maxRuns: maxRuns)
    }

    @Test func duplicateCreationUsesOwnerCallerAndCanonicalPayload() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let scheduler = try makeScheduler(journal, AgentTaskScheduleTestProbe())
        let owner = UUID(), caller = UUID(), target = UUID()
        let input = request(owner: owner, target: target)
        let first = try await scheduler.create(input, callerID: caller)
        #expect(try await scheduler.create(input, callerID: caller) == first)
        await #expect(throws: AgentTaskJournalError.conflict) {
            try await scheduler.create(request(owner: owner, target: target, prompt: "Other payload"), callerID: caller)
        }
        #expect(try await scheduler.list(ownerTaskID: owner).count == 1)
        #expect(try await scheduler.read(first.id, ownerTaskID: UUID()) == nil)
        await journal.close()
    }

    @Test func duplicateWakesAndSharedTargetNeverOverlap() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), outstandingCapacity: 2)
        let probe = AgentTaskScheduleTestProbe(), owner = UUID(), target = UUID()
        let scheduler = try makeScheduler(journal, probe)
        _ = try await scheduler.create(request(owner: owner, target: target), callerID: UUID())
        _ = try await scheduler.create(request(owner: owner, target: target), callerID: UUID())
        try await scheduler.restore(now: date)
        await probe.configure(gateDispatch: true)
        let firstWake = Task { try await scheduler.runDue(now: date) }
        await probe.waitForDispatch()
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.count == 1)
        #expect(try await scheduler.nextDueDate() == nil)
        await probe.releaseDispatch()
        try await firstWake.value
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.count == 1)
        #expect(try await scheduler.nextDueDate() == nil)
        await journal.close()
    }

    @Test func unknownResponseReservesTargetAndBudgetAcrossRestart() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite")
        let journal = try AgentTaskJournal(databaseURL: path)
        let probe = AgentTaskScheduleTestProbe(), owner = UUID(), target = UUID()
        let scheduler = try makeScheduler(journal, probe)
        let schedule = try await scheduler.create(request(owner: owner, target: target, recurrence: .interval(seconds: 60), maxRuns: 3), callerID: UUID())
        await probe.configure(loseResponse: true)
        try await scheduler.runDue(now: date)
        let occurrence = try #require(try await journal.occurrences(scheduleID: schedule.id, ownerTaskID: owner).first)
        #expect(occurrence.state == .acceptanceUnknown)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.runsUsed == 1)
        await journal.close()
        let reopened = try AgentTaskJournal(databaseURL: path)
        let restored = try self.makeScheduler(reopened, probe)
        try await restored.restore(now: date.addingTimeInterval(10_000))
        try await restored.runDue(now: date.addingTimeInterval(10_000))
        await #expect(throws: AgentTaskJournalError.invalidTransition) { try await restored.resume(schedule.id, ownerTaskID: owner) }
        _ = try await restored.create(request(owner: owner, target: target, misfire: .coalesceOne), callerID: UUID())
        try await restored.runDue(now: date.addingTimeInterval(20_000))
        #expect(await probe.operations == [occurrence.id])
        #expect(try await restored.nextDueDate() == nil)
        await reopened.close()
    }

    @Test func crashBeforeClaimAllowsOneSendButCommittedDispatchMarkerNeverReplays() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite"), owner = UUID()
        let first = try AgentTaskJournal(databaseURL: path)
        let input = request(owner: owner)
        let created = try await first.create(AgentTaskSchedule(callerID: UUID(), request: input, now: date))
        await first.close()
        let second = try AgentTaskJournal(databaseURL: path)
        let probe = AgentTaskScheduleTestProbe()
        let scheduler = try makeScheduler(second, probe)
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.count == 1)
        let accepted = try #require(try await second.occurrences(scheduleID: created.id, ownerTaskID: owner).first)
        #expect(accepted.state == .accepted)
        await second.close()
        let third = try AgentTaskJournal(databaseURL: path)
        let restored = try self.makeScheduler(third, probe)
        try await restored.runDue(now: date)
        #expect(await probe.operations.count == 1)
        #expect(try await third.occurrences(scheduleID: created.id, ownerTaskID: owner).first?.acceptance == accepted.acceptance)
        await third.close()
    }

    @Test func crashAfterDispatchMarkerWithoutResponseHoldsForeverWithoutEvidence() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite"), owner = UUID()
        let first = try AgentTaskJournal(databaseURL: path)
        let schedule = try await first.create(AgentTaskSchedule(callerID: UUID(), request: request(owner: owner), now: date))
        let marker = try #require(try await first.claim(schedule, at: date))
        await first.close()
        let second = try AgentTaskJournal(databaseURL: path)
        let probe = AgentTaskScheduleTestProbe()
        let scheduler = try makeScheduler(second, probe)
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.isEmpty)
        #expect(try await second.occurrences(scheduleID: schedule.id, ownerTaskID: owner).first?.state == .acceptanceUnknown)
        #expect(try await second.occurrences(scheduleID: schedule.id, ownerTaskID: owner).first?.id == marker.id)
        await second.close()
    }

    @Test(arguments: [AgentTaskScheduleRequest.MisfirePolicy.hold, .skip, .coalesceOne])
    func restartMisfiresNeverBurst(policy: AgentTaskScheduleRequest.MisfirePolicy) async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite"), owner = UUID()
        let first = try AgentTaskJournal(databaseURL: path)
        let schedule = try await first.create(AgentTaskSchedule(callerID: UUID(), request: request(owner: owner,
            due: date.addingTimeInterval(-86_400), misfire: policy, recurrence: .interval(seconds: 60), maxRuns: 3), now: date))
        await first.close()
        let journal = try AgentTaskJournal(databaseURL: path)
        let probe = AgentTaskScheduleTestProbe(), scheduler = try makeScheduler(journal, probe)
        try await scheduler.restore(now: date)
        try await scheduler.runDue(now: date)
        try await scheduler.runDue(now: date)
        let current = try #require(try await scheduler.read(schedule.id, ownerTaskID: owner))
        switch policy {
        case .hold:
            #expect(await probe.operations.isEmpty)
            #expect(current.state == .held)
            _ = try await scheduler.resume(schedule.id, ownerTaskID: owner)
            try await scheduler.runDue(now: date)
            #expect(await probe.operations.count == 1)
        case .skip:
            #expect(await probe.operations.isEmpty)
            #expect(current.nextDueAt == date.addingTimeInterval(60))
            #expect(try await journal.occurrences(scheduleID: schedule.id, ownerTaskID: owner).map(\.state) == [.skipped])
        case .coalesceOne:
            #expect(await probe.operations.count == 1)
            #expect(current.nextDueAt == date.addingTimeInterval(60))
        }
        await journal.close()
    }

    @Test func finiteBudgetCompletionAndBackwardClock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let probe = AgentTaskScheduleTestProbe(), owner = UUID()
        let scheduler = try makeScheduler(journal, probe)
        let schedule = try await scheduler.create(request(owner: owner, recurrence: .interval(seconds: 60), maxRuns: 2), callerID: UUID())
        try await scheduler.runDue(now: date)
        let firstID = try #require(await probe.operations.first)
        _ = try await journal.completeOccurrence(operationID: firstID, ownerTaskID: owner, phase: .completed)
        try await scheduler.runDue(now: date.addingTimeInterval(-5_000))
        #expect(await probe.operations.count == 1)
        try await scheduler.runDue(now: date.addingTimeInterval(60))
        let lastID = try #require(await probe.operations.last)
        _ = try await journal.completeOccurrence(operationID: lastID, ownerTaskID: owner, phase: .failed)
        try await scheduler.runDue(now: date.addingTimeInterval(120))
        #expect(await probe.operations.count == 2)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.state == .exhausted)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.runsUsed == 2)
        await journal.close()
    }

    @Test func deniedAndStaleAuthorizersCannotSend() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let probe = AgentTaskScheduleTestProbe(), owner = UUID()
        let scheduler = try makeScheduler(journal, probe)
        let schedule = try await scheduler.create(request(owner: owner), callerID: UUID())
        try await scheduler.restore(now: date)
        await probe.configure(deny: true)
        try await scheduler.runDue(now: date)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.state == .blocked)
        #expect(await probe.operations.isEmpty)
        _ = try await scheduler.resume(schedule.id, ownerTaskID: owner)
        await probe.configure(gateAuthorization: true)
        let due = Task { try await scheduler.runDue(now: date) }
        await probe.waitForAuthorization()
        _ = try await scheduler.pause(schedule.id, ownerTaskID: owner)
        _ = try await scheduler.resume(schedule.id, ownerTaskID: owner)
        await probe.releaseAuthorization()
        try await due.value
        #expect(await probe.operations.isEmpty)
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.count == 1)
        await journal.close()
    }

    @Test func cancellationBeforeAndDuringDispatchIsTruthful() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let probe = AgentTaskScheduleTestProbe(), owner = UUID()
        let scheduler = try makeScheduler(journal, probe)
        let unsent = try await scheduler.create(request(owner: owner), callerID: UUID())
        _ = try await scheduler.cancel(unsent.id, ownerTaskID: owner)
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.isEmpty)
        let sent = try await scheduler.create(request(owner: owner), callerID: UUID())
        await probe.configure(gateDispatch: true)
        let due = Task { try await scheduler.runDue(now: date) }
        await probe.waitForDispatch()
        _ = try await scheduler.cancel(sent.id, ownerTaskID: owner)
        await probe.releaseDispatch()
        try await due.value
        #expect(try await scheduler.read(sent.id, ownerTaskID: owner)?.state == .cancelled)
        #expect(try await journal.occurrences(scheduleID: sent.id, ownerTaskID: owner).first?.state == .accepted)
        #expect(try await journal.occurrences(scheduleID: sent.id, ownerTaskID: owner).first?.completion == nil)
        await journal.close()
    }

    @Test func fullDatabaseRollsBackClaimAndPreventsDispatch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), maximumDatabasePages: 32)
        let probe = AgentTaskScheduleTestProbe(), owner = UUID()
        let scheduler = try makeScheduler(journal, probe)
        let schedule = try await scheduler.create(request(owner: owner, prompt: String(repeating: "x", count: 50_000)), callerID: UUID())
        await #expect(throws: (any Error).self) { try await scheduler.runDue(now: date) }
        #expect(await probe.operations.isEmpty)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.runsUsed == 0)
        #expect(try await journal.occurrences(scheduleID: schedule.id, ownerTaskID: owner).isEmpty)
        await journal.close()
    }

    @Test func wrongOperationReceiptDoesNotConfirmEitherSubmission() async throws {
        let directory = makeDirectory()
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let owner = UUID(), target = UUID(), wrongOperation = UUID(), date = self.date
        let scheduler = try AgentTaskScheduler(journal: journal, now: { date }, authorize: { _ in },
            dispatch: { _, _, _ in
                AgentTaskScheduleAcceptance(taskID: target, operationID: wrongOperation, providerReference: "mismatched-turn")
            })
        let schedule = try await scheduler.create(request(owner: owner, target: target), callerID: UUID())
        try await scheduler.runDue(now: date)
        let occurrence = try #require(try await journal.occurrences(scheduleID: schedule.id, ownerTaskID: owner).first)
        #expect(occurrence.id != wrongOperation)
        #expect(occurrence.state == .acceptanceUnknown)
        #expect(occurrence.acceptance == nil)
        #expect(try await scheduler.nextDueDate() == nil)
        await journal.close()
    }

}
