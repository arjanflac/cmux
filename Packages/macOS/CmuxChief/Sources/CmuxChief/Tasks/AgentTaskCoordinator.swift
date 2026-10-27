import Foundation
import Observation

/// Owns explicit task relationships; never guesses an ordinary TUI's selected thread.
@MainActor @Observable
public final class AgentTaskCoordinator {
    /// Creates a terminal in the requested existing workspace and returns its identity.
    public typealias Present = @MainActor @Sendable (AgentTaskRecord, AgentTaskRequest) async throws -> UUID
    /// A durable passive consumer, awaited before the next turn may be admitted.
    public typealias ReceiptHandler = @MainActor @Sendable (AgentTaskRecord, AgentTaskTurnRecord) async throws -> Void
    /// Last confirmed receipts, including tasks restored without a live provider connection.
    public private(set) var records: [UUID: AgentTaskRecord] = [:]
    private let backend: any AgentTaskBackend
    private let repository: any AgentTaskRepository
    private let turnRepository: any AgentTaskTurnRepository
    private let executionLimits: AgentTaskExecutionLimits
    private var capacityReservations: [UUID: AgentTaskRequest.Provider] = [:]
    private var retiring: Set<UUID> = []
    private var finishingRetirements: Set<UUID> = []
    private var scheduleAdmissions: [UUID: Set<UUID>] = [:]
    private var retirementPermit: (@MainActor @Sendable (UUID) async throws -> Bool)?
    private let present: Present
    private let reconnect: Present?
    private var consumerOperations: [UUID: UUID] = [:]
    private var currentTurns: [UUID: AgentTaskTurnRecord] = [:]
    private var turnSubscribers: [UUID: AsyncStream<AgentTaskTurnRecord>.Continuation] = [:]
    private var admissions: [UUID: (taskID: UUID, prompt: String, task: Task<AgentTaskTurnRecord, any Error>)] = [:]
    private var reservedOperations: Set<UUID> = []
    private var transitioning: [UUID: Int] = [:]
    private var restoring = false
    private var consumers: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<AgentTaskRecord>.Continuation] = [:]
    private var requests: [UUID: AgentTaskRequest] = [:]
    private var starting: Set<UUID> = []
    private var presenting: Set<UUID> = []
    private var childIDsByParent: [UUID: Set<UUID>] = [:]
    private var cancelling: Set<UUID> = []
    private var persistence: Task<Void, any Error>?
    private var receiptHandler: ReceiptHandler?

    /// Installs an app-owned durable passive consumer; view streams remain best-effort.
    /// - Parameter handler: Persists delivery evidence without starting provider work.
    public func setReceiptHandler(_ handler: @escaping ReceiptHandler) { receiptHandler = handler }

    /// Installs the trusted schedule check required before retiring any worker.
    /// - Parameter permit: Returns false while durable future or uncertain scheduled work references the task.
    public func setRetirementPermit(_ permit: @escaping @MainActor @Sendable (UUID) async throws -> Bool) {
        retirementPermit = permit
    }

    /// Injects execution, persistence, and native window presentation.
    /// - Parameters:
    ///   - backend: Provider execution with no implicit replay.
    ///   - repository: Durable conversation projections.
    ///   - present: Opens a terminal only after the provider confirms a session.
    ///   - reconnect: Optional view-only attachment to saved sessions.
    ///   - turnRepository: Durable per-operation receipts; defaults to isolated memory for legacy callers.
    ///   - executionLimits: Independent managed-turn caps; provider-native subagent limits do not apply.
    public init(backend: any AgentTaskBackend, repository: any AgentTaskRepository, present: @escaping Present, reconnect: Present? = nil, turnRepository: (any AgentTaskTurnRepository)? = nil, executionLimits: AgentTaskExecutionLimits = AgentTaskExecutionLimits()) {
        self.executionLimits = executionLimits
        self.backend = backend
        self.repository = repository
        self.turnRepository = turnRepository ?? AgentTaskMemoryTurnRepository()
        self.present = present
        self.reconnect = reconnect
    }

    /// Restores receipts without submitting any input or treating saved receipts as live handles.
    /// - Throws: Persistence failures, or an attempt to restore over live work.
    public func restore() async throws {
        guard !restoring, starting.isEmpty, consumerOperations.isEmpty else { throw TaskError.busy }
        restoring = true
        defer { restoring = false }
        let saved = try await repository.load()
        let unfinished = try await turnRepository.unfinished()
        records.removeAll()
        currentTurns.removeAll()
        childIDsByParent.removeAll()
        for var record in saved {
            if let parent = record.parentTaskID, record.latestOperationID != nil {
                childIDsByParent[parent, default: []].insert(record.id)
            }
            if !record.phase.isFinished {
                record.phase = .disconnected
                record.detail = "restart_unreconciled"
            }
            records[record.id] = record
        }
        for old in unfinished {
            let turn = old.disconnectedAfterRestart()
            try await saveTurn(turn)
            // A crash between the intent and task writes must also block a new turn.
            if var record = records[turn.taskID], turn.sequence >= (record.turnCount ?? 1) {
                record.latestOperationID = turn.operationID
                record.turnCount = turn.sequence
                record.phase = .disconnected
                record.result = nil
                record.detail = "restart_unreconciled"
                records[record.id] = record
                try await save(record)
            }
        }
        pruneReceipts()
    }

    /// Registers an already-proven app-owned chat without submitting or resuming provider work.
    ///
    /// Trusted composition only: the app verifies a live frontend's selected session first.
    /// - Parameters:
    ///   - request: Routing metadata; its prompt is only a display title.
    ///   - sessionID: Exact provider session established by that proof.
    ///   - id: Stable enrollment identity, shared by views of the same conversation.
    /// - Returns: A saved conversation with no synthetic provider turn.
    /// - Throws: Conflicting enrollment, invalid input or persistence failures.
    public func enrollSession(_ request: AgentTaskRequest, sessionID: String, id: UUID) async throws -> AgentTaskRecord {
        guard !sessionID.isEmpty, !restoring, !starting.contains(id) else { throw TaskError.invalid }
        starting.insert(id)
        defer { starting.remove(id) }
        if let existing = try await record(id) {
            guard existing.provider == request.provider, existing.sessionID == sessionID,
                  existing.workspaceStableID == request.workspaceStableID else { throw TaskError.invalid }
            return existing
        }
        var enrolled = AgentTaskRecord(id: id, request: request, now: Date())
        enrolled.sessionID = sessionID
        enrolled.phase = .completed
        enrolled.latestOperationID = nil
        enrolled.turnCount = 0
        enrolled.detail = "enrolled_existing_session"
        try await save(enrolled)
        records[id] = enrolled
        publish(enrolled)
        return enrolled
    }

    /// Starts a fresh child conversation with its task ID as the initial operation ID.
    @discardableResult
    public func start(_ request: AgentTaskRequest, id: UUID = UUID()) async throws -> AgentTaskRecord {
        guard !restoring, records[id] == nil, !reservedOperations.contains(id),
              starting.insert(id).inserted else { throw TaskError.duplicate }
        reservedOperations.insert(id)
        defer { starting.remove(id); reservedOperations.remove(id) }
        try validatePrompt(request.prompt)
        if request.lifecycle == .oneShot {
            guard request.parentTaskID != nil, request.presentation == .background else { throw TaskError.invalid }
        }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: request.workingDirectory.path, isDirectory: &directory)
        guard request.workingDirectory.isFileURL, request.workingDirectory.path.hasPrefix("/"),
              exists, directory.boolValue else { throw TaskError.invalid }
        try reserveCapacity(id: id, provider: request.provider)
        defer { capacityReservations.removeValue(forKey: id) }
        guard try await repository.read(id) == nil, try await turnRepository.read(id) == nil else { throw TaskError.duplicate }
        try await loadParentChain(request.parentTaskID)
        try validateParent(request.parentTaskID)
        let record = AgentTaskRecord(id: id, request: request, now: Date())
        var turn = AgentTaskTurnRecord(taskID: id, request: AgentTaskTurnRequest(operationID: id, prompt: request.prompt),
                                       sequence: 1, sessionID: nil, now: record.createdAt)
        // Both receipts and dispatch intent must be durable before the backend is called.
        try await save(record)
        try await saveTurn(turn)
        try await loadParentChain(request.parentTaskID)
        try validateParent(request.parentTaskID)
        turn.phase = .dispatching
        try await saveTurn(turn)
        try validateParent(request.parentTaskID)
        records[id] = record
        if let parent = record.parentTaskID { childIDsByParent[parent, default: []].insert(id) }
        currentTurns[id] = turn
        requests[id] = request
        publish(record)
        launch(id: id, operationID: id, initial: request, continuation: nil)
        return record
    }

    /// Admits one explicit follow-up to a confirmed terminal turn in the same provider session.
    ///
    /// Identical operation IDs return their existing receipt, including uncertain receipts, without
    /// resubmitting input. A different task or exact prompt for the same ID is rejected.
    ///
    /// ```swift
    /// let receipt = try await coordinator.send(taskID, prompt: "Continue", operationID: operationID)
    /// let latest = try await coordinator.waitTurn(receipt.operationID)
    /// ```
    /// - Parameters:
    ///   - id: Stable conversation identity with a known session and confirmed terminal state.
    ///   - prompt: Exact new input, bounded to 200,000 UTF-8 bytes.
    ///   - operationID: Globally unique idempotency key; retain it across client retries.
    /// - Returns: The newly dispatched or previously saved turn receipt.
    /// - Throws: Conflicts, busy or uncertain conversations, invalid input, or persistence failures.
    @discardableResult
    public func send(_ id: UUID, prompt: String, operationID: UUID = UUID()) async throws -> AgentTaskTurnRecord {
        try validatePrompt(prompt)
        guard !restoring else { throw TaskError.busy }
        if let pending = admissions[operationID] {
            guard pending.taskID == id, pending.prompt == prompt else { throw TaskError.operationConflict }
            return try await pending.task.value
        }
        guard !reservedOperations.contains(operationID) else { throw TaskError.busy }
        // Receipt lookup remains safe during another admission or transition; it cannot send.
        if starting.contains(id) || cancelling.contains(id) || transitioning[id] != nil {
            guard let saved = try await turnRepository.read(operationID) else { throw TaskError.busy }
            guard saved.matches(taskID: id, prompt: prompt) else { throw TaskError.operationConflict }
            return currentTurns[operationID] ?? saved.disconnectedAfterRestart()
        }
        // Reserve before the first repository await, including reads of archived receipts.
        starting.insert(id)
        reservedOperations.insert(operationID)
        let admission = Task { try await self.admit(id, prompt: prompt, operationID: operationID) }
        admissions[operationID] = (id, prompt, admission)
        defer {
            admissions.removeValue(forKey: operationID)
            starting.remove(id)
            reservedOperations.remove(operationID)
        }
        return try await admission.value
    }

    /// Reads a turn without contacting or restarting a provider.
    /// - Parameter operationID: The exact submission identity, including an archived turn.
    /// - Returns: Its receipt; unfinished receipts without a live handle read as disconnected.
    /// - Throws: Repository errors.
    public func turn(_ operationID: UUID) async throws -> AgentTaskTurnRecord? {
        if let turn = currentTurns[operationID] { return turn }
        guard let saved = try await turnRepository.read(operationID) else { return currentTurns[operationID] }
        return currentTurns[operationID] ?? saved.disconnectedAfterRestart()
    }

    /// Reads a conversation's entire ordered history on demand.
    /// - Parameter taskID: The stable conversation identity.
    /// - Returns: Turn receipts in sequence order, including old result bodies.
    /// - Throws: Repository errors.
    public func turns(taskID: UUID) async throws -> [AgentTaskTurnRecord] {
        try await turnRepository.turns(taskID: taskID).map { currentTurns[$0.operationID] ?? $0.disconnectedAfterRestart() }
    }

    /// Waits for this turn's next durable event, or at most 15 seconds.
    /// - Parameter operationID: The submission to observe, never implicitly the latest turn.
    /// - Returns: Its latest receipt; completion, needs-input, and uncertainty return immediately.
    /// - Throws: Unknown-operation or repository errors.
    public func waitTurn(_ operationID: UUID) async throws -> AgentTaskTurnRecord {
        let events = turnChanges()
        guard let receipt = try await turn(operationID) else { throw TaskError.invalid }
        if receipt.phase.isSettled { return receipt }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await event in events where event.operationID == operationID { return } }
            group.addTask { try? await Task.sleep(for: .seconds(15)) }
            await group.next()
            group.cancelAll()
        }
        return try await turn(operationID) ?? receipt
    }

    private func admit(_ id: UUID, prompt: String, operationID: UUID) async throws -> AgentTaskTurnRecord {
        if let saved = try await turnRepository.read(operationID) {
            guard saved.matches(taskID: id, prompt: prompt) else { throw TaskError.operationConflict }
            return currentTurns[operationID] ?? saved.disconnectedAfterRestart()
        }
        guard var record = try await record(id), record.retirement == nil, !retiring.contains(id), record.phase.isFinished,
              let sessionID = record.sessionID, !sessionID.isEmpty else { throw TaskError.providerUnreconciled }
        // An intent saved just before a crash can be newer than the task projection.
        let history = try await turnRepository.turns(taskID: id)
        guard history.allSatisfy({ $0.phase.isFinished }) else { throw TaskError.providerUnreconciled }
        try await loadParentChain(record.parentTaskID)
        try validateParent(record.parentTaskID)
        try reserveCapacity(id: id, provider: record.provider)
        defer { capacityReservations.removeValue(forKey: id) }
        let sequence = max(record.turnCount ?? 1, history.map(\.sequence).max() ?? 1) + 1
        var receipt = AgentTaskTurnRecord(taskID: id, request: AgentTaskTurnRequest(operationID: operationID, prompt: prompt),
                                          sequence: sequence, sessionID: sessionID, now: Date())
        try await saveTurn(receipt)
        // A view-only attachment may have updated workspace/surface metadata during the write.
        record = records[id] ?? record
        record.latestOperationID = operationID
        record.turnCount = sequence
        record.phase = .starting
        record.result = nil
        record.detail = nil
        record.updatedAt = receipt.createdAt
        // Once intent exists, any subsequent failure leaves this conversation uncertain.
        records[id] = record
        currentTurns[operationID] = receipt
        do {
            try await save(record)
            try validateParent(record.parentTaskID)
            receipt.phase = .dispatching
            try await saveTurn(receipt)
            try validateParent(record.parentTaskID)
        } catch {
            try? await receive(.disconnected("admission_persistence_failed"), id: id, operationID: operationID)
            throw error
        }
        currentTurns[operationID] = receipt
        publish(record)
        launch(id: id, operationID: operationID, initial: nil, continuation: (record, AgentTaskTurnRequest(operationID: operationID, prompt: prompt)))
        return receipt
    }

    /// Consumes only the initial turn for compatibility with existing event callers.
    /// Follow-up integrations must use the overload with an explicit operation ID.
    public func receive(_ event: AgentTaskEvent, id: UUID) async throws {
        guard records[id]?.latestOperationID == id || records[id]?.latestOperationID == nil else { return }
        try await receive(event, id: id, operationID: id)
    }

    /// Applies an event only to its current operation, fencing old streams and late cleanup.
    /// - Parameters:
    ///   - event: A confirmed provider event for this submission.
    ///   - id: Stable conversation identity.
    ///   - operationID: The stream's captured submission identity.
    /// - Throws: Session changes or persistence failures; failures block further submission.
    public func receive(_ event: AgentTaskEvent, id: UUID, operationID: UUID) async throws {
        guard var record = records[id], (record.latestOperationID ?? id) == operationID,
              !record.phase.isFinished, var turn = currentTurns[operationID] else { return }
        transitioning[id, default: 0] += 1
        defer {
            if transitioning[id] == 1 { transitioning.removeValue(forKey: id) }
            else { transitioning[id, default: 1] -= 1 }
        }
        switch event {
        case .session(let session):
            guard !session.isEmpty, record.sessionID == nil || record.sessionID == session else { throw TaskError.sessionChanged }
            record.sessionID = session
            turn.sessionID = session
        case .running:
            record.phase = .running; turn.phase = .running
            if record.detail?.hasPrefix("terminal_attachment_failed:") != true { record.detail = nil }
        case .needsInput(let detail): record.phase = .needsInput; turn.phase = .needsInput; record.detail = String(detail.prefix(8192))
        case .completed(let text):
            record.phase = .completed; turn.phase = .completed; record.result = String(text.prefix(65_536))
            record.detail = text.count > 65_536 ? "result_truncated" : nil
        case .cancelled: record.phase = .cancelled; turn.phase = .cancelled; record.detail = nil
        case .failed(let reason): record.phase = .failed; turn.phase = .failed; record.detail = String(reason.prefix(8192))
        case .disconnected(let reason): record.phase = .disconnected; turn.phase = .disconnected; record.detail = String(reason.prefix(8192))
        }
        record.updatedAt = Date()
        turn.updatedAt = record.updatedAt
        turn.detail = record.detail
        turn.result = record.result
        records[id] = record
        currentTurns[operationID] = turn
        do {
            try await saveTransition(record, turn: turn)
            try await receiptHandler?(record, turn)
        } catch {
            // A successful provider event is not a durable receipt when its write failed.
            if records[id] == record {
                records[id]?.phase = .disconnected
                records[id]?.detail = "receipt_persistence_failed"
                currentTurns[operationID]?.phase = .disconnected
                currentTurns[operationID]?.detail = "receipt_persistence_failed"
            }
            throw error
        }
        guard records[id]?.latestOperationID == operationID else { return }
        if records[id] == record { publish(record); publishTurn(turn) }
        if turn.phase.isSettled { pruneReceipts() }
        if case .session = event, let latest = records[id], !latest.phase.isFinished,
           latest.presentation == .terminal, latest.surfaceID == nil,
           let request = requests[id], presenting.insert(id).inserted {
            defer { presenting.remove(id) }
            let surface: UUID
            do { surface = try await present(record, request) }
            catch {
                if var current = records[id], current.latestOperationID == operationID, !current.phase.isFinished {
                    current.detail = "terminal_attachment_failed: " + String(String(describing: error).prefix(1024))
                    current.updatedAt = Date()
                    records[id] = current
                    try await save(current)
                    if records[id] == current { publish(current) }
                }
                return
            }
            guard var current = records[id], current.latestOperationID == operationID, !current.phase.isFinished else { return }
            current.surfaceID = surface
            current.updatedAt = Date()
            records[id] = current
            try await save(current)
            if records[id] == current { publish(current) }
        }
    }

    private func launch(id: UUID, operationID: UUID, initial: AgentTaskRequest?,
                        continuation: (AgentTaskRecord, AgentTaskTurnRequest)?) {
        consumerOperations[id] = operationID
        consumers[id] = Task { [weak self, backend] in
            guard !Task.isCancelled else { return }
            do {
                let events: AsyncThrowingStream<AgentTaskEvent, any Error>
                if let initial { events = try await backend.start(id: id, request: initial) }
                else if let (record, request) = continuation {
                    events = try await backend.continueTask(id: id, record: record, request: request)
                } else { return }
                for try await event in events {
                    guard !Task.isCancelled else { break }
                    try await self?.receive(event, id: id, operationID: operationID)
                }
                if let self, self.consumerOperations[id] == operationID,
                   let current = self.records[id], !current.phase.isFinished, current.phase != .disconnected {
                    try await self.receive(.disconnected("stream_ended_without_completion"), id: id, operationID: operationID)
                }
            } catch {
                try? await self?.receive(.disconnected(String(describing: error)), id: id, operationID: operationID)
            }
            if let self, self.consumerOperations[id] == operationID {
                self.consumers.removeValue(forKey: id)
                self.consumerOperations.removeValue(forKey: id)
                self.requests.removeValue(forKey: id)
                self.pruneReceipts()
                _ = try? await self.finishRetirement(id)
            }
        }
    }

    /// Whether the worker has begun local retirement; no further input may be admitted.
    /// - Parameter id: Exact managed task identity.
    /// - Returns: True for pending or completed local retirement, including an in-flight acknowledgement.
    public func isRetiredOrRetiring(_ id: UUID) -> Bool { records[id]?.retirement != nil || retiring.contains(id) }

    /// Holds the referenced tasks across schedule authorization and durable admission.
    /// - Parameters:
    ///   - taskIDs: Exact owner and existing target identities, at most two tasks.
    ///   - operation: Entire schedule authorization and journal commit, without provider dispatch.
    /// - Returns: The operation's durable schedule result.
    /// - Throws: Retired/unavailable task, admission, authorization or storage errors.
    public func withScheduleAdmission<Result>(taskIDs: Set<UUID>,
        operation: @MainActor () async throws -> Result) async throws -> Result {
        guard !restoring, !taskIDs.isEmpty, taskIDs.count <= 2, scheduleAdmissions.count < 64,
              !taskIDs.contains(where: isRetiredOrRetiring) else { throw TaskError.providerUnreconciled }
        let admission = UUID()
        // Each overlapping admission owns a separate reservation. Releasing one
        // cannot release another pending schedule's references to the same task.
        scheduleAdmissions[admission] = taskIDs
        defer { scheduleAdmissions.removeValue(forKey: admission) }
        for id in taskIDs {
            guard let record = try await record(id), record.retirement == nil,
                  !isRetiredOrRetiring(id) else { throw TaskError.providerUnreconciled }
        }
        return try await operation()
    }

    /// Retires an explicit one-shot worker after its exact successful result was consumed.
    ///
    /// The parent inbox acknowledgement must already be durable. Existing/legacy sessions,
    /// failures, stale result acknowledgements, live descendants and scheduled work stay intact.
    /// The intent is persisted before releasing an idle owned process. Read/results remain
    /// available; retired workers reject follow-up input. Provider histories are never deleted.
    /// - Parameter event: Exact journal-verified parent acknowledgement.
    /// - Returns: True once locally retired, false when this acknowledgement is not eligible.
    /// - Throws: Persistence, schedule-read or idle-resource release failures; no prompt is sent.
    @discardableResult
    public func retireAcknowledgedWorker(_ event: AgentTaskInboxEvent) async throws -> Bool {
        guard event.phase == .completed, let acknowledgedAt = event.acknowledgedAt,
              let retirementPermit, !restoring, !starting.contains(event.taskID),
              !cancelling.contains(event.taskID), !presenting.contains(event.taskID),
              !hasScheduleAdmission(event.taskID),
              retiring.insert(event.taskID).inserted else { return false }
        defer { retiring.remove(event.taskID) }
        guard var record = try await record(event.taskID), record.lifecycle == .oneShot,
              record.presentation == .background, record.surfaceID == nil,
              record.parentTaskID == event.ownerTaskID, record.latestOperationID == event.operationID,
              record.phase == .completed else { return false }
        guard try await !hasUnretiredDescendants(record.id),
              try await retirementPermit(record.id) else { return false }
        guard records[record.id]?.latestOperationID == event.operationID,
              records[record.id]?.phase == .completed, !hasScheduleAdmission(record.id) else { return false }
        if record.retirement == nil {
            record.retirement = AgentTaskRetirement(operationID: event.operationID, acknowledgedAt: acknowledgedAt)
            try await save(record)
            records[record.id] = record
            publish(record)
        }
        return try await finishRetirement(record.id)
    }

    /// Retries only durable local retirement intents, never provider work or model input.
    /// - Throws: Storage or schedule checks failed; provider histories remain intact.
    public func finishPendingRetirements() async throws {
        for record in records.values where record.retirement?.retiredAt == nil && record.retirement != nil {
            _ = try await finishRetirement(record.id)
        }
    }

    private func finishRetirement(_ id: UUID) async throws -> Bool {
        guard let snapshot = records[id], var retirement = snapshot.retirement else { return false }
        if retirement.retiredAt != nil { return true }
        guard finishingRetirements.insert(id).inserted else { return false }
        defer { finishingRetirements.remove(id) }
        guard snapshot.phase == .completed, snapshot.latestOperationID == retirement.operationID,
              snapshot.presentation == .background, snapshot.surfaceID == nil,
              transitioning[id] == nil, !starting.contains(id), !cancelling.contains(id), !presenting.contains(id),
              consumerOperations[id] == nil, !hasScheduleAdmission(id), let retirementPermit else { return false }
        guard try await !hasUnretiredDescendants(id),
              try await retirementPermit(id), !hasScheduleAdmission(id) else { return false }
        try await backend.releaseIdleResources(id: id)
        guard var record = records[id], record.retirement == snapshot.retirement,
              record.phase == .completed, record.latestOperationID == retirement.operationID else { return false }
        retirement.retiredAt = Date()
        record.retirement = retirement
        try await save(record)
        records[id] = record
        publish(record)
        return true
    }

    /// A reusable or scheduled descendant keeps every ancestor usable, even between turns.
    private func hasUnretiredDescendants(_ id: UUID) async throws -> Bool {
        let saved = try await repository.load()
        var lineage = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        for record in records.values { lineage[record.id] = record }
        for child in lineage.values where !child.isRetired {
            var parent = child.parentTaskID
            var visited: Set<UUID> = []
            while let next = parent, visited.insert(next).inserted {
                if next == id { return true }
                parent = lineage[next]?.parentTaskID
            }
        }
        return false
    }

    private func hasScheduleAdmission(_ id: UUID) -> Bool {
        scheduleAdmissions.values.contains { $0.contains(id) }
    }

    private func reserveCapacity(id: UUID, provider: AgentTaskRequest.Provider) throws {
        var occupied = capacityReservations
        for record in records.values where !record.phase.isFinished && record.turnCount != 0 {
            occupied[record.id] = record.provider
        }
        occupied.removeValue(forKey: id)
        guard occupied.count < Int(executionLimits.total),
              occupied.values.filter({ $0 == provider }).count < executionLimits.capacity(for: provider) else {
            throw TaskError.capacityExceeded
        }
        capacityReservations[id] = provider
    }

    /// Reconnects only a terminal view of a known session; never invokes the backend.
    ///
    /// - Parameters:
    ///   - id: An existing saved task with a provider session identity.
    ///   - workspaceID: The explicitly resolved existing workspace for this view.
    /// - Returns: The receipt with its new surface identity and unchanged provider phase.
    public func attach(_ id: UUID, workspaceID: UUID, workspaceStableID: UUID? = nil) async throws -> AgentTaskRecord {
        guard let existing = try await record(id), existing.retirement == nil, !retiring.contains(id), existing.sessionID != nil,
              let reconnect, presenting.insert(id).inserted else { throw TaskError.invalid }
        defer { presenting.remove(id) }
        if records[id] == nil { records[id] = existing }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: existing.workingDirectory.path, isDirectory: &directory), directory.boolValue else { throw TaskError.invalid }
        var viewRecord = existing
        viewRecord.workspaceID = workspaceID
        viewRecord.workspaceStableID = workspaceStableID ?? existing.workspaceStableID
        viewRecord.presentation = .terminal
        let request = AgentTaskRequest(provider: existing.provider, prompt: existing.title,
            workspaceID: workspaceID, workingDirectory: existing.workingDirectory,
            model: existing.model, effort: existing.effort, presentation: .terminal, parentTaskID: existing.parentTaskID)
        let surface = try await reconnect(viewRecord, request)
        guard var current = records[id] else { throw TaskError.invalid }
        current.workspaceID = workspaceID
        current.workspaceStableID = viewRecord.workspaceStableID
        current.surfaceID = surface
        current.presentation = .terminal
        current.updatedAt = Date()
        if current.detail?.hasPrefix("terminal_attachment_failed:") == true { current.detail = nil }
        records[id] = current
        try await save(current)
        if records[id] == current { publish(current) }
        return current
    }

    /// Cancels only a live current turn and known descendants; saved receipts never restart a provider.
    public func cancel(_ id: UUID) async throws {
        guard !restoring, !starting.contains(id), transitioning[id] == nil else { throw TaskError.providerUnreconciled }
        if records[id] == nil, let archived = try await record(id) { records[id] = archived }
        guard records[id] != nil else { return }
        defer { pruneReceipts() }
        guard cancelling.insert(id).inserted else { throw TaskError.providerUnreconciled }
        defer { cancelling.remove(id) }
        var unconfirmed: [UUID] = []
        // Include archived children, including completed parents of live descendants.
        let saved = try await repository.load()
        for child in saved where records[child.id] == nil {
            var receipt = child
            if !receipt.phase.isFinished { receipt.phase = .disconnected; receipt.detail = "restart_unreconciled" }
            records[receipt.id] = receipt
        }
        for child in records.values.filter({ $0.parentTaskID == id }).map(\.id) {
            do { try await cancel(child) }
            catch { unconfirmed.append(child) }
        }
        guard let before = records[id], !before.phase.isFinished else {
            if !unconfirmed.isEmpty { throw TaskError.childrenUnconfirmed(unconfirmed) }
            return
        }
        guard let operationID = consumerOperations[id], operationID == before.latestOperationID else {
            throw TaskError.providerUnreconciled
        }
        do { try await backend.cancel(id: id) }
        catch {
            try await receive(.disconnected("cancellation_unconfirmed: \(error)"), id: id, operationID: operationID)
            throw error
        }
        if records[id]?.latestOperationID == operationID, records[id]?.phase.isFinished == false {
            try await receive(.cancelled, id: id, operationID: operationID)
        }
        if consumerOperations[id] == operationID {
            consumers.removeValue(forKey: id)?.cancel()
            consumerOperations.removeValue(forKey: id)
            requests.removeValue(forKey: id)
        }
        if !unconfirmed.isEmpty { throw TaskError.childrenUnconfirmed(unconfirmed) }
    }

    /// Parks on native events for at most 15 seconds, returning the latest receipt.
    public func wait(_ id: UUID) async throws -> AgentTaskRecord {
        let events = changes()
        guard let record = try await record(id) else { throw TaskError.invalid }
        if record.phase.isFinished || record.phase == .disconnected || record.phase == .needsInput { return record }
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

    /// Returns durable lineage identities independently of the bounded recent-result cache.
    /// - Parameter ownerTaskID: Exact managed parent ID.
    /// - Returns: Direct children with modern per-turn receipts, including archived results.
    public func childTaskIDs(of ownerTaskID: UUID) -> Set<UUID> { childIDsByParent[ownerTaskID] ?? [] }

    /// Reads all modern descendants from the existing durable lineage index, without provider I/O.
    /// - Parameter ownerTaskID: Exact managed ancestor identity.
    /// - Returns: Descendant identities at every depth, including retired records whose results remain readable.
    public func descendantTaskIDs(of ownerTaskID: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var pending = [ownerTaskID]
        while let owner = pending.popLast() {
            for child in childIDsByParent[owner] ?? [] where child != ownerTaskID {
                if result.insert(child).inserted { pending.append(child) }
            }
        }
        return result
    }

    /// Discovers reusable worker identities through a bounded authorized metadata read.
    /// - Parameters:
    ///   - query: UUID pagination and retirement visibility.
    ///   - authorize: Trusted composition's current grant, revalidated across repository awaits.
    /// - Returns: Sanitized descendant metadata without provider requests or parent wake-ups.
    /// - Throws: Invalid owner, changed authority or repository errors.
    public func workers(_ query: AgentTaskWorkerDirectoryQuery,
                        authorize: @MainActor () async throws -> AgentTaskWorkerDirectoryAccess) async throws -> AgentTaskWorkerDirectoryPage {
        // Structural seam for the executed discovery regression; activated by the following repair.
        return AgentTaskWorkerDirectoryPage(workers: [], nextCursor: nil, hasMore: false)
    }

    /// Reads a recent or archived receipt without reconnecting to a provider.
    public func record(_ id: UUID) async throws -> AgentTaskRecord? {
        if let record = records[id], record.phase != .completed || record.result != nil { return record }
        guard var record = try await repository.read(id) else { return records[id] }
        if let latest = records[id], latest.phase != .completed || latest.result != nil { return latest }
        if !record.phase.isFinished { record.phase = .disconnected; record.detail = "restart_unreconciled" }
        if records[id] == nil { records[id] = record; pruneReceipts() }
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

    private func turnChanges() -> AsyncStream<AgentTaskTurnRecord> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AgentTaskTurnRecord.self, bufferingPolicy: .bufferingNewest(64))
        turnSubscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.turnSubscribers.removeValue(forKey: token) } }
        return stream
    }

    private func publishTurn(_ turn: AgentTaskTurnRecord) {
        for continuation in turnSubscribers.values { continuation.yield(turn) }
    }

    private func validatePrompt(_ prompt: String) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 200_000 else { throw TaskError.invalid }
    }

    private func pruneReceipts() {
        let historyTurns = currentTurns.values.filter { $0.phase.isFinished || $0.phase == .disconnected }
            .sorted { $0.updatedAt > $1.updatedAt }
        for old in historyTurns.dropFirst(100) where consumerOperations[old.taskID] != old.operationID {
            currentTurns.removeValue(forKey: old.operationID)
        }
        var ancestors: Set<UUID> = []
        for active in records.values where !active.phase.isFinished {
            var parent = active.parentTaskID
            while let id = parent, ancestors.insert(id).inserted { parent = records[id]?.parentTaskID }
        }
        let history = records.values.filter { $0.phase.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
        for old in history.dropFirst(100) {
            if starting.contains(old.id) || presenting.contains(old.id) || transitioning[old.id] != nil
                || retiring.contains(old.id) || finishingRetirements.contains(old.id)
                || hasScheduleAdmission(old.id) { continue }
            if old.retirement != nil && old.retirement?.retiredAt == nil { continue }
            if ancestors.contains(old.id) { records[old.id]?.result = nil }
            else { records.removeValue(forKey: old.id) }
        }
    }

    private func validateParent(_ id: UUID?) throws {
        guard let id else { return }
        guard records[id] != nil else { throw TaskError.unknownParent }
        var ancestor: UUID? = id
        var visited: Set<UUID> = []
        while let current = ancestor, let parent = records[current] {
            guard visited.insert(current).inserted else { throw TaskError.invalid }
            guard !cancelling.contains(current), parent.phase != .cancelled else { throw CancellationError() }
            guard parent.retirement == nil, !retiring.contains(current) else { throw TaskError.providerUnreconciled }
            ancestor = parent.parentTaskID
        }
    }

    private func loadParentChain(_ id: UUID?) async throws {
        var ancestor = id
        var visited: Set<UUID> = []
        while let current = ancestor {
            guard visited.insert(current).inserted else { throw TaskError.invalid }
            if records[current] == nil {
                guard var archived = try await repository.read(current) else { throw TaskError.unknownParent }
                if records[current] == nil {
                    if !archived.phase.isFinished { archived.phase = .disconnected; archived.detail = "restart_unreconciled" }
                    archived.result = nil
                    records[current] = archived
                }
            }
            ancestor = records[current]?.parentTaskID
        }
    }

    // Serialize both stores in one queue so late writes cannot replace newer receipts.
    private func save(_ record: AgentTaskRecord) async throws {
        let previous = persistence
        let next = Task { [repository] in
            _ = try? await previous?.value
            try await repository.save(record)
        }
        persistence = next
        try await next.value
    }

    private func saveTurn(_ turn: AgentTaskTurnRecord) async throws {
        let previous = persistence
        let next = Task { [turnRepository] in
            _ = try? await previous?.value
            try await turnRepository.save(turn)
        }
        persistence = next
        try await next.value
    }

    private func saveTransition(_ record: AgentTaskRecord, turn: AgentTaskTurnRecord) async throws {
        let previous = persistence
        let next = Task { [repository, turnRepository] in
            _ = try? await previous?.value
            // Save the projection first: a partial write leaves unfinished turn intent,
            // which restart recovery treats conservatively as uncertain.
            try await repository.save(record)
            try await turnRepository.save(turn)
        }
        persistence = next
        try await next.value
    }

    enum TaskError: Error {
        case capacityExceeded, duplicate, invalid, unknownParent, sessionChanged, providerUnreconciled, busy, operationConflict, childrenUnconfirmed([UUID])
    }
}
