import Foundation

/// Public, nonsecret metadata describing an ephemeral task-authority grant.
///
/// Encoding this value never encodes its bearer token. A decoded value is not
/// proof of enrollment and cannot authorize an external client. The app may use
/// an issued value with trusted composition APIs after authenticating the caller.
public struct AgentTaskScope: Sendable, Codable, Equatable {
    /// Public capability identity and lifetime; this contains no raw token.
    public let capability: AgentTaskScopeCapability
    /// SHA-256 of the entire raw token; safe for correlation, never a bearer credential.
    public var tokenDigest: String { capability.tokenDigest }
    /// App-lifetime authority epoch; a fresh authority must receive a fresh epoch.
    public var appEpoch: UUID { capability.appEpoch }
    /// Exact task identity of the enrolled caller.
    public let ownerTaskID: UUID
    /// Exact provider connection/session identity established by the app's live proof.
    public let providerSessionID: String
    /// Stable workspace identity for routing; it never proves caller authority.
    public let workspaceStableID: UUID
    /// App-issued generation that changes with the live process/chat binding.
    public let bindingGeneration: String
    /// Operations explicitly granted by native enrollment.
    public let allowedOperations: Set<AgentTaskScopeOperation>
    /// Explicit task targets, including the owner; validate each target on reads and writes.
    public internal(set) var allowedTargets: Set<UUID>
    /// Root whose immutable budget covers this grant.
    public let rootTaskID: UUID
    /// Actual parent in the reserved task graph, absent only for a root.
    public let parentTaskID: UUID?
    /// Delegation depth, with a root at zero.
    public let depth: Int
    /// Root limits inherited without replenishment by child grants.
    public let budget: AgentTaskScopeBudget
    /// Clock instant at which the grant was issued.
    public var issuedAt: Date { capability.issuedAt }
    /// Exclusive expiry boundary; validation at this instant fails.
    public var expiresAt: Date { capability.expiresAt }
}
