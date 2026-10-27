import Foundation

/// Confirmed provider events for one explicitly managed task.
public enum AgentTaskEvent: Equatable, Sendable {
    /// The exact provider session to present. Claude confirms its planned ID through SessionStart.
    case session(String)
    /// The provider reports active execution.
    case running
    /// The task needs attention in its ordinary terminal or phone client.
    case needsInput(String)
    /// The provider reported its first-turn result.
    case completed(String)
    /// The provider acknowledged an interrupt.
    case cancelled
    /// The provider reported an unsuccessful turn.
    case failed(String)
    /// The transport or provider state is uncertain.
    case disconnected(String)
}
