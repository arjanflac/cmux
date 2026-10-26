import CmuxSettings
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Applies the authored folder only while creating a fresh local shell.
    func launchDirectoryForNewTerminal(explicit: String?, hasStartupWork: Bool) -> String? {
        let folders = UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().terminal.workspaceLaunchDirectories)
        return WorkspaceLaunchDirectoryPolicy().resolve(
            workspaceID: stableId, explicit: explicit, configured: folders,
            isRemote: isRemoteWorkspace, hasStartupWork: hasStartupWork,
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
    }
}
