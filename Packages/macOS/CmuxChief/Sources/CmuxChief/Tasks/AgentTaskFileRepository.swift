import Foundation

/// One private, atomically replaced receipt per task.
public actor AgentTaskFileRepository: AgentTaskRepository {
    private let directory: URL

    /// Creates a repository at an app-owned directory.
    public init(directory: URL) { self.directory = directory }

    /// Loads app-owned receipts without reconnecting to any provider.
    public func load() throws -> [AgentTaskRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        var records: [AgentTaskRecord] = []
        var finished = 0
        for file in files {
            var record = try JSONDecoder().decode(AgentTaskRecord.self, from: Data(contentsOf: file))
            // Preserve unfinished task identities and ancestry regardless of
            // age. Cache only recent result bodies; read older ones on demand.
            if record.phase.isFinished {
                finished += 1
                if finished > 100 { record.result = nil }
            }
            records.append(record)
        }
        return records
    }

    /// Loads an older receipt on demand instead of retaining all results in memory.
    public func read(_ id: UUID) throws -> AgentTaskRecord? {
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(AgentTaskRecord.self, from: Data(contentsOf: file))
    }

    /// Atomically saves a receipt inside a user-private directory.
    public func save(_ record: AgentTaskRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(record.id.uuidString + ".json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
