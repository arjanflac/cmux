import Foundation
import Testing
@testable import CmuxChief

@Suite("Historical inbox acknowledgement capacity")
struct AgentTaskInboxRetentionRegressionTests {
    @Test func consumedHistoryCannotBlockNewTaskResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-inbox-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
        let owner = UUID(), worker = UUID()
        for _ in 0..<10_001 {
            let event = try await journal.appendInbox(ownerTaskID: owner, taskID: worker, operationID: UUID(), phase: .completed)
            _ = try await journal.acknowledge(ownerTaskID: owner, eventID: event.id)
        }
        #expect(try await journal.unreadInboxCount(ownerTaskID: owner) == 0)
        let unread = try await journal.appendInbox(ownerTaskID: owner, taskID: worker, operationID: UUID(), phase: .completed)
        #expect(try await journal.inbox(ownerTaskID: owner, afterSequence: unread.sequence - 1) == [unread])
        await journal.close()
    }
}
