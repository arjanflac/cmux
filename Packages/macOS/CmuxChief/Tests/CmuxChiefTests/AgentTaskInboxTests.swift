import Foundation
import Testing
@testable import CmuxChief

@Suite("Passive durable task inbox")
struct AgentTaskInboxTests {
    @Test func unreadAggregateIncludesEventsBeyondAcknowledgedFirstPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let owner = UUID(), child = UUID()
        for _ in 0..<100 {
            let event = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: UUID(), phase: .completed)
            _ = try await journal.acknowledge(ownerTaskID: owner, eventID: event.id)
        }
        #expect(try await journal.unreadInboxCount(ownerTaskID: owner) == 0)
        _ = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: UUID(), phase: .completed)
        #expect(try await journal.inbox(ownerTaskID: owner).allSatisfy { $0.acknowledgedAt != nil })
        #expect(try await journal.unreadInboxCount(ownerTaskID: owner) == 1)
        #expect(try await journal.unreadInboxCount(ownerTaskID: UUID()) == 0)
    }

    @Test func dedupReplayAcknowledgementAndRestartHaveNoProviderWork() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-inbox-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let journal = try AgentTaskJournal(databaseURL: path, now: { date })
        let owner = UUID(), child = UUID(), turn = UUID()
        let event = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn,
                                                  phase: .completed, result: .body("Private result"))
        #expect(event.sequence > 0)
        #expect(event.acknowledgedAt == nil)
        #expect(try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn,
            phase: .completed, result: .body("Private result")) == event)
        let next = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: UUID(),
                                                 phase: .completed, result: .reference("receipt:123"))
        #expect(next.sequence > event.sequence)
        #expect(try await journal.inbox(ownerTaskID: owner, afterSequence: event.sequence, limit: 1) == [next])
        #expect(try await journal.inbox(ownerTaskID: UUID()).isEmpty)
        await #expect(throws: AgentTaskJournalError.notFound) { try await journal.acknowledge(ownerTaskID: UUID(), eventID: event.id) }
        let acknowledged = try await journal.acknowledge(ownerTaskID: owner, eventID: event.id)
        #expect(acknowledged.acknowledgedAt == date)
        #expect(try await journal.acknowledge(ownerTaskID: owner, eventID: event.id) == acknowledged)
        await journal.close()
        let restored = try AgentTaskJournal(databaseURL: path)
        // A scheduler with a provider spy proves passive replay/ack does not require dispatch.
        let probe = AgentTaskScheduleTestProbe()
        let scheduler = try AgentTaskScheduler(journal: restored, now: { date }, authorize: { try await probe.authorize($0) },
            dispatch: { try await probe.dispatch($0, prompt: $1, operationID: $2) })
        #expect(try await restored.inbox(ownerTaskID: owner) == [acknowledged, next])
        #expect(try await restored.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn,
            phase: .completed, result: .body("Private result")) == acknowledged)
        _ = try await restored.acknowledge(ownerTaskID: owner, eventID: next.id)
        try await scheduler.runDue(now: date)
        #expect(await probe.operations.isEmpty)
        await restored.close()
    }

    @Test func inboxBoundsConflictAndOwnerKeysNeverDropUnreadData() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("cmux-inbox-\(UUID())")
        defer { try? FileManager().removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), inboxCapacity: 2)
        let owner = UUID(), child = UUID(), turn = UUID()
        let first = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn, phase: .completed)
        await #expect(throws: AgentTaskJournalError.conflict) {
            try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn, phase: .completed, result: .body("Changed"))
        }
        await #expect(throws: AgentTaskJournalError.invalidRequest) {
            try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: turn, phase: .failed,
                                          result: .body(String(repeating: "é", count: 32_769)))
        }
        let otherOwner = UUID()
        let second = try await journal.appendInbox(ownerTaskID: otherOwner, taskID: child, operationID: turn, phase: .completed)
        #expect(second.sequence > first.sequence)
        await #expect(throws: AgentTaskJournalError.capacity) {
            try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: UUID(), phase: .completed)
        }
        #expect(try await journal.inbox(ownerTaskID: owner) == [first])
        #expect(try await journal.inbox(ownerTaskID: otherOwner) == [second])
        await #expect(throws: AgentTaskJournalError.invalidRequest) { try await journal.inbox(ownerTaskID: owner, limit: 1_001) }
        await journal.close()
    }
}
