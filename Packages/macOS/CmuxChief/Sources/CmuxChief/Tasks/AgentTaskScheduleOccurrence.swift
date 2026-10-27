import CryptoKit
import Foundation

/// An immutable dispatch payload with independently persisted acceptance and completion.
public struct AgentTaskScheduleOccurrence: Codable, Equatable, Sendable {
    /// Delivery state; every nonterminal state retains its target reservation across restart.
    public enum State: String, Codable, Sendable {
        /// Durable point of no automatic retry, committed before invoking dispatch.
        case dispatching
        /// Dispatch threw, returned invalid evidence, or the app restarted during submission.
        case acceptanceUnknown
        /// Provider acceptance is confirmed, but terminal completion is not.
        case accepted
        /// A terminal provider receipt has been recorded.
        case completed
        /// A late wake was skipped without contacting a provider.
        case skipped
    }
    /// Stable occurrence and coordinator operation identity, reused only for evidence correlation.
    public let id: UUID
    /// Owning schedule.
    public let scheduleID: UUID
    /// One-based budget slot, unique per schedule.
    public let ordinal: Int
    /// Original due instant, retained even for coalesced or skipped wakes.
    public let nominalDueAt: Date
    /// Exact snapshotted target.
    public let target: AgentTaskScheduleTarget
    /// Private snapshotted prompt.
    public let prompt: String
    /// Submission state.
    public internal(set) var state: State
    /// Durable acceptance evidence, never inferred from completion absence.
    public internal(set) var acceptance: AgentTaskScheduleAcceptance?
    /// Confirmed terminal phase, independent of acceptance.
    public internal(set) var completion: AgentTaskRecord.Phase?
    /// Claim or skip time.
    public let createdAt: Date
    /// Latest receipt time.
    public internal(set) var updatedAt: Date

    var reservesTarget: Bool { state == .dispatching || state == .acceptanceUnknown || state == .accepted }

    init(schedule: AgentTaskSchedule, state: State, now: Date) {
        // UUIDv8, deterministically namespaced by the durable schedule and one-based budget slot.
        var bytes = Array(SHA256.hash(data: Data("cmux.schedule.v1:\(schedule.id.uuidString):\(schedule.runsUsed + 1)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        scheduleID = schedule.id
        ordinal = schedule.runsUsed + 1
        nominalDueAt = schedule.nextDueAt ?? schedule.request.dueAt
        target = schedule.request.target
        prompt = schedule.request.prompt
        self.state = state
        createdAt = now
        updatedAt = now
    }
}
