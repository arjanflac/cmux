import Foundation

/// Native terminal outcomes of managed turns, and the cancellations waiting for them.
///
/// An interrupt request or its RPC acknowledgment is not proof of
/// cancellation. A cancelling caller waits here for the provider's own
/// terminal outcome of the exact operation it interrupted.
struct AgentTurnOutcomeWaiters {
    private var waiting: [UUID: [UUID: CheckedContinuation<AgentTaskEvent?, Never>]] = [:]
    private var outcomes: [UUID: (operation: UUID, event: AgentTaskEvent)] = [:]

    /// Records the terminal outcome of `operation` and wakes its waiters.
    mutating func record(_ event: AgentTaskEvent, id: UUID, operation: UUID) {
        outcomes[id] = (operation, event)
        for waiter in (waiting.removeValue(forKey: id) ?? [:]).values { waiter.resume(returning: event) }
    }

    /// The recorded outcome of `operation`, if it already ended.
    func outcome(id: UUID, operation: UUID) -> AgentTaskEvent? {
        guard let saved = outcomes[id], saved.operation == operation else { return nil }
        return saved.event
    }

    /// Parks `continuation` until the task's live turn records an outcome.
    mutating func add(id: UUID, token: UUID, continuation: CheckedContinuation<AgentTaskEvent?, Never>) {
        waiting[id, default: [:]][token] = continuation
    }

    /// The deadline passed: wakes one waiter without an outcome.
    mutating func expire(id: UUID, token: UUID) {
        waiting[id]?.removeValue(forKey: token)?.resume(returning: nil)
    }

    /// Succeeds only for a provider-confirmed cancellation.
    ///
    /// - Throws: ``AgentManagedTaskError/cancellationUnconfirmed`` without an
    ///   outcome; ``AgentManagedTaskError/cancellationSuperseded(_:)`` when the
    ///   turn ended otherwise, so the coordinator keeps the actual outcome.
    static func confirmCancellation(_ outcome: AgentTaskEvent?) throws {
        switch outcome {
        case .cancelled?: return
        case nil: throw AgentManagedTaskError.cancellationUnconfirmed
        case let other?: throw AgentManagedTaskError.cancellationSuperseded(String(describing: other))
        }
    }
}
