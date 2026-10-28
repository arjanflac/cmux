import CmuxSettings
import SwiftUI

/// Personal cmux+ controls, composed from the same setting models and actions
/// as the regular panes. Only a personal host can mount or index this page.
@MainActor
struct PersonalSection: View {
    let runtime: SettingsRuntime
    @State private var reorder: DefaultsValueModel<WorkspaceAutoReorderMode>
    @State private var conversations: DefaultsValueModel<Bool>
    @State private var shortcuts: ShortcutListModel

    init(runtime: SettingsRuntime) {
        self.runtime = runtime
        _reorder = State(initialValue: DefaultsValueModel(store: runtime.userDefaultsStore, key: runtime.catalog.app.reorderOnNotification))
        _conversations = State(initialValue: DefaultsValueModel(store: runtime.userDefaultsStore, key: runtime.catalog.betaFeatures.conversationSidebar))
        let host = runtime.hostActions
        _shortcuts = State(initialValue: ShortcutListModel(
            jsonStore: runtime.jsonStore, userDefaultsStore: runtime.userDefaultsStore,
            catalog: runtime.catalog, errorLog: runtime.errorLog,
            canRegisterSystemWideHotkey: { host.canRegisterSystemWideHotkey($0) },
            defaultShortcutResolver: runtime.shortcutDefaultResolver,
            onShortcutsChanged: { host.notifyShortcutSettingsDidChange() }
        ))
    }

    var body: some View {
        Group {
            SettingsSectionHeader(SettingsSectionID.personal.title, section: .personal)
            note(String(localized: "settings.personal.intro", defaultValue: "Personal cmux+ controls. Changes apply as described below; running conversations keep going.", bundle: .module))
            SettingsCard {
                AgentSessionSettingsRows(defaultsStore: runtime.userDefaultsStore, catalog: runtime.catalog,
                                         hostActions: runtime.hostActions, section: .personal)
            }
            note(String(localized: "settings.personal.sessionsApply", defaultValue: "Quiet mode applies to new launches. Auto-resume reconnects supported saved sessions on reopen without restarting model work. Memory controls affect eligible background terminals.", bundle: .module))
            note(String(localized: "settings.personal.coordinationPolicy", defaultValue: "Off by default. Turning coordination off blocks new coordination actions; it does not stop workers already running.", bundle: .module))
            note(String(localized: "settings.personal.coordinationLimits", defaultValue: "Schedules run only while cmux is open. By default, missed work waits for resume. cmux worker limits are separate from native subagent limits. Chief is not connected by this switch.", bundle: .module))
            SettingsCard {
                TextBoxLaunchSettingsRows(defaultsStore: runtime.userDefaultsStore, catalog: runtime.catalog)
            }
            SettingsCard {
                orderingRow
                SettingsCardDivider()
                ShortcutKeymapPresetRow(model: shortcuts, proposals: runtime.keymapProposals, section: .personal)
                SettingsCardDivider()
                conversationsRow
                SettingsCardDivider()
                SettingsCardRow(configurationReview: .settingsOnly, searchAnchorID: "setting:personal:sidebar-visibility",
                    String(localized: "settings.personal.sidebar", defaultValue: "Show / Hide Sidebar (⌘B)", bundle: .module),
                    subtitle: String(localized: "settings.personal.sidebarApply", defaultValue: "Changes the last active cmux window. This is a window action, not a saved preference.", bundle: .module)) {
                    Button(String(localized: "settings.personal.sidebar", defaultValue: "Show / Hide Sidebar (⌘B)", bundle: .module)) { runtime.hostActions.togglePersonalSidebar() }
                        .accessibilityIdentifier("SettingsPersonalSidebarButton")
                }
            }
            note(String(localized: "settings.personal.navigationApply", defaultValue: "Ordering and Conversations update immediately. Session-first makes Cmd+T open a sidebar workspace and Ctrl+Tab switch workspaces. Preview and apply the keymap; custom bindings stay.", bundle: .module))
            note(String(localized: "settings.personal.included", defaultValue: "Always included: narrower sidebar resizing, Swish window movement compatibility, and native input layout fixes. Drag the sidebar edge to resize it.", bundle: .module))
        }
        .accessibilityIdentifier("SettingsPersonalSection")
        .task {
            reorder.startObserving()
            conversations.startObserving()
            shortcuts.startObserving()
        }
    }

    private var orderingRow: some View {
        SettingsCardRow(
            configurationReview: .json("app.reorderOnNotification"),
            String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"),
            subtitle: String(localized: "settings.app.reorderOnNotification.modeSubtitle", defaultValue: "Notifications and Agent Activity move recently active workspaces up. Working First keeps working workspaces above idle ones, preserving pinned and selected rows. Ordering waits while you point at the sidebar."),
            controlWidth: 180
        ) {
            Picker("", selection: Binding(get: { reorder.current }, set: { reorder.set($0) })) {
                Text(String(localized: "settings.app.reorderOnNotification.mode.off", defaultValue: "Off")).tag(WorkspaceAutoReorderMode.off)
                Text(String(localized: "settings.app.reorderOnNotification.mode.notifications", defaultValue: "Notifications")).tag(WorkspaceAutoReorderMode.notifications)
                Text(String(localized: "settings.app.reorderOnNotification.mode.agentActivity", defaultValue: "Agent Activity")).tag(WorkspaceAutoReorderMode.agentActivity)
                Text(String(localized: "settings.app.reorderOnNotification.mode.workingFirst", defaultValue: "Working First")).tag(WorkspaceAutoReorderMode.workingFirst)
            }
            .labelsHidden().pickerStyle(.menu)
            .accessibilityIdentifier("SettingsPersonalOrderingPicker")
        }
    }

    private var conversationsRow: some View {
        SettingsCardRow(
            configurationReview: .json("sidebar.beta.conversations.enabled"),
            String(localized: "settings.betaFeatures.conversationSidebar", defaultValue: "Conversation Sidebar"),
            subtitle: conversations.current
                ? String(localized: "settings.betaFeatures.conversationSidebar.subtitleOn", defaultValue: "Shows Conversations in the left sidebar picker.")
                : String(localized: "settings.betaFeatures.conversationSidebar.subtitleOff", defaultValue: "Hides Conversations while preserving existing agent sessions.")
        ) {
            Toggle("", isOn: Binding(get: { conversations.current }, set: { conversations.set($0) }))
                .labelsHidden().controlSize(.small)
                .accessibilityIdentifier("SettingsPersonalConversationSidebarToggle")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).cmuxFont(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 2)
    }
}
