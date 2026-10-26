import Foundation

/// Serializable, nonsecret identity and lifetime metadata for a capability.
///
/// This value contains only the bearer hash, never its raw credential. Decoding
/// it grants no authority. The raw token exists only in ``AgentTaskScopeGrant``.
public struct AgentTaskScopeCapability: Sendable, Codable, Equatable {
    /// SHA-256 of the complete raw bearer token, safe for correlation.
    public let tokenDigest: String
    /// App-lifetime epoch of the issuing authority.
    public let appEpoch: UUID
    /// Clock instant at which the capability was issued.
    public let issuedAt: Date
    /// Exclusive expiry boundary; validation at this instant fails.
    public let expiresAt: Date
}
