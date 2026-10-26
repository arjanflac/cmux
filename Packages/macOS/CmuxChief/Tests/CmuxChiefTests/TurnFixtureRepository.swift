import Foundation
@testable import CmuxChief

actor TurnFixtureRepository: AgentTaskTurnRepository {
    private let store = AgentTaskMemoryTurnRepository()
    private var failure: AgentTaskTurnRecord.Phase?
    private var admissionGates: [UUID: TurnFixtureGate] = [:]

    func holdAdmission(_ id: UUID, gate: TurnFixtureGate) { admissionGates[id] = gate }
    func fail(on phase: AgentTaskTurnRecord.Phase) { failure = phase }
    func unfinished() async throws -> [AgentTaskTurnRecord] { await store.unfinished() }
    func read(_ operationID: UUID) async throws -> AgentTaskTurnRecord? { await store.read(operationID) }
    func turns(taskID: UUID) async throws -> [AgentTaskTurnRecord] { await store.turns(taskID: taskID) }
    func save(_ record: AgentTaskTurnRecord) async throws {
        if record.phase == .admitted, let gate = admissionGates.removeValue(forKey: record.operationID) { await gate.hold() }
        if failure == record.phase { throw CocoaError(.fileWriteNoPermission) }
        try await store.save(record)
    }
}
