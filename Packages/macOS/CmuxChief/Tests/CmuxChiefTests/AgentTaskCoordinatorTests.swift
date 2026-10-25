import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Managed agent tasks")
struct AgentTaskCoordinatorTests {
    private func request(_ presentation: AgentTaskRequest.Presentation = .terminal, parent: UUID? = nil) -> AgentTaskRequest {
        AgentTaskRequest(provider: .codex, prompt: "Review this task", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), model: "gpt-6-luna",
                         presentation: presentation, parentTaskID: parent)
    }

    @Test func visibleTaskOpensOneTabOnlyAfterProviderSession() async throws {
        let backend = TaskTestBackend(), repository = TaskTestRepository(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        let record = try await coordinator.start(request())
        #expect(views.opened.isEmpty)
        try await coordinator.receive(.session("real-session"), id: record.id)
        try await coordinator.receive(.session("real-session"), id: record.id)
        #expect(views.opened.count == 1)
        #expect(views.opened.first?.workspaceID == record.workspaceID)
        #expect(coordinator.records[record.id]?.surfaceID != nil)
        try await coordinator.cancel(record.id)
    }

    @Test func backgroundTaskNeverCreatesATerminal() async throws {
        let backend = TaskTestBackend(), repository = TaskTestRepository(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        let record = try await coordinator.start(request(.background))
        try await coordinator.receive(.session("real-session"), id: record.id)
        try await coordinator.receive(.completed("Design result"), id: record.id)
        #expect(views.opened.isEmpty)
        #expect(coordinator.records[record.id]?.result == "Design result")
        #expect(coordinator.records[record.id]?.phase == .completed)
    }

    @Test func disconnectionPreservesUncertaintyAndCompletedReceiptsAreFinal() async throws {
        let backend = TaskTestBackend(), repository = TaskTestRepository(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        let record = try await coordinator.start(request(.background))
        try await coordinator.receive(.running, id: record.id)
        try await coordinator.receive(.disconnected("Socket lost"), id: record.id)
        #expect(coordinator.records[record.id]?.phase == .disconnected)
        #expect(coordinator.records[record.id]?.result == nil)
        try await coordinator.receive(.completed("Confirmed result"), id: record.id)
        try await coordinator.receive(.disconnected("Late close"), id: record.id)
        #expect(coordinator.records[record.id]?.phase == .completed)
        #expect(coordinator.records[record.id]?.result == "Confirmed result")
    }

    @Test func cannotRetargetATaskToAnotherSession() async throws {
        let backend = TaskTestBackend(), repository = TaskTestRepository(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        let record = try await coordinator.start(request(.background))
        try await coordinator.receive(.session("original"), id: record.id)
        await #expect(throws: (any Error).self) { try await coordinator.receive(.session("other"), id: record.id) }
        #expect(coordinator.records[record.id]?.sessionID == "original")
        try await coordinator.cancel(record.id)
    }

    @Test func cancellingAParentLeavesUnrelatedTasksAlone() async throws {
        let backend = TaskTestBackend(), repository = TaskTestRepository(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        let parent = try await coordinator.start(request(.background))
        let child = try await coordinator.start(request(.background, parent: parent.id))
        let other = try await coordinator.start(request(.background))
        try await coordinator.cancel(parent.id)
        #expect(coordinator.records[parent.id]?.phase == .cancelled)
        #expect(coordinator.records[child.id]?.phase == .cancelled)
        #expect(coordinator.records[other.id]?.phase == .starting)
        #expect(await backend.cancelled.contains(parent.id))
        #expect(await backend.cancelled.contains(child.id))
        #expect(await !backend.cancelled.contains(other.id))
        try await coordinator.cancel(other.id)
    }

    @Test func restartRestoresReceiptsWithoutLaunchingProviders() async throws {
        let repository = TaskTestRepository(), views = TaskTestViews()
        let original = AgentTaskRecord(id: UUID(), request: request(), now: Date())
        await repository.save(original)
        let backend = TaskTestBackend()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        try await coordinator.restore()
        #expect(coordinator.records[original.id]?.phase == .disconnected)
        #expect(await backend.started.isEmpty)
        #expect(views.opened.isEmpty)
    }

    @Test func persistenceFailurePreventsExecution() async throws {
        let backend = TaskTestBackend(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: FailingTaskRepository(), present: views.open)
        await #expect(throws: (any Error).self) { try await coordinator.start(request()) }
        #expect(await backend.started.isEmpty)
        #expect(coordinator.records.isEmpty)
    }

    @Test func rejectedCancellationRemainsUncertain() async throws {
        let backend = TaskTestBackend(failCancellation: true), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TaskTestRepository(), present: views.open)
        let record = try await coordinator.start(request(.background))
        await #expect(throws: (any Error).self) { try await coordinator.cancel(record.id) }
        #expect(coordinator.records[record.id]?.phase == .disconnected)
        #expect(coordinator.records[record.id]?.phase != .cancelled)
    }

    @Test func oldReceiptsRemainReadableOutsideBoundedHistory() async throws {
        let repository = TaskTestRepository(), views = TaskTestViews()
        var oldest: AgentTaskRecord?
        for index in 0..<101 {
            var record = AgentTaskRecord(id: UUID(), request: request(), now: Date(timeIntervalSince1970: Double(index)))
            record.phase = .completed; record.result = "Archived result"
            await repository.save(record)
            if index == 0 { oldest = record }
        }
        let coordinator = AgentTaskCoordinator(backend: TaskTestBackend(), repository: repository, present: views.open)
        try await coordinator.restore()
        let id = try #require(oldest?.id)
        #expect(coordinator.records.count == 100)
        #expect(coordinator.records[id] == nil)
        #expect(try await coordinator.record(id)?.result == "Archived result")
        #expect(views.opened.isEmpty)
    }

    @Test func missingDirectoryCannotLaunchInAnUnrelatedFallbackDirectory() async throws {
        let backend = TaskTestBackend(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TaskTestRepository(), present: views.open)
        var input = request()
        input.workingDirectory = URL(fileURLWithPath: "/tmp/" + UUID().uuidString)
        await #expect(throws: (any Error).self) { try await coordinator.start(input) }
        #expect(await backend.started.isEmpty)
    }

    @Test func restoredProviderCannotBeReportedCancelledWithoutReconciliation() async throws {
        let repository = TaskTestRepository(), views = TaskTestViews()
        var record = AgentTaskRecord(id: UUID(), request: request(.background), now: Date())
        record.phase = .running; record.sessionID = "previously-running-daemon-session"
        await repository.save(record)
        let backend = AgentManagedTaskBackend(socketPath: "/tmp/" + UUID().uuidString, cancelTerminal: { _ in })
        let coordinator = AgentTaskCoordinator(backend: backend, repository: repository, present: views.open)
        try await coordinator.restore()
        await #expect(throws: (any Error).self) { try await coordinator.cancel(record.id) }
        #expect(coordinator.records[record.id]?.phase == .disconnected)
    }

    @Test func uncertainChildDoesNotPreventOtherCancellationAttempts() async throws {
        let backend = TaskTestBackend(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TaskTestRepository(), present: views.open)
        let parent = try await coordinator.start(request(.background))
        let uncertain = try await coordinator.start(request(.background, parent: parent.id))
        let sibling = try await coordinator.start(request(.background, parent: parent.id))
        await backend.failCancel(uncertain.id)
        await #expect(throws: (any Error).self) { try await coordinator.cancel(parent.id) }
        #expect(await backend.attempted.contains(parent.id))
        #expect(await backend.attempted.contains(sibling.id))
        #expect(coordinator.records[parent.id]?.phase == .cancelled)
        #expect(coordinator.records[sibling.id]?.phase == .cancelled)
        #expect(coordinator.records[uncertain.id]?.phase == .disconnected)
    }

    @Test func cancellationTraversesCompletedParentsOfLiveDescendants() async throws {
        let backend = TaskTestBackend(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TaskTestRepository(), present: views.open)
        let root = try await coordinator.start(request(.background))
        let child = try await coordinator.start(request(.background, parent: root.id))
        let descendant = try await coordinator.start(request(.background, parent: child.id))
        try await coordinator.receive(.completed("First turn done"), id: child.id)
        try await coordinator.cancel(root.id)
        #expect(await backend.cancelled.contains(descendant.id))
        #expect(coordinator.records[child.id]?.phase == .completed)
        try await coordinator.cancel(descendant.id)
    }

    @Test func boundedHistoryRetainsAncestorsOfUnfinishedTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileRepository(directory: directory), views = TaskTestViews()
        var parent = AgentTaskRecord(id: UUID(), request: request(), now: Date(timeIntervalSince1970: 0))
        parent.phase = .completed
        try await repository.save(parent)
        let child = AgentTaskRecord(id: UUID(), request: request(.background, parent: parent.id), now: Date(timeIntervalSince1970: 1))
        try await repository.save(child)
        for index in 2..<104 {
            var other = AgentTaskRecord(id: UUID(), request: request(), now: Date(timeIntervalSince1970: Double(index)))
            other.phase = .completed
            try await repository.save(other)
        }
        let coordinator = AgentTaskCoordinator(backend: TaskTestBackend(), repository: repository, present: views.open)
        try await coordinator.restore()
        #expect(coordinator.records[parent.id] != nil)
        #expect(coordinator.records[child.id]?.parentTaskID == parent.id)
    }

    @Test func parentCompletionCannotHideUnconfirmedChildCancellation() async throws {
        let backend = TaskTestBackend(), views = TaskTestViews()
        let coordinator = AgentTaskCoordinator(backend: backend, repository: TaskTestRepository(), present: views.open)
        let parent = try await coordinator.start(request(.background))
        let child = try await coordinator.start(request(.background, parent: parent.id))
        await backend.failCancel(child.id)
        await backend.beforeCancel(parent.id) { [weak coordinator] in
            try? await coordinator?.receive(.cancelled, id: parent.id)
        }
        await #expect(throws: (any Error).self) { try await coordinator.cancel(parent.id) }
        #expect(coordinator.records[parent.id]?.phase == .cancelled)
        #expect(coordinator.records[child.id]?.phase == .disconnected)
    }

    @Test func receiptsUsePrivateFilesAndRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileRepository(directory: directory)
        var record = AgentTaskRecord(id: UUID(), request: request(), now: Date())
        record.phase = .completed; record.result = "Result"
        try await repository.save(record)
        #expect(try await repository.load() == [record])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(record.id.uuidString + ".json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

private actor TaskTestBackend: AgentTaskBackend {
    let failCancellation: Bool
    init(failCancellation: Bool = false) { self.failCancellation = failCancellation }
    var started: [UUID] = []
    var cancelled: Set<UUID> = []
    var attempted: Set<UUID> = []
    var failures: Set<UUID> = []
    func failCancel(_ id: UUID) { failures.insert(id) }
    var callbacks: [UUID: @Sendable () async -> Void] = [:]
    func beforeCancel(_ id: UUID, _ callback: @escaping @Sendable () async -> Void) { callbacks[id] = callback }
    private var streams: [UUID: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation] = [:]
    func start(id: UUID, request: AgentTaskRequest) -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        started.append(id)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AgentTaskEvent.self)
        streams[id] = continuation
        return stream
    }
    func cancel(id: UUID) async throws {
        attempted.insert(id)
        if failCancellation || failures.contains(id) { throw CocoaError(.fileWriteUnknown) }
        if let callback = callbacks.removeValue(forKey: id) { await callback() }
        cancelled.insert(id); streams.removeValue(forKey: id)?.finish()
    }
}

private actor TaskTestRepository: AgentTaskRepository {
    private var records: [UUID: AgentTaskRecord] = [:]
    func load() -> [AgentTaskRecord] { Array(records.values) }
    func save(_ record: AgentTaskRecord) { records[record.id] = record }
}

private struct FailingTaskRepository: AgentTaskRepository {
    func load() -> [AgentTaskRecord] { [] }
    func save(_ record: AgentTaskRecord) throws { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor private final class TaskTestViews {
    var opened: [AgentTaskRecord] = []
    func open(_ record: AgentTaskRecord, _ request: AgentTaskRequest) -> UUID { opened.append(record); return UUID() }
}
