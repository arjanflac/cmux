import AppKit
import CmuxWorkspaces

/// Decoded, immutable thumbnail prepared when workspace identity changes, never in a row body.
struct SidebarWorkspaceIconSnapshot: Equatable {
    let fingerprint: String
    let image: NSImage

    init?(_ icon: WorkspaceIcon) {
        guard let image = NSImage(data: icon.pngData) else { return nil }
        self.fingerprint = icon.fingerprint
        self.image = image
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }
}
