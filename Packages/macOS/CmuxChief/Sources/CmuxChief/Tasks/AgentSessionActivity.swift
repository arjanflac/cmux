import Foundation

/// Authoritative status of an explicitly bound cmux-owned Codex chat.
public struct AgentSessionActivity: Sendable, Equatable {
    public enum Phase: String, Sendable { case working, attention, idle, unknown }
    public let sessionID: String
    public let phase: Phase
    public init(sessionID: String, phase: Phase) { self.sessionID = sessionID; self.phase = phase }
}
