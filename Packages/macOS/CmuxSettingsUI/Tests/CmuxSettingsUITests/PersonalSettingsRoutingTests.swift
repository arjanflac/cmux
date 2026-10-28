import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@Suite("Personal Settings routing")
struct PersonalSettingsRoutingTests {
    @Test func ordinaryHostsKeepExistingDestinationsAndHidePersonalControls() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        #expect(index.match("").allSatisfy { $0.id != "section:personal" })
        #expect(index.match("sidebar visibility").allSatisfy { $0.id != "setting:personal:sidebar-visibility" })
        #expect(index.anchorID(forSettingsPath: "terminal.agentOrchestration") == "setting:terminal:agent-orchestration")
        #expect(index.anchorID(forSettingsPath: "terminal.autoResumeAgentSessions") == "setting:terminal:agent-auto-resume")
        #expect(index.anchorID(forSettingsPath: "app.reorderOnNotification") == "setting:app:reorder-notification")
    }

    @Test func personalHostsHaveOneCanonicalDestinationForExistingControls() throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog(), personalCustomizationAvailable: true)
        for (path, row) in [
            ("terminal.codexQuietFrontend", "codex-quiet"),
            ("terminal.agentOrchestration", "agent-orchestration"),
            ("terminal.autoResumeAgentSessions", "agent-auto-resume"),
            ("terminal.agentHibernation.enabled", "agent-hibernation"),
            ("terminal.rendererRealization.enabled", "renderer-realization"),
            ("terminal.showTextBoxOnNewTerminals", "show-textbox-new-terminals"),
            ("terminal.focusTextBoxOnNewTerminals", "focus-textbox-new-terminals"),
            ("app.reorderOnNotification", "reorder-notification"),
            ("sidebar.beta.conversations.enabled", "conversationSidebar"),
        ] {
            let id = "setting:personal:" + row
            #expect(index.anchorID(forSettingsPath: path) == id)
            let matches = index.match(path).filter { $0.id == id }
            #expect(matches.count == 1)
            let entry = try #require(matches.first)
            #expect(entry.kind == .setting(parent: .personal))
        }
        #expect(index.entries.contains { $0.id == "setting:personal:base-keymap" })
        #expect(!index.entries.contains { $0.id == "setting:keyboardShortcuts:base-keymap" })
        #expect(index.entries.contains { $0.id == "section:terminal" })
        #expect(index.entries.contains { $0.id == "section:keyboardShortcuts" })
    }

    @Test func oldRowLinksReachTheMovedRowOnlyOnPersonalHosts() {
        let moved = PersonalSettingsRouting.navigation(section: .terminal, anchorID: "setting:terminal:agent-auto-resume", available: true)
        #expect(moved.section == .personal)
        #expect(moved.anchorID == "setting:personal:agent-auto-resume")
        let original = PersonalSettingsRouting.navigation(section: .terminal, anchorID: "setting:terminal:agent-auto-resume", available: false)
        #expect(original.section == .terminal)
        #expect(original.anchorID == "setting:terminal:agent-auto-resume")
        let ordinary = PersonalSettingsRouting.navigation(section: .app, anchorID: "section:app", available: true)
        #expect(ordinary.section == .app)
        #expect(ordinary.anchorID == "section:app")
        let unavailable = PersonalSettingsRouting.navigation(section: .personal, anchorID: "section:personal", available: false)
        #expect(unavailable.section == .app)
        #expect(unavailable.anchorID == "section:app")
    }

    @MainActor @Test func legacyNotificationSelectsTheSamePersonalPaneAsItsRow() throws {
        let notification = Notification(name: SettingsWindowRoot.navigationRequestName,
            userInfo: ["target": "terminal", "anchor": "setting:terminal:agent-auto-resume"])
        let personal = try #require(SettingsWindowRoot.navigationDestination(for: notification, personalAvailable: true))
        #expect(personal.section == .personal)
        #expect(personal.anchorID == "setting:personal:agent-auto-resume")
        let ordinary = try #require(SettingsWindowRoot.navigationDestination(for: notification, personalAvailable: false))
        #expect(ordinary.section == .terminal)
        #expect(ordinary.anchorID == "setting:terminal:agent-auto-resume")
    }

    @MainActor @Test func mountingUsesTheSameExplicitHostCapability() {
        #expect(!NoopSettingsHostActions().isPersonalCustomizationAvailable)
        #expect(!SettingsWindowRoot.mountOrder(cloudAvailable: true).contains(.personal))
        #expect(SettingsWindowRoot.mountOrder(cloudAvailable: true, personalAvailable: true).first == .personal)
        #expect(!SettingsWindowRoot.mountOrder(cloudAvailable: false, personalAvailable: true).contains(.cloudMachines))
    }
}
