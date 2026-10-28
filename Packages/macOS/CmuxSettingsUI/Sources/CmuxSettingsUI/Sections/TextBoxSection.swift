import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// **TextBox** section — controls for the rich terminal input.
@MainActor
public struct TextBoxSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let showsLaunchControls: Bool
    @State private var maxLines: DefaultsValueModel<Int>
    @State private var defaultSubmitAction: DefaultsValueModel<String>
    @State private var submitActions: DefaultsValueModel<String>

    /// Creates the TextBox settings section.
    ///
    /// - Parameters:
    ///   - defaultsStore: The store used to read and write TextBox settings.
    ///   - catalog: The catalog that provides the TextBox-related setting keys.
    ///   - showsLaunchControls: False when the host presents the shared launch toggles on its personal page.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, showsLaunchControls: Bool = true) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.showsLaunchControls = showsLaunchControls
        _maxLines = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines))
        _defaultSubmitAction = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxDefaultSubmitAction))
        _submitActions = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxSubmitActions))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.textBox", defaultValue: "TextBox"), section: .textBox)
            SettingsCard {
                if showsLaunchControls {
                    TextBoxLaunchSettingsRows(defaultsStore: defaultsStore, catalog: catalog)
                    SettingsCardDivider()
                }
                defaultSubmitActionRow
                SettingsCardDivider()
                maxLinesRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            defaultSubmitAction,
            submitActions,
            maxLines,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var defaultSubmitActionRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.textBoxDefaultSubmitAction"),
            String(localized: "settings.textBox.defaultSubmitAction", defaultValue: "Default Submit Action"),
            subtitle: String(localized: "settings.textBox.defaultSubmitAction.subtitle", defaultValue: "Used for new terminal sessions. Active Claude, Codex, OpenCode, and Pi sessions always submit as text entry."),
            controlWidth: 210
        ) {
            Picker("", selection: Binding(get: { defaultSubmitAction.current }, set: { defaultSubmitAction.set($0) })) {
                ForEach(defaultSubmitActionOptions) { option in
                    Text(verbatim: option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTextBoxDefaultSubmitActionPicker")
            .accessibilityLabel(
                String(localized: "settings.textBox.defaultSubmitAction", defaultValue: "Default Submit Action")
            )
        }
    }

    private var defaultSubmitActionOptions: [TextBoxSettingsSubmitActionOption] {
        TextBoxSettingsSubmitActionOptions().normalizedOptions(
            configuredJSON: submitActions.current,
            currentID: defaultSubmitAction.current
        )
    }

    @ViewBuilder
    private var maxLinesRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.textBoxMaxLines"),
            String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines"),
            subtitle: String(localized: "settings.textBox.maxLines.subtitle", defaultValue: "Limits how tall the rich terminal input can grow before it scrolls."),
            controlWidth: 196
        ) {
            Stepper(
                value: Binding(get: { maxLines.current }, set: { maxLines.set($0) }),
                in: 1...20
            ) {
                Text(verbatim: "\(maxLines.current)")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTextBoxMaxLinesStepper")
            .accessibilityLabel(
                String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines")
            )
        }
    }
}
