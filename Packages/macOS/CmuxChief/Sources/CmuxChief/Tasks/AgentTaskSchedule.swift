import Foundation

/// A durable schedule snapshot; changes are made through ``AgentTaskScheduler``.
public struct AgentTaskSchedule: Codable, Equatable, Sendable {
    /// Admission and recovery state; acceptance uncertainty requires evidence before resuming.
    public enum State: String, Codable, Sendable {
        /// Eligible for a due claim, subject to authorization and capacity.
        case active
        /// Explicitly paused by its owner.
        case paused
        /// Overdue or interrupted by restart; explicit resume is required.
        case held
        /// Authorization failed before provider work began; explicit resume rechecks authority.
        case blocked
        /// Future unsent work was cancelled; outstanding provider work is unaffected.
        case cancelled
        /// Finite budget or expiry has been reached.
        case exhausted
    }
    /// Journal-assigned stable identity.
    public let id: UUID
    /// Caller operation key, unique within the owner, for idempotent creation.
    public let callerID: UUID
    /// Immutable payload whose canonical hash detects caller-key conflicts.
    public let request: AgentTaskScheduleRequest
    /// Monotonic mutation generation used to reject authorization results from stale snapshots.
    public internal(set) var revision: Int
    /// Current admission state.
    public internal(set) var state: State
    /// Next nominal UTC instant, absent after exhaustion or cancellation.
    public internal(set) var nextDueAt: Date?
    /// Consumed dispatch or skipped-wake budget; uncertainty does not refund it.
    public internal(set) var runsUsed: Int
    /// Time the journal first admitted this schedule.
    public let createdAt: Date
    /// Latest journal mutation time.
    public internal(set) var updatedAt: Date
    /// Stable reason code, never a provider exception or prompt.
    public internal(set) var reason: String?

    init(id: UUID = UUID(), callerID: UUID, request: AgentTaskScheduleRequest, now: Date) {
        self.id = id
        self.callerID = callerID
        self.request = request
        revision = 1
        state = .active
        nextDueAt = request.dueAt
        runsUsed = 0
        createdAt = now
        updatedAt = now
    }
}
