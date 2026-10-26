import Foundation

/// Fail-closed admission, persistence and evidence errors from the task journal.
public enum AgentTaskJournalError: Error, Equatable, Sendable {
    /// Invalid size, date, recurrence, receipt or target shape.
    case invalidRequest
    /// A stable caller key or evidence key was reused for a different payload.
    case conflict
    /// The bounded schedule, inbox or outstanding capacity is exhausted.
    case capacity
    /// Owner-scoped record does not exist.
    case notFound
    /// Transition would resume cancelled/exhausted work or unresolved provider work.
    case invalidTransition
    /// Journal was explicitly closed.
    case closed
    /// Storage failed; SQLite's numeric error is retained without private SQL or payloads.
    case storage(Int32)
    /// Private directory or database could not be secured, or is a symbolic link.
    case insecurePath
}
