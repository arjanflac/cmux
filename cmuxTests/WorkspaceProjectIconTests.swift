import AppKit
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceProjectIconTests {
    @Test("sidebar snapshots reuse a decoded image and reflect removal")
    func sidebarImageLifetime() throws {
        let workspace = Workspace(title: "Project", workingDirectory: "/tmp", portOrdinal: 0)
        defer { workspace.teardownAllPanels() }
        let suite = "WorkspaceProjectIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: false
        )
        let withoutIcon = factory.makeSnapshot()
        let icon = try makeIcon()
        workspace.setCustomIcon(icon)
        let withIcon = factory.makeSnapshot()
        let cachedImage = try #require(withIcon.customIcon?.image)
        #expect(withIcon != withoutIcon)
        #expect(withIcon.customIcon?.fingerprint == icon.fingerprint)
        #expect(factory.makeSnapshot() == withIcon)
        #expect(factory.makeSnapshot().customIcon?.image === cachedImage)
        workspace.setCustomIcon(nil)
        #expect(factory.makeSnapshot() == withoutIcon)
    }

    @Test("explicit removal wins over an older session snapshot")
    func recoveryTombstone() throws {
        let suite = "WorkspaceProjectIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceCustomizationStore(defaults: defaults)
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: store)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let icon = try makeIcon()
        manager.applyWorkspaceIcon(icon, to: workspace)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.customIcon == icon)
        manager.removeWorkspaceIcon(workspaceId: workspace.id)
        // Model a stale autosave restoring its old image before journal reconciliation.
        workspace.setCustomIcon(decoded.customIcon)
        manager.reconcileWorkspaceCustomization(afterRestoring: decoded, to: workspace)
        #expect(workspace.customIcon == nil)
        #expect(workspace.sidebarIcon == nil)
    }

    private func makeIcon() throws -> WorkspaceIcon {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        return try #require(WorkspaceIcon(pngData: png))
    }
}
