/// A task-authority rejection that never includes a bearer credential.
public enum AgentTaskScopeError: String, Error, Sendable, Codable {
    /// The token does not have the authority's bounded canonical format.
    case malformedToken
    /// No active or revoked registry entry matches the token hash.
    case unknownCapability
    /// The grant was explicitly revoked.
    case revoked
    /// The grant reached its expiry boundary; backward clock movement cannot revive it.
    case expired
    /// The token or scope belongs to another app lifetime.
    case epochMismatch
    /// The exact provider session was omitted or differs from the enrolled session.
    case sessionMismatch
    /// The binding generation was omitted or differs from the enrolled generation.
    case bindingMismatch
    /// The operation is not granted.
    case operationDenied
    /// The requested target is outside the grant or the owner's descendant graph.
    case targetNotOwned
    /// A caller-supplied parent differs from the authenticated caller task identity.
    case conflictingParent
    /// The lifetime or clock instant is nonfinite, or the lifetime is not positive.
    case invalidLifetime
    /// A root limit is invalid or an existing lineage's immutable limits were changed.
    case invalidBudget
    /// An enrolled session or binding identity is empty.
    case invalidBinding
    /// The entropy source did not supply exactly 256 bits or repeated an issued token.
    case invalidEntropy
    /// A nonroot issue request lacks a reserved child or a live parent grant.
    case missingParentGrant
    /// A child would exceed the maximum delegation depth.
    case depthLimitExceeded
    /// Existing plus pending direct children exhaust this owner's capacity.
    case childLimitExceeded
    /// All branches together exhaust the root's descendant reservation budget.
    case lineageBudgetExceeded
}
