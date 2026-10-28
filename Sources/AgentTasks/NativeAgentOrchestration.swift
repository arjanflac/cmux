import AppKit
import CmuxChief
import CmuxFoundation
import CmuxSettings
import CryptoKit
import Darwin
import Foundation

/// Composes scoped control, durable scheduling and passive frontend delivery for this app instance.
@MainActor
final class NativeAgentOrchestration {
    unowned let runtime: NativeAgentTaskRuntime
    let authority = AgentTaskScopeAuthority()
    let journal: AgentTaskJournal
    let ledger: AgentTaskCommandLedger
    let panelsStore: AgentTaskPanelRepository
    var panels: [UUID: NativeAgentTaskPanel] = [:]
    var commandTasks: [UUID: Task<Data, any Error>] = [:]
    var responseOwners: [String: String] = [:]
    var schedulerStorage: AgentTaskScheduler?
    var timer: Task<Void, Never>?
    var timerGeneration = UUID()
    var wakeObserver: NSObjectProtocol?
    var clockObserver: NSObjectProtocol?
    var storageFailure: String?
    var restored = false
    var restoring: Task<Void, any Error>?

    init(runtime: NativeAgentTaskRuntime, directory: URL) throws {
        self.runtime = runtime
        journal = try AgentTaskJournal(databaseURL: directory.appendingPathComponent("orchestration.sqlite"))
        ledger = AgentTaskCommandLedger(directory: directory.appendingPathComponent("commands"))
        panelsStore = AgentTaskPanelRepository(directory: directory.appendingPathComponent("panels"))
        let journal = self.journal
        runtime.coordinator.setRetirementPermit { taskID in try await !journal.preventsRetirement(of: taskID) }
    }

    var enabled: Bool {
        UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().terminal.agentOrchestration)
    }

    func noteStorageFailure(_ error: any Error) {
        storageFailure = String(describing: error)
        timer?.cancel()
    }

    /// Startup and wake recovery read receipts, never replay provider prompts.
    func restore() async throws {
        if restored { return }
        if let restoring { return try await restoring.value }
        let task = Task { @MainActor in
            let scheduler = try self.makeScheduler()
            self.schedulerStorage = scheduler
            try await scheduler.restore()
            try await self.runtime.turnRepository.visitReceipts { [weak self] turn in
                try await self?.reconcileTurnReceipt(turn)
            }
            try await self.runtime.coordinator.finishPendingRetirements()
            self.restored = true
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.wake() } }
            self.clockObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.wake() } }
            await self.armTimer()
        }
        restoring = task
        try await task.value
    }

    func makeScheduler() throws -> AgentTaskScheduler {
        try AgentTaskScheduler(journal: journal, authorize: { [weak self] schedule in
            guard let self else { throw CocoaError(.userCancelled) }
            try await self.authorizeSchedule(schedule)
        }, preflight: { [weak self] schedule in
            guard let self else { throw CocoaError(.userCancelled) }
            try await self.preflightSchedule(schedule)
        }, dispatch: { [weak self] target, prompt, operation in
            guard let self else { throw CocoaError(.userCancelled) }
            return try await self.dispatchSchedule(target, prompt: prompt, operationID: operation)
        })
    }

    func wake() async {
        do {
            guard let schedulerStorage, storageFailure == nil else { return }
            // A wake preserves this process's live provider handles. Launch-only recovery
            // reconciles lost handles; treating a wake as launch would mark live work uncertain.
            try await schedulerStorage.runDue()
            await armTimer()
        } catch { noteStorageFailure(error) }
    }

    /// One timer serves every schedule and every aggregate view.
    func armTimer() async {
        timer?.cancel()
        timer = nil
        let generation = UUID()
        timerGeneration = generation
        guard storageFailure == nil, let schedulerStorage else { return }
        do {
            let next = try await schedulerStorage.nextDueDate()
            guard timerGeneration == generation else { return }
            let refresh = panels.isEmpty ? nil : Date().addingTimeInterval(20)
            guard let due = [next, refresh].compactMap({ $0 }).min() else { return }
            let seconds = max(0.1, min(due.timeIntervalSinceNow, 86_400))
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, self.timerGeneration == generation else { return }
                // Only sleeping timers can be cancelled by rearming. An admitted due
                // pass owns its provider submission until a receipt settles it.
                self.timer = nil
                do {
                    try await self.refreshPanels()
                    try await schedulerStorage.runDue()
                    await self.armTimer()
                } catch { self.noteStorageFailure(error) }
            }
        } catch { noteStorageFailure(error) }
    }

    func ensureHealthy() throws {
        guard storageFailure == nil else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Stable operation identity does not rely on process environment or presentation IDs.
    func identity(_ text: String) -> UUID {
        if let id = UUID(uuidString: text) { return id }
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }

    func data(_ object: [String: Any]) throws -> Data {
        var value = object
        var result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if var text = value["result"] as? String {
            while result.count > 60_000, !text.isEmpty {
                text = String(text.prefix(max(0, text.count * 3 / 4)))
                value["result"] = text
                value["result_truncated"] = true
                result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            }
        }
        guard result.count <= 65_536 else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}
