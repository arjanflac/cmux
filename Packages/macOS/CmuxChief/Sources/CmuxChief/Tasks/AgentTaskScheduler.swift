import Foundation

/// App-lifetime scheduling actor with injected authority and delivery, driven by one app-owned timer.
///
/// Call ``restore(now:)`` at launch and ``reconcile(now:)`` after sleep or clock changes. A timer calls
/// ``runDue(now:)`` and then rearms from ``nextDueDate()``. This actor never creates a worker or timer.
/// Authorization must revalidate the durable owner grant, exact cmux-owned target, workspace,
/// permissions and provider support. Dispatch must return positive provider acceptance, not task admission.
///
/// ```swift
/// let scheduler = try AgentTaskScheduler(journal: journal, authorize: { schedule in
///     try await scopes.preflight(schedule)
/// }, dispatch: { target, prompt, operationID in
///     try await delivery.submit(target, prompt: prompt, operationID: operationID)
/// })
/// try await scheduler.restore()
/// try await scheduler.runDue()
/// ```
public actor AgentTaskScheduler {
    private let journal: AgentTaskJournal
    private let authorize: @Sendable (AgentTaskSchedule) async throws -> Void
    private let preflight: @Sendable (AgentTaskSchedule) async throws -> Void
    private let dispatch: @Sendable (AgentTaskScheduleTarget, String, UUID) async throws -> AgentTaskScheduleAcceptance
    private let now: @Sendable () -> Date
    private let latenessTolerance: TimeInterval
    private var restored = false
    private var running = false

    /// Creates a scheduler whose external effects are supplied by the composition root.
    ///
    /// - Parameters:
    ///   - journal: App-owned durable journal.
    ///   - latenessTolerance: Maximum on-time lateness in seconds, default 30; larger delays use the misfire policy.
    ///   - now: Injected UTC clock; no timer or wall-clock sleep is created here.
    ///   - authorize: Side-effect-free preflight, invoked at admission and again immediately before each claim.
    ///   - preflight: Due-time readiness check; an agent may schedule its future work while it is currently busy.
    ///   - dispatch: Provider submission called once after a durable marker; throws mean acceptance unknown.
    /// - Throws: Invalid negative or nonfinite tolerance.
    public init(journal: AgentTaskJournal, latenessTolerance: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = { Date() },
                authorize: @escaping @Sendable (AgentTaskSchedule) async throws -> Void,
                preflight: @escaping @Sendable (AgentTaskSchedule) async throws -> Void = { _ in },
                dispatch: @escaping @Sendable (AgentTaskScheduleTarget, String, UUID) async throws -> AgentTaskScheduleAcceptance) throws {
        guard latenessTolerance.isFinite, latenessTolerance >= 0 else { throw AgentTaskJournalError.invalidRequest }
        self.journal = journal
        self.latenessTolerance = latenessTolerance
        self.now = now
        self.authorize = authorize
        self.preflight = preflight
        self.dispatch = dispatch
    }

    /// Restores the journal without provider I/O; uncertain or accepted unfinished work remains reserved.
    ///
    /// - Parameter now: Explicit UTC instant, or the injected clock when omitted.
    /// - Throws: Storage errors or reconciliation during an active due pass.
    public func restore(now date: Date? = nil) async throws {
        guard !running else { throw AgentTaskJournalError.invalidTransition }
        try await journal.reconcile(at: try instant(date), tolerance: latenessTolerance)
        restored = true
    }

    /// Rescans after sleep or a clock change, with the same conservative semantics as launch recovery.
    ///
    /// - Parameter now: Explicit UTC instant, or the injected clock.
    /// - Throws: Persistence errors or reconciliation during a due pass; retry reconciliation after it finishes.
    public func reconcile(now date: Date? = nil) async throws { try await restore(now: date) }

    /// Admits idempotent finite scheduling intent after root authorization.
    ///
    /// - Parameters:
    ///   - request: Validated immutable payload.
    ///   - callerID: Stable caller operation key; reusing it with another payload is a conflict.
    /// - Returns: Original durable schedule on duplicate creation, otherwise the new schedule.
    /// - Throws: Authorization, validation, conflict, capacity or persistence errors.
    public func create(_ request: AgentTaskScheduleRequest, callerID: UUID) async throws -> AgentTaskSchedule {
        try request.validate()
        let candidate = AgentTaskSchedule(callerID: callerID, request: request, now: try instant(nil))
        try await authorize(candidate)
        return try await journal.create(candidate)
    }

    /// Lists all retained schedules for one authorized owner.
    ///
    /// - Parameter ownerTaskID: Owner scoped by the caller's authorization layer.
    /// - Returns: Creation-ordered durable snapshots.
    /// - Throws: Persistence errors.
    public func list(ownerTaskID: UUID) async throws -> [AgentTaskSchedule] {
        try await journal.schedules(ownerTaskID: ownerTaskID)
    }

    /// Reads an owner-scoped schedule without provider work.
    ///
    /// - Parameters:
    ///   - id: Schedule ID.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: Snapshot, or nil when missing or differently owned.
    /// - Throws: Persistence errors.
    public func read(_ id: UUID, ownerTaskID: UUID) async throws -> AgentTaskSchedule? {
        try await journal.schedule(id, ownerTaskID: ownerTaskID)
    }

    /// Stops future claims; work already marked dispatching remains reserved.
    ///
    /// - Parameters:
    ///   - id: Schedule ID.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: Updated snapshot.
    /// - Throws: Ownership, transition or persistence errors.
    public func pause(_ id: UUID, ownerTaskID: UUID) async throws -> AgentTaskSchedule {
        try await journal.setState(.paused, id: id, ownerTaskID: ownerTaskID, at: try instant(nil))
    }

    /// Explicitly permits one held overdue wake now, with fresh authority required at claim time.
    ///
    /// - Parameters:
    ///   - id: Schedule ID.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: Active or exhausted snapshot; unresolved provider work cannot resume.
    /// - Throws: Ownership, unresolved reservation, terminal transition or persistence errors.
    public func resume(_ id: UUID, ownerTaskID: UUID) async throws -> AgentTaskSchedule {
        try await journal.setState(.active, id: id, ownerTaskID: ownerTaskID, at: try instant(nil))
    }

    /// Cancels future unsent work without claiming that provider work was interrupted.
    ///
    /// - Parameters:
    ///   - id: Schedule ID.
    ///   - ownerTaskID: Authorized owner.
    /// - Returns: Cancelled schedule; existing dispatch and acceptance receipts remain intact.
    /// - Throws: Ownership or persistence errors.
    public func cancel(_ id: UUID, ownerTaskID: UUID) async throws -> AgentTaskSchedule {
        try await journal.setState(.cancelled, id: id, ownerTaskID: ownerTaskID, at: try instant(nil))
    }

    /// Finds the next eligible timer instant, excluding reserved targets and full outstanding capacity.
    ///
    /// - Returns: Next UTC due time, or nil when a control/evidence change must wake the scheduler.
    /// - Throws: Persistence errors.
    public func nextDueDate() async throws -> Date? { try await journal.nextDueDate() }

    /// Runs one bounded due pass; duplicate concurrent wakes do not overlap or replay submissions.
    ///
    /// Throws from dispatch conservatively become durable acceptance uncertainty. If recording that
    /// uncertainty fails, the already committed dispatch marker still prevents automatic replay.
    /// The adapter owns any provider deadline; a timeout must throw and must never initiate a retry.
    ///
    /// - Parameter now: Fixed UTC simulation instant, or the injected clock, read again after authorization.
    /// - Throws: Persistence or clock errors. No provider call occurs before its claim transaction commits.
    public func runDue(now date: Date? = nil) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        let explicitDate = date
        let date = try instant(explicitDate)
        if !restored {
            try await journal.reconcile(at: date, tolerance: latenessTolerance)
            restored = true
        }
        let candidates = try await journal.candidates(at: date, tolerance: latenessTolerance)
        for schedule in candidates {
            do {
                try await authorize(schedule)
                try await preflight(schedule)
            }
            catch {
                try await journal.block(schedule, at: date)
                continue
            }
            try Task.checkCancellation()
            let claimDate = try instant(explicitDate)
            guard let occurrence = try await journal.claim(schedule, at: claimDate, tolerance: latenessTolerance) else { continue }
            do {
                let receipt = try await dispatch(occurrence.target, occurrence.prompt, occurrence.id)
                // A receipt for a different occurrence cannot establish this submission's acceptance.
                guard receipt.operationID == occurrence.id else { throw AgentTaskJournalError.conflict }
                _ = try await journal.confirmAcceptance(receipt, ownerTaskID: schedule.request.ownerTaskID)
            } catch {
                try await journal.markUnknown(occurrence.id, ownerTaskID: schedule.request.ownerTaskID, at: claimDate)
            }
        }
    }

    private func instant(_ explicit: Date?) throws -> Date {
        let date = explicit ?? now()
        guard date.timeIntervalSince1970.isFinite else { throw AgentTaskJournalError.invalidRequest }
        return date
    }
}
