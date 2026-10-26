/// An issued bearer credential and its independently serializable public scope.
///
/// Deliberately not `Codable`. Keep this value in private transport memory; never
/// place the raw token in prompts, transcripts, environment, argv, or durable
/// schedule records. Private capability-file transport belongs to the app bridge.
public struct AgentTaskScopeGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The secret bearer token, returned only at issuance.
    public let token: String
    /// Nonsecret metadata that may be encoded for a renderer or inspector.
    public let scope: AgentTaskScope

    /// A diagnostic description that omits the bearer token.
    public var description: String { "AgentTaskScopeGrant(<redacted>)" }
    /// A debug description that omits the bearer token.
    public var debugDescription: String { description }
    /// A reflection surface that exposes only nonsecret scope metadata.
    public var customMirror: Mirror { Mirror(self, children: ["scope": scope]) }
}
