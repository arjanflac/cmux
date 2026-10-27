import CmuxFoundation
import Foundation

/// One verified frontend view. Its files convey transport state, never model instructions.
struct NativeAgentTaskPanel {
    let id: UUID
    /// A fresh private file generation prevents an older refresh from replacing a new registration.
    let storageID = UUID()
    let workspaceID: UUID
    let surfaceID: UUID
    let ownerTaskID: UUID
    let sessionID: String
    let process: AgentPIDProcessIdentity
    let invocationID: String
    let generation: String
    var paths: (snapshot: URL, scope: URL)?
    var renewedAt: Date
}
