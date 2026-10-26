import Foundation
import Darwin

/// Private atomic receipts, kept separate from the task receipt directory.
public actor AgentTaskFileTurnRepository: AgentTaskTurnRepository {
    private let directory: URL
    private let fileManager: FileManager

    /// Opens an app-owned turn directory; use a different directory from task receipts.
    /// - Parameters:
    ///   - directory: Explicit persistence location, with no global default.
    ///   - fileManager: Filesystem access, injectable for isolated callers.
    public init(directory: URL, fileManager: FileManager = FileManager()) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Loads unfinished receipts for restart reconciliation without retaining completed bodies.
    /// - Returns: Receipts that cannot establish provider completion.
    /// - Throws: Filesystem or decoding errors, rather than silently losing deduplication data.
    public func unfinished() throws -> [AgentTaskTurnRecord] {
        try files().compactMap { file in
            let record = try decode(file)
            return record.phase.isFinished ? nil : record
        }
    }

    /// Reads any saved operation, including archived results.
    /// - Parameter operationID: The globally unique submission identity.
    /// - Returns: Its complete receipt, when present.
    /// - Throws: Filesystem or decoding errors.
    public func read(_ operationID: UUID) throws -> AgentTaskTurnRecord? {
        let file = location(operationID)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let record = try decode(file)
        guard record.operationID == operationID else { throw AgentTaskTurnRepositoryError.conflict }
        return record
    }

    /// Reads ordered history on demand rather than caching old result bodies.
    /// - Parameter taskID: The stable conversation identity.
    /// - Returns: All saved turns, in admission order.
    /// - Throws: Filesystem or decoding errors.
    public func turns(taskID: UUID) throws -> [AgentTaskTurnRecord] {
        try files().map { try decode($0) }.filter { $0.taskID == taskID }.sorted { $0.sequence < $1.sequence }
    }

    /// Replays durable receipts one body at a time for passive crash recovery, without provider I/O.
    /// - Parameter visitor: Awaited before loading the next receipt; no unbounded body buffer is created.
    /// - Throws: Storage, decoding or visitor errors. No model input is submitted.
    public func visitReceipts(_ visitor: @escaping @Sendable (AgentTaskTurnRecord) async throws -> Void) async throws {
        for file in try files() {
            try Task.checkCancellation()
            try await visitor(decode(file))
        }
    }

    /// Atomically saves intent or a transition with user-only directory and file permissions.
    /// - Parameter record: A receipt with an immutable submission payload.
    /// - Throws: Identity conflicts, encoding errors, or filesystem errors.
    public func save(_ record: AgentTaskTurnRecord) throws {
        if let old = try read(record.operationID) {
            guard old.matches(taskID: record.taskID, prompt: record.prompt), old.sequence == record.sequence else {
                throw AgentTaskTurnRepositoryError.conflict
            }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = location(record.operationID)
        // Set the temporary inode's mode before rename, so plaintext is never world-readable.
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporary) }
        try JSONEncoder().encode(record).write(to: temporary)
        if fileManager.fileExists(atPath: file.path) {
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        let parent = open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func decode(_ file: URL) throws -> AgentTaskTurnRecord {
        let record = try JSONDecoder().decode(AgentTaskTurnRecord.self, from: Data(contentsOf: file))
        guard file.deletingPathExtension().lastPathComponent == record.operationID.uuidString,
              record.prompt.utf8.count <= 200_000, record.sequence > 0 else {
            throw AgentTaskTurnRepositoryError.conflict
        }
        return record
    }

    private func files() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
}
