import Foundation

/// A provider-native request for a user decision that is pending in a live managed turn.
///
/// Interactions are never answered automatically. Read them with
/// ``AgentManagedTaskBackend/interactions(id:)`` and answer one exactly once
/// with ``AgentManagedTaskBackend/respond(id:requestID:response:)``. An
/// interaction from an earlier connection, process or turn is stale and its
/// answer fails instead of reaching later work.
///
/// ```swift
/// for interaction in await backend.interactions(id: task) where interaction.answer == .allowOrDeny {
///     try await backend.respond(id: task, requestID: interaction.requestID,
///                               response: Data(#"{"behavior":"deny"}"#.utf8))
/// }
/// ```
public struct AgentTaskInteraction: Sendable, Equatable {
    /// What the provider asks for.
    public enum Kind: String, Sendable {
        /// Codex asks to run a command.
        case commandApproval
        /// Codex asks to apply a file change.
        case fileChangeApproval
        /// Codex asks for additional permissions.
        case permissionApproval
        /// Claude Code asks whether a tool may run.
        case toolApproval
        /// The provider asks the user a question.
        case userInput
        /// An MCP server asks for structured input.
        case elicitation
        /// A request this backend cannot interpret.
        case unknown
    }

    /// Which answers this backend can deliver for the request.
    public enum Answer: String, Sendable {
        /// The provider-native JSON result object for ``method`` (Codex app-server).
        case nativeResponse
        /// `{"behavior":"allow"}` or `{"behavior":"deny"}` (Claude Code).
        case allowOrDeny
        /// Only `{"behavior":"deny"}`: cmux cannot supply this request's answer.
        case denyOnly
        /// No answer can be delivered; use the provider's own client.
        case unsupported
    }

    /// The managed task whose live turn asked.
    public let taskID: UUID
    /// The provider request identity as text: a string ID verbatim, a numeric ID in decimal.
    public let requestID: String
    /// What is asked.
    public let kind: Kind
    /// Provider-native method or tool name.
    public let method: String
    /// A short human-readable description.
    public let summary: String
    /// Provider-offered decisions, when it lists them.
    public let options: [String]
    /// Which answers can be delivered.
    public let answer: Answer
    /// The provider-native request parameters as compact JSON.
    public let request: Data
}
