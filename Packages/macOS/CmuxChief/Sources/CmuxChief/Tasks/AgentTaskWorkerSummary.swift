import Foundation

/// Small worker metadata with no prompt, result, path, provider-session ID or transport credential.
public struct AgentTaskWorkerSummary: Codable, Equatable, Sendable {
    /// Stable coordinator identity accepted by send, read and result operations.
    public let taskID: UUID
    /// Provider executing this worker.
    public let provider: AgentTaskRequest.Provider
    /// Sanitized short existing title, which may derive from the first prompt line.
    public let title: String
    /// Sanitized requested model, when available.
    public let model: String?
    /// Persistent for legacy records unless explicitly created one-shot.
    public let lifecycle: AgentTaskRequest.Lifecycle
    /// Local retirement only; provider histories are not archived or deleted.
    public let retirement: Retirement
    /// Latest owned receipt phase; this does not promise provider-wide idleness.
    public let phase: AgentTaskRecord.Phase
    /// Exact latest operation for result/turn inspection, when known.
    public let latestOperationID: UUID?
    /// True only for a locally settled persistent worker; dispatch still performs native preflight.
    public let reusable: Bool
    /// Why another submission requires preflight or is currently unavailable locally.
    public let followUp: FollowUp
    /// Latest saved/observed metadata time, not a routing or ownership proof.
    public let updatedAt: Date

    /// Local lifecycle state, independent of provider history retention.
    public enum Retirement: String, Codable, Sendable {
        /// No local retirement intent exists.
        case none
        /// Retirement was requested or resources are still being released.
        case pending
        /// Locally retired; durable results remain readable.
        case retired
    }

    /// Local follow-up eligibility, with no promise that another frontend is idle.
    public enum FollowUp: String, Codable, Sendable {
        /// Locally reusable; the normal dispatch path must still recheck the provider.
        case requiresPreflight = "requires_preflight"
        /// A turn or local transition is in progress.
        case working
        /// Human input or approval is still required.
        case needsInput = "needs_input"
        /// Provider acceptance/execution is unresolved or an ancestor cannot be continued.
        case unreconciled
        /// No confirmed provider session is available.
        case missingSession = "missing_session"
        /// This worker was intended for one result rather than persistent reuse.
        case oneShot = "one_shot"
        /// Local retirement is pending.
        case retiring
        /// Local retirement is complete.
        case retired
    }

    init(_ record: AgentTaskRecord, locallyBusy: Bool, retiring: Bool, usableAncestry: Bool) {
        taskID = record.id; provider = record.provider
        title = Self.sanitize(record.title, maximum: 100) ?? record.provider.rawValue
        model = record.model.flatMap { Self.sanitize($0, maximum: 80) }
        lifecycle = record.lifecycle ?? .persistent
        retirement = record.isRetired ? .retired : (record.retirement != nil || retiring ? .pending : .none)
        phase = record.phase; latestOperationID = record.latestOperationID; updatedAt = record.updatedAt
        if retirement == .retired { followUp = .retired }
        else if retirement == .pending { followUp = .retiring }
        else if !usableAncestry || record.phase == .disconnected { followUp = .unreconciled }
        else if record.phase == .needsInput { followUp = .needsInput }
        else if locallyBusy || !record.phase.isFinished { followUp = .working }
        else if record.sessionID?.isEmpty != false { followUp = .missingSession }
        else if lifecycle == .oneShot { followUp = .oneShot }
        else { followUp = .requiresPreflight }
        reusable = followUp == .requiresPreflight
    }

    private static func sanitize(_ value: String, maximum: Int) -> String? {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }.prefix(maximum)
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id", provider, title, model, lifecycle, retirement, phase, reusable
        case latestOperationID = "latest_operation_id", followUp = "follow_up", updatedAt = "updated_at"
    }
}
