import Foundation

/// Trusted composition's current read authorization; this value cannot grant authority itself.
///
/// The app derives this metadata only after validating an actual provider context or
/// explicit local operator. A directory read calls that validator again before projection.
public struct AgentTaskWorkerDirectoryAccess: Equatable, Sendable {
    /// Authenticated managed owner; never selected by a model request.
    public let ownerTaskID: UUID
    /// Exact persisted workspace bound to the owner.
    public let workspaceStableID: UUID
    /// Explicit current read targets, not a workspace or ancestry wildcard.
    public let allowedTaskIDs: Set<UUID>

    /// Describes a current read grant without storing a token or provider session.
    /// - Parameters:
    ///   - ownerTaskID: Owner obtained from the verified invocation.
    ///   - workspaceStableID: The owner's verified persisted workspace.
    ///   - allowedTaskIDs: Already-authorized targets; the query also verifies real ancestry.
    public init(ownerTaskID: UUID, workspaceStableID: UUID, allowedTaskIDs: Set<UUID>) {
        self.ownerTaskID = ownerTaskID; self.workspaceStableID = workspaceStableID
        self.allowedTaskIDs = allowedTaskIDs
    }
}
