import AppKit
import CmuxWorkspaces
import UniformTypeIdentifiers

@MainActor
extension TabManager {
    /// Starts the shared manual-image flow used by both native sidebar implementations.
    func chooseWorkspaceIcon(workspaceId: UUID) {
        guard tabs.contains(where: { $0.id == workspaceId }) else { return }
        let token = UUID()
        workspaceIconImportTokens[workspaceId] = token
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.message = String(localized: "workspace.icon.choose.message", defaultValue: "Choose an image for this workspace.")
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                if self.workspaceIconImportTokens[workspaceId] == token {
                    self.workspaceIconImportTokens.removeValue(forKey: workspaceId)
                }
                return
            }
            Task { @MainActor [weak self] in
                do {
                    let icon = try await WorkspaceIconImporter().importIcon(from: url)
                    guard let self,
                          self.workspaceIconImportTokens[workspaceId] == token else { return }
                    self.workspaceIconImportTokens.removeValue(forKey: workspaceId)
                    guard let workspace = self.tabs.first(where: { $0.id == workspaceId }) else { return }
                    self.applyWorkspaceIcon(icon, to: workspace)
                } catch {
                    guard let self,
                          self.workspaceIconImportTokens[workspaceId] == token else { return }
                    self.workspaceIconImportTokens.removeValue(forKey: workspaceId)
                    guard self.tabs.contains(where: { $0.id == workspaceId }) else { return }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "workspace.icon.import.error.title", defaultValue: "Couldn't Import Workspace Icon")
                    alert.informativeText = String(localized: "workspace.icon.import.error.message", defaultValue: "Choose a PNG, JPEG, TIFF, or HEIC image smaller than 10 MB. Your current icon hasn't changed.")
                    alert.runModal()
                }
            }
        }
    }

    func removeWorkspaceIcon(workspaceId: UUID) {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return }
        applyWorkspaceIcon(nil, to: workspace)
    }
}
