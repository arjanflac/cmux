import Foundation
import Observation

/// Owns explicit task relationships; never guesses an ordinary TUI's selected thread.
@MainActor @Observable
public final class AgentTaskCoordinator {
    /// Creates a terminal in the requested existing workspace and returns its identity.
    public typealias Present = @MainActor @Sendable (AgentTaskRecord, AgentTaskRequest) async throws -> UUID
    /// Last confirmed receipts, including tasks restored without a live provider connection.
    public private(set) var records: [UUID: AgentTaskRecord] = [:]
    private let backend: any AgentTaskBackend
    private let repository: any AgentTaskRepository
    private let present: Present
    private var consumers: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<AgentTaskRecord>.Continuation] = [:]
    private var requests: [UUID: AgentTaskRequest] = [:]
    private var starting: Set<UUID> = []
    private var presenting: Set<UUID> = []
    private var cancelling: Set<UUID> = []
    private var persistence: Task<Void, any Error>?

    /// Injects execution, persistence, and native window presentation.
    public init(backend: any AgentTaskBackend, repository: any AgentTaskRepository, present: @escaping Present) {
        self.backend = backend
        self.repository = repository
        self.present = present
    }

    /// Restores receipts as disconnected when their previous provider state is unknown.
    public func restore() async throws {
        for var record in try await repository.load() {
            if !record.phase.isFinished {
                record.phase = .disconnected
                record.detail = "restart_unreconciled"
            }
            records[record.id] = record
        }
        pruneReceipts()
    }

    /// Starts a fresh child task, persisting its receipt before any execution.
    @discardableResult
    public func start(_ request: AgentTaskRequest, id: UUID = UUID()) async throws -> AgentTaskRecord {
        guard records[id] == nil, starting.insert(id).inserted else { throw TaskError.duplicate }
        defer { starting.remove(id) }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: request.workingDirectory.path, isDirectory: &directory)
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= 200_000,
              request.workingDirectory.isFileURL, request.workingDirectory.path.hasPrefix("/"),
              exists, directory.boolValue else { throw TaskError.invalid }
        try validateParent(request.parentTaskID)
        let record = AgentTaskRecord(id: id, request: request, now: Date())
        try await save(record)
        try validateParent(request.parentTaskID)
        records[id] = record
        requests[id] = request
        publish(record)
        consumers[id] = Task { [weak self, backend] in
            guard !Task.isCancelled else { return }
            do {
                let events = try await backend.start(id: id, request: request)
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    try await self?.receive(event, id: id)
                }
                if let self, let current = self.records[id], !current.phase.isFinished, current.phase != .disconnected {
                    try await self.receive(.disconnected("stream_ended_without_completion"), id: id)
                }
            } catch {
                try? await self?.receive(.disconnected(String(describing: error)), id: id)
            }
            self?.consumers.removeValue(forKey: id)
        }
        return record
    }

    /// Applies a provider receipt. Terminal presentation happens once, after a real session exists.
    public func receive(_ event: AgentTaskEvent, id: UUID) async throws {
        guard var record = records[id], !record.phase.isFinished else { return }
        switch event {
        case .session(let session):
            guard record.sessionID == nil || record.sessionID == session else { throw TaskError.sessionChanged }
            record.sessionID = session
        case .running: record.phase = .running; record.detail = nil
        case .needsInput(let detail): record.phase = .needsInput; record.detail = detail
        case .completed(let text):
            record.phase = .completed; record.result = String(text.prefix(65_536))
            record.detail = text.count > 65_536 ? "result_truncated" : nil
        case .cancelled: record.phase = .cancelled; record.detail = nil
        case .failed(let reason): record.phase = .failed; record.detail = reason
        case .disconnected(let reason): record.phase = .disconnected; record.detail = reason
        }
        record.updatedAt = Date()
        records[id] = record
        try await save(record)
        if records[id] == record { publish(record) }
        if record.phase.isFinished { requests.removeValue(forKey: id); pruneReceipts() }
        if case .session = event, let latest = records[id], !latest.phase.isFinished,
           latest.presentation == .terminal, latest.surfaceID == nil,
           let request = requests[id], presenting.insert(id).inserted {
            defer { presenting.remove(id) }
            let surface: UUID
            do { surface = try await present(record, request) }
            catch {
                // A requested visible task must not silently continue headless.
                try await cancel(id)
                throw error
            }
            // Cancellation during presentation must not restore a stale running state.
            guard var current = records[id], !current.phase.isFinished else { return }
            current.surfaceID = surface
            current.updatedAt = Date()
            records[id] = current
            try await save(current)
            if records[id] == current { publish(current) }
        }
    }

    /// Cancels the task and its known descendants, without touching unrelated agents.
    public func cancel(_ id: UUID) async throws {
        guard records[id] != nil, cancelling.insert(id).inserted else { return }
        defer { cancelling.remove(id) }
        for child in records.values.filter({ $0.parentTaskID == id && !$0.phase.isFinished }).map(\.id) {
            try await cancel(child)
        }
        guard let before = records[id], !before.phase.isFinished else { return }
        do { try await backend.cancel(id: id) }
        catch {
            try await receive(.disconnected("cancellation_unconfirmed: \(error)"), id: id)
            throw error
        }
        guard var record = records[id], !record.phase.isFinished else { return }
        record.phase = .cancelled
        record.updatedAt = Date()
        records[id] = record
        try await save(record)
        if records[id] == record { publish(record) }
        consumers.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)
    }

    /// Parks on native events for at most 15 seconds, returning the latest receipt.
    public func wait(_ id: UUID) async throws -> AgentTaskRecord {
        guard let record = try await record(id) else { throw TaskError.invalid }
        if record.phase.isFinished || record.phase == .disconnected { return record }
        let events = changes()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events where event.id == id { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(15)) }
            await group.next()
            group.cancelAll()
        }
        return records[id] ?? record
    }

    /// Reads a recent or archived receipt without reconnecting to a provider.
    public func record(_ id: UUID) async throws -> AgentTaskRecord? {
        if let record = records[id] { return record }
        guard var record = try await repository.read(id) else { return nil }
        if !record.phase.isFinished { record.phase = .disconnected; record.detail = "restart_unreconciled" }
        return record
    }

    /// Streams state transitions. Dropped viewers cannot retain the coordinator.
    public func changes() -> AsyncStream<AgentTaskRecord> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AgentTaskRecord.self, bufferingPolicy: .bufferingNewest(64))
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: token) } }
        return stream
    }

    private func publish(_ record: AgentTaskRecord) {
        for continuation in subscribers.values { continuation.yield(record) }
    }

    private func pruneReceipts() {
        let history = records.values.filter { $0.phase.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
        for old in history.dropFirst(100) { records.removeValue(forKey: old.id) }
    }

    private func validateParent(_ id: UUID?) throws {
        guard let id else { return }
        guard let parent = records[id] else { throw TaskError.unknownParent }
        guard !cancelling.contains(id), parent.phase != .cancelled else { throw CancellationError() }
    }

    // Serialize disk writes across main-actor suspension points so a late write
    // cannot replace a newer terminal receipt.
    private func save(_ record: AgentTaskRecord) async throws {
        let previous = persistence
        let next = Task { [repository] in
            _ = try? await previous?.value
            try await repository.save(record)
        }
        persistence = next
        try await next.value
    }

    enum TaskError: Error { case duplicate, invalid, unknownParent, sessionChanged }
}
