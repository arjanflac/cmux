import Foundation

/// Why the managed task backend rejected or could not confirm an operation.
///
/// Errors thrown by ``AgentManagedTaskBackend/continueTask(id:record:request:)``
/// are raised before the prompt could reach the provider: nothing was sent.
/// Uncertainty after submission arrives as ``AgentTaskEvent/disconnected(_:)``.
public enum AgentManagedTaskError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The task, or its provider session, already has a turn running; nothing was sent.
    case busy
    /// The saved record has no provider session to continue; nothing was sent.
    case missingSession
    /// A live process is bound to a different session than the saved record.
    case sessionMismatch
    /// The provider or presentation cannot honestly support this request.
    case unsupported(String)
    /// Preparing the submission failed before the prompt was sent.
    case notSent(String)
    /// No live turn of this task is owned by this backend.
    case noActiveTurn
    /// Interruption was requested but no native terminal outcome was observed in time.
    case cancellationUnconfirmed
    /// The provider settled the turn with another outcome before the interruption.
    case cancellationSuperseded(String)
    /// The interaction is no longer pending on the live connection or process.
    case staleInteraction
    /// The answer does not fit the provider-native request it answers.
    case invalidResponse(String)
    /// A bounded event buffer filled; later provider events are uncertain.
    case eventOverflow

    /// A stable diagnostic code.
    public var description: String {
        switch self {
        case .busy: return "provider_session_busy"
        case .missingSession: return "provider_session_missing"
        case .sessionMismatch: return "provider_session_mismatch"
        case .unsupported(let reason): return "unsupported: " + reason
        case .notSent(let reason): return "not_sent: " + reason
        case .noActiveTurn: return "no_active_turn"
        case .cancellationUnconfirmed: return "cancellation_unconfirmed"
        case .cancellationSuperseded(let outcome): return "cancellation_superseded: " + outcome
        case .staleInteraction: return "interaction_stale"
        case .invalidResponse(let reason): return "invalid_response: " + reason
        case .eventOverflow: return "event_buffer_overflow"
        }
    }
}
