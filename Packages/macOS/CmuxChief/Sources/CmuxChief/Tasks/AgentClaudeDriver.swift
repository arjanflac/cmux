import CmuxHomeCore
import Foundation

/// The managed Claude Code operations a task backend needs from one brain.
///
/// ``ClaudeCodeBrain`` conforms; its configuration must set
/// ``ClaudeCodeBrain/Configuration/managedConversation``. Tests supply fixtures.
protocol AgentClaudeDriver: Sendable {
    /// Starts one turn; managed failures arrive as thrown `ClaudeManagedTurnError` values.
    func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error>
    /// Answers one pending permission exactly once, or throws when it is stale.
    func answerPermission(_ id: String, allow: Bool, conversation: ConversationID) async throws
    /// Asks Claude Code to interrupt; the outcome arrives on the turn's stream.
    func interrupt(conversation: ConversationID) async
    /// Stops the process; its session stays resumable.
    func shutdown() async
}
