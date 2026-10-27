public import Foundation

/// Chooses a workspace's configured folder for a fresh local shell only.
public struct WorkspaceLaunchDirectoryPolicy: Sendable {
    /// Creates the stateless launch-folder policy.
    public init() {}

    /// Returns the explicit directory or an eligible configured workspace folder.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's persistent identity.
    ///   - explicit: An authored directory, which always wins.
    ///   - configured: Absolute folders keyed by persistent workspace UUID.
    ///   - isRemote: Whether creation targets a remote workspace.
    ///   - hasStartupWork: Whether creation restores a surface or starts a command.
    ///   - directoryExists: The caller's local directory validation seam.
    /// - Returns: A configured folder only for a fresh shell with no explicit cwd.
    public func resolve(
        workspaceID: UUID, explicit: String?, configured: [String: String],
        isRemote: Bool, hasStartupWork: Bool, directoryExists: (String) -> Bool
    ) -> String? {
        if let explicit { return explicit }
        let matching = configured.filter { UUID(uuidString: $0.key) == workspaceID }
        guard !isRemote, !hasStartupWork, matching.count == 1,
              let folder = matching.values.first,
              (folder as NSString).isAbsolutePath, directoryExists(folder) else { return nil }
        return folder
    }
}
