import CryptoKit
import Foundation

/// App-owned SQLite source of truth for finite schedules, submission receipts and a passive inbox.
///
/// Construct one journal per app runtime in a dedicated private directory with trusted ancestors.
/// The connection and statements stay inside this actor's non-Sendable database owner; WAL and
/// FULL synchronous transactions commit before any provider call. Closing releases the connection;
/// ordinary deallocation also closes it without an actor-isolated deinitializer.
///
/// ```swift
/// let journal = try AgentTaskJournal(databaseURL: privateDirectory.appendingPathComponent("tasks.sqlite"))
/// ```
public actor AgentTaskJournal {
    private var database: AgentTaskJournalDatabase?
    private let scheduleCapacity: Int
    let inboxCapacity: Int
    private let outstandingCapacity: Int
    let now: @Sendable () -> Date

    /// Opens or creates a durable journal; never selects a global production path.
    ///
    /// - Parameters:
    ///   - databaseURL: File in an app-owned dedicated directory; parent mode becomes 0700, file 0600.
    ///   - scheduleCapacity: Total retained schedules, default 256; finished records keep deduplication keys.
    ///   - inboxCapacity: Total retained inbox events, default 10,000; unacknowledged events are never pruned.
    ///   - outstandingCapacity: Concurrent outstanding occurrences, default one; unknown acceptance reserves capacity.
    ///   - maximumDatabasePages: SQLite page quota, default 65,536, also useful for deterministic full-disk tests.
    ///   - now: Injected UTC clock for inbox receipts and evidence updates.
    /// - Throws: ``AgentTaskJournalError`` or filesystem errors; failure admits no provider work.
    public init(databaseURL: URL, scheduleCapacity: Int = 256, inboxCapacity: Int = 10_000,
                outstandingCapacity: Int = 1, maximumDatabasePages: Int = 65_536,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard (1...1_024).contains(scheduleCapacity), (1...100_000).contains(inboxCapacity),
              (1...100).contains(outstandingCapacity) else { throw AgentTaskJournalError.invalidRequest }
        self.scheduleCapacity = scheduleCapacity
        self.inboxCapacity = inboxCapacity
        self.outstandingCapacity = outstandingCapacity
        self.now = now
        database = try AgentTaskJournalDatabase(url: databaseURL, maximumPages: maximumDatabasePages)
    }

    /// Releases the connection; subsequent operations fail closed.
    public func close() { database = nil }

    /// Lists an owner's schedules, including terminal records that preserve idempotency.
    ///
    /// - Parameter ownerTaskID: Owner already authorized by the app's scope layer.
    /// - Returns: Stable creation order, with ID as a tie breaker.
    /// - Throws: Storage or decoding errors.
    public func schedules(ownerTaskID: UUID) throws -> [AgentTaskSchedule] {
        try allSchedules().filter { $0.request.ownerTaskID == ownerTaskID }.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    /// Reads an owner-scoped schedule.
    ///
    /// - Parameters:
    ///   - id: Schedule ID.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: The durable snapshot, or nil for a missing or differently owned record.
    /// - Throws: Storage or decoding errors.
    public func schedule(_ id: UUID, ownerTaskID: UUID) throws -> AgentTaskSchedule? {
        try allSchedules().first { $0.id == id && $0.request.ownerTaskID == ownerTaskID }
    }

    /// Replays dispatch receipts for a schedule without contacting a provider.
    ///
    /// - Parameters:
    ///   - scheduleID: Schedule to inspect.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: Receipts in ordinal order, including skipped and uncertain occurrences.
    /// - Throws: Not found, storage or decoding errors.
    public func occurrences(scheduleID: UUID, ownerTaskID: UUID) throws -> [AgentTaskScheduleOccurrence] {
        guard try schedule(scheduleID, ownerTaskID: ownerTaskID) != nil else { throw AgentTaskJournalError.notFound }
        return try db().rows("SELECT payload FROM task_occurrences WHERE schedule = ? ORDER BY ordinal", [scheduleID.uuidString])
            .map { try decode(AgentTaskScheduleOccurrence.self, $0[0]) }
    }

    /// Resolves an exact provider operation to durable scheduling ownership for trusted app recovery.
    /// This metadata lookup grants no model or socket authority and performs no provider work.
    /// - Parameter operationID: Exact operation from a durable provider receipt.
    /// - Returns: Owning task and occurrence, even when the owner left the recent task cache.
    /// - Throws: Storage or corrupt-record errors.
    public func scheduledReceipt(_ operationID: UUID) throws -> (ownerTaskID: UUID, occurrence: AgentTaskScheduleOccurrence)? {
        guard let row = try db().rows("SELECT s.owner, o.payload FROM task_occurrences o JOIN task_schedules s ON s.id = o.schedule WHERE o.id = ?",
                                      [operationID.uuidString]).first else { return nil }
        guard let owner = UUID(uuidString: row[0]) else { throw AgentTaskJournalError.invalidRequest }
        return (owner, try decode(AgentTaskScheduleOccurrence.self, row[1]))
    }

    /// Persists positive acceptance independently of completion, including late evidence after uncertainty.
    ///
    /// - Parameters:
    ///   - acceptance: Exact provider evidence; its operation ID identifies the occurrence.
    ///   - ownerTaskID: Authorized schedule owner.
    /// - Returns: Updated receipt; identical duplicate evidence is harmless.
    /// - Throws: Conflicting evidence, invalid receipt, ownership or storage errors.
    public func confirmAcceptance(_ acceptance: AgentTaskScheduleAcceptance, ownerTaskID: UUID) throws -> AgentTaskScheduleOccurrence {
        try db().transaction {
            var occurrence = try ownedOccurrence(acceptance.operationID, ownerTaskID: ownerTaskID)
            guard !acceptance.providerReference.isEmpty, acceptance.providerReference.utf8.count <= 4_096 else {
                throw AgentTaskJournalError.invalidRequest
            }
            if case .existingTask(let id) = occurrence.target, id != acceptance.taskID {
                throw AgentTaskJournalError.conflict
            }
            if let previous = occurrence.acceptance {
                guard previous == acceptance else { throw AgentTaskJournalError.conflict }
                return occurrence
            }
            guard occurrence.state == .dispatching || occurrence.state == .acceptanceUnknown else {
                throw AgentTaskJournalError.invalidTransition
            }
            occurrence.acceptance = acceptance
            occurrence.state = .accepted
            occurrence.updatedAt = now()
            try save(occurrence)
            return occurrence
        }
    }

    /// Records terminal provider evidence and releases the outstanding reservation.
    ///
    /// - Parameters:
    ///   - operationID: Occurrence operation ID, never a task's mutable latest-turn ID.
    ///   - ownerTaskID: Authorized owner.
    ///   - phase: A confirmed completed, failed or cancelled provider phase.
    /// - Returns: Updated receipt. A cancelled schedule alone is never interruption evidence.
    /// - Throws: Missing acceptance, nonterminal phase, conflicting evidence or persistence errors.
    public func completeOccurrence(operationID: UUID, ownerTaskID: UUID, phase: AgentTaskRecord.Phase) throws -> AgentTaskScheduleOccurrence {
        try db().transaction {
            var occurrence = try ownedOccurrence(operationID, ownerTaskID: ownerTaskID)
            guard phase.isFinished, occurrence.acceptance != nil else { throw AgentTaskJournalError.invalidTransition }
            if let previous = occurrence.completion {
                guard previous == phase else { throw AgentTaskJournalError.conflict }
                return occurrence
            }
            occurrence.completion = phase
            occurrence.state = .completed
            occurrence.updatedAt = now()
            try save(occurrence)
            return occurrence
        }
    }

    func create(_ candidate: AgentTaskSchedule) throws -> AgentTaskSchedule {
        try candidate.request.validate()
        let hash = try payloadHash(candidate.request)
        return try db().transaction {
            if let row = try db().rows("SELECT payload_hash, payload FROM task_schedules WHERE owner = ? AND caller = ?",
                                       [candidate.request.ownerTaskID.uuidString, candidate.callerID.uuidString]).first {
                guard row[0] == hash else { throw AgentTaskJournalError.conflict }
                return try decode(AgentTaskSchedule.self, row[1])
            }
            guard try allSchedules().count < scheduleCapacity else { throw AgentTaskJournalError.capacity }
            try db().execute("INSERT INTO task_schedules(id, owner, caller, payload_hash, payload) VALUES (?, ?, ?, ?, ?)",
                             [candidate.id.uuidString, candidate.request.ownerTaskID.uuidString,
                              candidate.callerID.uuidString, hash, try encode(candidate)])
            return candidate
        }
    }

    func setState(_ state: AgentTaskSchedule.State, id: UUID, ownerTaskID: UUID, at date: Date) throws -> AgentTaskSchedule {
        try db().transaction {
            guard var schedule = try schedule(id, ownerTaskID: ownerTaskID) else { throw AgentTaskJournalError.notFound }
            if state == .cancelled {
                schedule.state = .cancelled
                schedule.nextDueAt = nil
            } else {
                guard schedule.state != .cancelled, schedule.state != .exhausted else { throw AgentTaskJournalError.invalidTransition }
                if state == .active {
                    if schedule.state == .active { return schedule }
                    guard try !hasReservation(schedule, occurrences: outstandingOccurrences()) else { throw AgentTaskJournalError.invalidTransition }
                    schedule.state = schedule.runsUsed >= schedule.request.maxRuns ? .exhausted : .active
                    if schedule.state == .active, let due = schedule.nextDueAt, due < date { schedule.nextDueAt = date }
                } else {
                    schedule.state = state
                }
            }
            schedule.reason = nil
            touch(&schedule, at: date)
            try save(schedule)
            return schedule
        }
    }

    /// Recovery is read-only with respect to providers; durable dispatch markers are never made retryable.
    func reconcile(at date: Date, tolerance: TimeInterval) throws {
        try db().transaction {
            for var occurrence in try outstandingOccurrences() {
                if occurrence.state == .dispatching {
                    occurrence.state = .acceptanceUnknown
                    occurrence.updatedAt = date
                    try save(occurrence)
                }
                guard var schedule = try allSchedules().first(where: { $0.id == occurrence.scheduleID }),
                      schedule.state != .cancelled else { continue }
                schedule.state = .held
                schedule.reason = occurrence.acceptance == nil ? "acceptance_unknown" : "completion_unknown"
                touch(&schedule, at: date)
                try save(schedule)
            }
            try applyMisfires(at: date, tolerance: tolerance)
        }
    }

    func candidates(at date: Date, tolerance: TimeInterval) throws -> [AgentTaskSchedule] {
        try db().transaction {
            try applyMisfires(at: date, tolerance: tolerance)
            return try allSchedules().filter { $0.state == .active && ($0.nextDueAt.map { $0 <= date } ?? false) }
                .sorted { ($0.nextDueAt ?? .distantFuture, $0.id.uuidString) < ($1.nextDueAt ?? .distantFuture, $1.id.uuidString) }
        }
    }

    func block(_ expected: AgentTaskSchedule, at date: Date) throws {
        try db().transaction {
            guard var schedule = try schedule(expected.id, ownerTaskID: expected.request.ownerTaskID), schedule == expected else { return }
            schedule.state = .blocked
            schedule.reason = "authorization_failed"
            touch(&schedule, at: date)
            try save(schedule)
        }
    }

    /// The single shared claim path rechecks the authorized snapshot, reservation and capacity atomically.
    func claim(_ expected: AgentTaskSchedule, at date: Date, tolerance: TimeInterval? = nil) throws -> AgentTaskScheduleOccurrence? {
        try db().transaction {
            if let tolerance { try applyMisfires(at: date, tolerance: tolerance) }
            guard var schedule = try schedule(expected.id, ownerTaskID: expected.request.ownerTaskID),
                  schedule == expected, schedule.state == .active, let due = schedule.nextDueAt, due <= date,
                  schedule.request.expiresAt.map({ date < $0 }) ?? true,
                  schedule.runsUsed < schedule.request.maxRuns else { return nil }
            let outstanding = try outstandingOccurrences()
            guard outstanding.count < outstandingCapacity, !hasReservation(schedule, occurrences: outstanding) else { return nil }
            let occurrence = AgentTaskScheduleOccurrence(schedule: schedule, state: .dispatching, now: date)
            try insert(occurrence)
            advance(&schedule, at: date)
            try save(schedule)
            return occurrence
        }
    }

    func markUnknown(_ id: UUID, ownerTaskID: UUID, at date: Date) throws {
        try db().transaction {
            var occurrence = try ownedOccurrence(id, ownerTaskID: ownerTaskID)
            // Late terminal/acceptance evidence wins over a delivery adapter's thrown response.
            guard occurrence.state == .dispatching else { return }
            occurrence.state = .acceptanceUnknown
            occurrence.updatedAt = date
            try save(occurrence)
            guard var schedule = try schedule(occurrence.scheduleID, ownerTaskID: ownerTaskID), schedule.state != .cancelled else { return }
            schedule.state = .held
            schedule.reason = "acceptance_unknown"
            touch(&schedule, at: date)
            try save(schedule)
        }
    }

    func nextDueDate() throws -> Date? {
        let outstanding = try outstandingOccurrences()
        guard outstanding.count < outstandingCapacity else { return nil }
        return try allSchedules().filter { $0.state == .active && !hasReservation($0, occurrences: outstanding) }
            .compactMap(\.nextDueAt).min()
    }

    private func applyMisfires(at date: Date, tolerance: TimeInterval) throws {
        for var schedule in try allSchedules() where schedule.state == .active {
            if let expiry = schedule.request.expiresAt, date >= expiry {
                schedule.state = .exhausted
                schedule.nextDueAt = nil
                schedule.reason = "expired"
            } else if let due = schedule.nextDueAt, date.timeIntervalSince(due) > tolerance {
                switch schedule.request.misfire {
                case .hold:
                    schedule.state = .held
                    schedule.reason = "misfire_hold"
                case .skip:
                    try insert(AgentTaskScheduleOccurrence(schedule: schedule, state: .skipped, now: date))
                    advance(&schedule, at: date)
                    schedule.reason = "misfire_skipped"
                case .coalesceOne:
                    continue
                }
            } else { continue }
            touch(&schedule, at: date)
            try save(schedule)
        }
    }

    private func advance(_ schedule: inout AgentTaskSchedule, at date: Date) {
        schedule.runsUsed += 1
        switch schedule.request.recurrence {
        case .once:
            schedule.state = .exhausted
            schedule.nextDueAt = nil
        case .interval(let seconds):
            schedule.state = schedule.runsUsed >= schedule.request.maxRuns ? .exhausted : .active
            schedule.nextDueAt = schedule.state == .active ? date.addingTimeInterval(seconds) : nil
        }
        touch(&schedule, at: date)
    }

    private func hasReservation(_ schedule: AgentTaskSchedule, occurrences: [AgentTaskScheduleOccurrence]) -> Bool {
        occurrences.contains { occurrence in
            guard occurrence.reservesTarget else { return false }
            if occurrence.scheduleID == schedule.id { return true }
            if case .existingTask(let taskID) = schedule.request.target {
                if case .existingTask(let reserved) = occurrence.target, reserved == taskID { return true }
                return occurrence.acceptance?.taskID == taskID
            }
            return false
        }
    }

    private func touch(_ schedule: inout AgentTaskSchedule, at date: Date) {
        schedule.revision += 1
        schedule.updatedAt = date
    }

    private func ownedOccurrence(_ id: UUID, ownerTaskID: UUID) throws -> AgentTaskScheduleOccurrence {
        guard let row = try db().rows("SELECT payload FROM task_occurrences WHERE id = ?", [id.uuidString]).first else {
            throw AgentTaskJournalError.notFound
        }
        let occurrence = try decode(AgentTaskScheduleOccurrence.self, row[0])
        guard try schedule(occurrence.scheduleID, ownerTaskID: ownerTaskID) != nil else { throw AgentTaskJournalError.notFound }
        return occurrence
    }

    private func allSchedules() throws -> [AgentTaskSchedule] {
        try db().rows("SELECT payload FROM task_schedules").map { try decode(AgentTaskSchedule.self, $0[0]) }
    }

    private func outstandingOccurrences() throws -> [AgentTaskScheduleOccurrence] {
        try db().rows("SELECT payload FROM task_occurrences WHERE state IN ('dispatching', 'acceptanceUnknown', 'accepted')")
            .map { try decode(AgentTaskScheduleOccurrence.self, $0[0]) }
    }

    private func save(_ schedule: AgentTaskSchedule) throws {
        try db().execute("UPDATE task_schedules SET payload = ? WHERE id = ?", [try encode(schedule), schedule.id.uuidString])
    }

    private func save(_ occurrence: AgentTaskScheduleOccurrence) throws {
        try db().execute("UPDATE task_occurrences SET state = ?, payload = ? WHERE id = ?",
                         [occurrence.state.rawValue, try encode(occurrence), occurrence.id.uuidString])
    }

    private func insert(_ occurrence: AgentTaskScheduleOccurrence) throws {
        try db().execute("INSERT INTO task_occurrences(id, schedule, ordinal, state, payload) VALUES (?, ?, ?, ?, ?)",
                         [occurrence.id.uuidString, occurrence.scheduleID.uuidString, String(occurrence.ordinal),
                          occurrence.state.rawValue, try encode(occurrence)])
    }

    // Internal helpers are shared only with this actor's inbox extension, never with a provider adapter.
    func db() throws -> AgentTaskJournalDatabase {
        guard let database else { throw AgentTaskJournalError.closed }
        return database
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func payloadHash(_ request: AgentTaskScheduleRequest) throws -> String {
        SHA256.hash(data: Data(try encode(request).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
