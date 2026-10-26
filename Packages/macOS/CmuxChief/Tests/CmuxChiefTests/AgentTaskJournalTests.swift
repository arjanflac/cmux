import Foundation
import Testing
@testable import CmuxChief

@Suite("Private scheduling journal")
struct AgentTaskJournalTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func privatePermissionsAndClosedJournalFailClosed() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-private-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite")
        let journal = try AgentTaskJournal(databaseURL: path)
        let parentMode = try #require(FileManager().attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        let fileMode = try #require(FileManager().attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        #expect(parentMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)
        await journal.close()
        await #expect(throws: AgentTaskJournalError.closed) { try await journal.inbox(ownerTaskID: UUID()) }
    }

    @Test func symlinkDatabaseIsRejected() throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-symlink-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("untouched")
        try Data("keep".utf8).write(to: destination)
        let link = directory.appendingPathComponent("tasks.sqlite")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: AgentTaskJournalError.insecurePath) { try AgentTaskJournal(databaseURL: link) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    }

    @Test func finiteValidationCapacityAndExpiry() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-validation-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), scheduleCapacity: 1)
        let probe = AgentTaskScheduleTestProbe(), owner = UUID(), target = UUID(), date = self.date
        let scheduler = try AgentTaskScheduler(journal: journal, now: { date }, authorize: { try await probe.authorize($0) },
            dispatch: { try await probe.dispatch($0, prompt: $1, operationID: $2) })
        for (interval, runs) in [(59.0, 1), (60.0, 101), (.infinity, 1)] {
            let request = AgentTaskScheduleRequest(ownerTaskID: owner, target: .existingTask(target), prompt: "Work",
                dueAt: date, recurrence: .interval(seconds: interval), maxRuns: runs)
            await #expect(throws: AgentTaskJournalError.invalidRequest) { try await scheduler.create(request, callerID: UUID()) }
        }
        let request = AgentTaskScheduleRequest(ownerTaskID: owner, target: .existingTask(target), prompt: "Work", dueAt: date,
                                               expiresAt: date.addingTimeInterval(60))
        let schedule = try await scheduler.create(request, callerID: UUID())
        await #expect(throws: AgentTaskJournalError.capacity) { try await scheduler.create(request, callerID: UUID()) }
        try await scheduler.runDue(now: date.addingTimeInterval(60))
        #expect(await probe.operations.isEmpty)
        #expect(try await scheduler.read(schedule.id, ownerTaskID: owner)?.reason == "expired")
        #expect(try await scheduler.nextDueDate() == nil)
        await journal.close()
    }

    @Test func evidenceConflictsCannotChangeAcceptanceOrInventCompletion() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-evidence-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let owner = UUID(), task = UUID()
        let request = AgentTaskScheduleRequest(ownerTaskID: owner, target: .existingTask(task), prompt: "Work", dueAt: date)
        let schedule = try await journal.create(AgentTaskSchedule(callerID: UUID(), request: request, now: date))
        let marker = try #require(try await journal.claim(schedule, at: date))
        let recovery = try #require(try await journal.scheduledReceipt(marker.id))
        #expect(recovery.ownerTaskID == owner)
        #expect(recovery.occurrence == marker)
        #expect(try await journal.scheduledReceipt(UUID()) == nil)
        await #expect(throws: AgentTaskJournalError.invalidTransition) {
            try await journal.completeOccurrence(operationID: marker.id, ownerTaskID: owner, phase: .cancelled)
        }
        let acceptance = AgentTaskScheduleAcceptance(taskID: task, operationID: marker.id, providerReference: "turn:1")
        _ = try await journal.confirmAcceptance(acceptance, ownerTaskID: owner)
        _ = try await journal.confirmAcceptance(acceptance, ownerTaskID: owner)
        await #expect(throws: AgentTaskJournalError.conflict) {
            try await journal.confirmAcceptance(AgentTaskScheduleAcceptance(taskID: UUID(), operationID: marker.id,
                                                                          providerReference: "turn:1"), ownerTaskID: owner)
        }
        await #expect(throws: AgentTaskJournalError.invalidTransition) {
            try await journal.completeOccurrence(operationID: marker.id, ownerTaskID: owner, phase: .disconnected)
        }
        let completed = try await journal.completeOccurrence(operationID: marker.id, ownerTaskID: owner, phase: .completed)
        #expect(completed.acceptance == acceptance)
        #expect(completed.completion == .completed)
        await journal.close()
    }
}
