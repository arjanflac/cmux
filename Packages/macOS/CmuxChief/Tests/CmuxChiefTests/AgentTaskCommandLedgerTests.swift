import Foundation
import Testing
@testable import CmuxChief

@Suite("Orchestrator command admission")
struct AgentTaskCommandLedgerTests {
    @Test func restartReturnsUncertaintyInsteadOfDispatchPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID(), input = Data("{\"action\":\"send\"}".utf8)
        let ledger = AgentTaskCommandLedger(directory: root)
        #expect(try await ledger.begin(operation, arguments: input) == nil)
        let restored = AgentTaskCommandLedger(directory: root)
        let previous = try await restored.begin(operation, arguments: input)
        #expect(previous?.id == operation)
        #expect(previous?.response == nil)
        let result = Data("{\"phase\":\"completed\"}".utf8)
        try await ledger.complete(operation, response: result)
        #expect(try await restored.begin(operation, arguments: input)?.response == result)
        await #expect(throws: AgentTaskCommandLedger.Failure.self) {
            try await restored.begin(operation, arguments: Data("different input".utf8))
        }
    }

    @Test func unwriteableStoreCannotAdmitACommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentTaskCommandLedger(directory: root)
        await #expect(throws: (any Error).self) {
            try await ledger.begin(UUID(), arguments: Data())
        }
    }
}
