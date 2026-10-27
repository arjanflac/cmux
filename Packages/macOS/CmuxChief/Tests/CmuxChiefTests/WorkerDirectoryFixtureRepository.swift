import Foundation
@testable import CmuxChief

/// Controlled durable reads let a fixture revoke authority or move a view during an await.
actor WorkerDirectoryFixtureRepository: AgentTaskRepository {
    private var records: [UUID: AgentTaskRecord] = [:]
    private var gates: [UUID: TurnFixtureGate] = [:]
    private(set) var reads: [UUID] = []

    func load() -> [AgentTaskRecord] { Array(records.values) }
    func save(_ record: AgentTaskRecord) { records[record.id] = record }
    func holdRead(_ id: UUID, gate: TurnFixtureGate) { gates[id] = gate }
    func read(_ id: UUID) async -> AgentTaskRecord? {
        reads.append(id)
        if let gate = gates[id] { await gate.hold() }
        return records[id]
    }
}
