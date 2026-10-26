import Foundation
@testable import CmuxChief

actor TurnFixtureTaskRepository: AgentTaskRepository {
    private var records: [UUID: AgentTaskRecord] = [:]
    func load() -> [AgentTaskRecord] { Array(records.values) }
    func save(_ record: AgentTaskRecord) { records[record.id] = record }
}
