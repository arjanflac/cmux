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

@Suite("Bounded acknowledged inbox payloads")
struct AgentTaskInboxCompactionTests {
    @Test func tenThousandAcknowledgementsDoNotPoisonCapacityOrReappearUnreadAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-compaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tasks.sqlite")
        let journal = try AgentTaskJournal(databaseURL: path), owner = UUID(), child = UUID(), otherOwner = UUID()
        let unread = try await journal.appendInbox(ownerTaskID: otherOwner, taskID: child, operationID: UUID(), phase: .completed,
                                                   result: .body("Must remain unread"))
        var original: AgentTaskInboxEvent?
        for index in 0..<10_001 {
            let event = try await journal.appendInbox(ownerTaskID: owner, taskID: child, operationID: UUID(), phase: .completed,
                                                       result: .body("Result \(index)"))
            let acknowledged = try await journal.acknowledge(ownerTaskID: owner, eventID: event.id)
            if original == nil { original = acknowledged }
        }
        let old = try #require(original)
        #expect(try await journal.inbox(ownerTaskID: owner, limit: 1_000).count == 100)
        #expect(try await journal.unreadInboxCount(ownerTaskID: owner) == 0)
        #expect(try await journal.inbox(ownerTaskID: otherOwner) == [unread])
        await journal.close()
        let restored = try AgentTaskJournal(databaseURL: path)
        // Startup receipt reconciliation replays the exact old turn; it must remain acknowledged.
        #expect(try await restored.appendInbox(ownerTaskID: owner, taskID: child, operationID: old.operationID,
                                               phase: .completed, result: old.result) == old)
        #expect(try await restored.unreadInboxCount(ownerTaskID: owner) == 0)
        let compacted = try await restored.acknowledge(ownerTaskID: owner, eventID: old.id)
        #expect(compacted.id == old.id && compacted.sequence == old.sequence)
        #expect(compacted.acknowledgedAt == old.acknowledgedAt)
        #expect(compacted.result == nil && compacted.resultCompacted == true)
        await #expect(throws: AgentTaskJournalError.conflict) {
            try await restored.appendInbox(ownerTaskID: owner, taskID: child, operationID: old.operationID,
                                             phase: .completed, result: .body("Changed old result"))
        }
        await restored.close()
    }

    @Test func globalPressureCompactsOnlyAcknowledgedPayloadsAcrossOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-compaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), inboxCapacity: 2)
        let firstOwner = UUID(), secondOwner = UUID(), child = UUID()
        let old = try await journal.appendInbox(ownerTaskID: firstOwner, taskID: child, operationID: UUID(), phase: .completed,
                                                result: .body("Consumed"))
        let ack = try await journal.acknowledge(ownerTaskID: firstOwner, eventID: old.id)
        let unread = try await journal.appendInbox(ownerTaskID: secondOwner, taskID: child, operationID: UUID(), phase: .completed)
        let next = try await journal.appendInbox(ownerTaskID: firstOwner, taskID: child, operationID: UUID(), phase: .completed)
        #expect(next.sequence > unread.sequence)
        #expect(try await journal.inbox(ownerTaskID: secondOwner) == [unread])
        #expect(try await journal.appendInbox(ownerTaskID: firstOwner, taskID: child, operationID: old.operationID,
                                               phase: .completed, result: old.result) == ack)
        await #expect(throws: AgentTaskJournalError.capacity) {
            try await journal.appendInbox(ownerTaskID: UUID(), taskID: child, operationID: UUID(), phase: .completed)
        }
        #expect(try await journal.unreadInboxCount(ownerTaskID: firstOwner) == 1)
        #expect(try await journal.unreadInboxCount(ownerTaskID: secondOwner) == 1)
        await journal.close()
    }

    @Test func compactionKeepsIndependentTurnReceiptBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-compaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"), acknowledgedInboxPerOwner: 0)
        let store = AgentTaskFileTurnRepository(directory: directory.appendingPathComponent("turns")), taskID = UUID(), owner = UUID()
        var turn = AgentTaskTurnRecord(taskID: taskID, request: AgentTaskTurnRequest(operationID: taskID, prompt: "Fixture"),
                                       sequence: 1, sessionID: "exact-session", now: Date())
        turn.phase = .completed; turn.result = String(repeating: "Private result", count: 1_000)
        try await store.save(turn)
        let event = try await journal.appendInbox(ownerTaskID: owner, taskID: taskID, operationID: taskID, phase: .completed,
                                                   result: .body(turn.result!))
        _ = try await journal.acknowledge(ownerTaskID: owner, eventID: event.id)
        #expect(try await journal.inbox(ownerTaskID: owner).isEmpty)
        #expect(try await store.read(taskID)?.result == turn.result)
        #expect(try await journal.acknowledge(ownerTaskID: owner, eventID: event.id).resultCompacted == true)
        await journal.close()
    }
}
