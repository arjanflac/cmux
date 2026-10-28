import CmuxSettings
import SwiftUI

/// Shared native input launch controls; existing terminal input is unaffected.
@MainActor
struct TextBoxLaunchSettingsRows: View {
    @State private var showOnNewTerminals: DefaultsValueModel<Bool>
    @State private var focusOnNewTerminals: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _showOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showTextBoxOnNewTerminals))
        _focusOnNewTerminals = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.focusTextBoxOnNewTerminals))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            showOnNewTerminalsRow
            SettingsCardDivider()
            focusOnNewTerminalsRow
        }
        .task { showOnNewTerminals.startObserving(); focusOnNewTerminals.startObserving() }
    }

    @ViewBuilder
    private var showOnNewTerminalsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.showTextBoxOnNewTerminals"),
            String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals"),
            subtitle: String(localized: "settings.textBox.showOnNewTerminals.subtitle", defaultValue: "Opening a terminal tab, split, or workspace shows the TextBox.")
        ) {
            Toggle("", isOn: Binding(get: { showOnNewTerminals.current }, set: { showOnNewTerminals.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTextBoxShowOnNewTerminalsToggle")
                .accessibilityLabel(
                    String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals")
                )
        }
    }

    @ViewBuilder
    private var focusOnNewTerminalsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.focusTextBoxOnNewTerminals"),
            String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals"),
            subtitle: String(localized: "settings.textBox.focusOnNewTerminals.subtitle", defaultValue: "Opening a terminal tab, split, or workspace puts keyboard focus in the TextBox.")
        ) {
            Toggle("", isOn: Binding(get: { focusOnNewTerminals.current }, set: { focusOnNewTerminals.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTextBoxFocusOnNewTerminalsToggle")
                .accessibilityLabel(
                    String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals")
                )
        }
    }

}
