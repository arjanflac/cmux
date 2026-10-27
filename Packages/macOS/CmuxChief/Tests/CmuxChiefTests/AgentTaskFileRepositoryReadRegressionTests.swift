import Foundation
import Testing
@testable import CmuxChief

@Suite("Durable exact task read")
struct AgentTaskFileRepositoryReadRegressionTests {
    @Test func oldResultReadDoesNotUseTheTruncatedLoadProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-exact-task-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileRepository(directory: directory), oldID = UUID()
        let request = AgentTaskRequest(provider: .codex, prompt: "Fixture", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"), presentation: .background)
        var old = AgentTaskRecord(id: oldID, request: request, now: Date())
        old.phase = .completed; old.result = "EXACT_OLD_RESULT"
        try await repository.save(old)
        for _ in 0..<105 {
            var recent = AgentTaskRecord(id: UUID(), request: request, now: Date())
            recent.phase = .completed; recent.result = "Recent"
            try await repository.save(recent)
        }
        let projection = try await repository.load()
        #expect(projection.first { $0.id == oldID }?.result == nil)
        let raw = try JSONDecoder().decode(AgentTaskRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent(oldID.uuidString + ".json")))
        #expect(raw.result == "EXACT_OLD_RESULT")
        let direct = try await repository.read(oldID)?.result
        #expect(direct == "EXACT_OLD_RESULT")
        let erased: any AgentTaskRepository = repository
        let throughProtocol = try await erased.read(oldID)?.result
        #expect(throughProtocol == "EXACT_OLD_RESULT")
    }
    @Test func mismatchedFilenameAndRecordIdentityAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-exact-task-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileRepository(directory: directory), requested = UUID(), actual = UUID()
        let request = AgentTaskRequest(provider: .codex, prompt: "Fixture", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"), presentation: .background)
        var record = AgentTaskRecord(id: actual, request: request, now: Date())
        record.phase = .completed
        try await repository.save(record)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(requested.uuidString + ".json"))
        await #expect(throws: CocoaError(.fileReadCorruptFile)) { try await repository.read(requested) }
        await #expect(throws: CocoaError(.fileReadCorruptFile)) { try await repository.load() }
    }

}
