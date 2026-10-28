import Foundation

/// Immutable scheduling intent, with UTC instants and a finite dispatch budget.
public struct AgentTaskScheduleRequest: Codable, Equatable, Sendable {
    /// Fixed intervals reanchor at each dispatch or skipped wake; missed intervals never accumulate sends.
    public enum Recurrence: Codable, Equatable, Sendable {
        /// A single occurrence.
        case once
        /// A finite series separated by at least 60 seconds, bounded by ``maxRuns``.
        case interval(seconds: TimeInterval)
    }
    /// Behavior when an occurrence is later than the scheduler's configured tolerance.
    public enum MisfirePolicy: String, Codable, Sendable {
        /// Hold until an explicit resume, the conservative default.
        case hold
        /// Write one skipped receipt and advance beyond the current instant.
        case skip
        /// Dispatch one catch-up occurrence and advance beyond the current instant.
        case coalesceOne
    }
    /// App-owned parent whose durable grant the authorizer validates.
    public let ownerTaskID: UUID
    /// Exact delivery destination; there is no arbitrary provider-session target.
    public let target: AgentTaskScheduleTarget
    /// Private prompt, at most 200,000 UTF-8 bytes.
    public let prompt: String
    /// First nominal UTC instant; ``timeZoneID`` is descriptive, not calendar recurrence arithmetic.
    public let dueAt: Date
    /// Valid Foundation time zone identifier retained for presentation.
    public let timeZoneID: String
    /// Once or a fixed interval, never an unbounded calendar rule.
    public let recurrence: Recurrence
    /// Explicit late-wake policy, defaulting to hold.
    public let misfire: MisfirePolicy
    /// Optional exclusive UTC expiry, after which no new dispatch is allowed.
    public let expiresAt: Date?
    /// Total claimed/skipped wakes, 1–100 for an existing worker or at most eight for fresh workers; once requires one.
    public let maxRuns: Int

    /// Creates intent; validation occurs when the scheduler admits it.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Managed owner with a persistent scheduling grant.
    ///   - target: Explicit known managed task or fully specified new-task request.
    ///   - prompt: Private input; a new-task request must carry the same prompt.
    ///   - dueAt: First UTC instant.
    ///   - timeZoneID: Presentation zone, defaulting to UTC.
    ///   - recurrence: Once by default; intervals must be at least 60 seconds.
    ///   - misfire: Hold by default to avoid unexpected paid work after sleep.
    ///   - expiresAt: Optional exclusive expiry after the first due instant.
    ///   - maxRuns: Finite wake budget, defaulting to one.
    public init(ownerTaskID: UUID, target: AgentTaskScheduleTarget, prompt: String, dueAt: Date,
                timeZoneID: String = "UTC", recurrence: Recurrence = .once,
                misfire: MisfirePolicy = .hold, expiresAt: Date? = nil, maxRuns: Int = 1) {
        self.ownerTaskID = ownerTaskID
        self.target = target
        self.prompt = prompt
        self.dueAt = dueAt
        self.timeZoneID = timeZoneID
        self.recurrence = recurrence
        self.misfire = misfire
        self.expiresAt = expiresAt
        self.maxRuns = maxRuns
    }

    func validate() throws {
        guard !prompt.isEmpty, prompt.utf8.count <= 200_000, dueAt.timeIntervalSince1970.isFinite,
              TimeZone(identifier: timeZoneID) != nil, (1...100).contains(maxRuns) else {
            throw AgentTaskJournalError.invalidRequest
        }
        if let expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > dueAt else {
                throw AgentTaskJournalError.invalidRequest
            }
        }
        switch recurrence {
        case .once:
            guard maxRuns == 1 else { throw AgentTaskJournalError.invalidRequest }
        case .interval(let seconds):
            guard seconds.isFinite, seconds >= 60,
                  dueAt.addingTimeInterval(seconds * Double(maxRuns)).timeIntervalSince1970.isFinite else {
                throw AgentTaskJournalError.invalidRequest
            }
        }
        if case .newTask(let task) = target {
            guard maxRuns <= 8, task.prompt == prompt, task.parentTaskID == ownerTaskID,
                  task.workspaceStableID != nil, task.workingDirectory.isFileURL,
                  task.workingDirectory.path.hasPrefix("/") else {
                throw AgentTaskJournalError.invalidRequest
            }
        }
    }
}
