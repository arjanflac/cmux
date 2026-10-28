import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The same settings-backed session controls in Terminal (stock hosts) or cmux+.
@MainActor
struct AgentSessionSettingsRows: View {
    let hostActions: SettingsHostActions
    let section: SettingsSectionID
    @State private var tasks = MainActorTaskStore<String>()
    @State private var autoResume: DefaultsValueModel<Bool>
    @State private var quietStatus: QuietCodexStatus?
    @State private var checkingQuiet = false
    @State private var codexQuiet: DefaultsValueModel<Bool>
    @State private var agentOrchestration: DefaultsValueModel<Bool>
    @State private var hibernation: DefaultsValueModel<Bool>
    @State private var idleSeconds: DefaultsValueModel<Double>
    @State private var maxLive: DefaultsValueModel<Int>
    @State private var rendererReclaim: DefaultsValueModel<Bool>
    @State private var rendererIdleSeconds: DefaultsValueModel<Double>
    @State private var rendererMaxWarm: DefaultsValueModel<Int>
    @State private var memGuardrailEnabled: DefaultsValueModel<Bool>
    @State private var memGuardrailThresholdGB: DefaultsValueModel<Double>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog,
         hostActions: SettingsHostActions, section: SettingsSectionID) {
        self.hostActions = hostActions
        self.section = section
        _autoResume = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions))
        _codexQuiet = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.codexQuietFrontend))
        _agentOrchestration = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentOrchestration))
        _hibernation = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled))
        _idleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds))
        _maxLive = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals))
        _rendererReclaim = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationEnabled))
        _rendererIdleSeconds = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationIdleSeconds))
        _rendererMaxWarm = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.rendererRealizationMaxWarmRenderers))
        _memGuardrailEnabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.runawayMemoryGuardrailEnabled))
        _memGuardrailThresholdGB = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.runawayMemoryGuardrailThresholdGB))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .json("terminal.agentOrchestration"),
                String(localized: "settings.terminal.agentOrchestration", defaultValue: "Background Agent Coordination", bundle: .module),
                subtitle: String(localized: "settings.terminal.agentOrchestration.subtitle", defaultValue: "Allow this cmux session to use background workers and scheduled tasks. Schedules run while cmux is open; missed work waits until resumed.", bundle: .module)
            ) {
                Toggle("", isOn: Binding(get: { agentOrchestration.current }, set: { agentOrchestration.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentOrchestrationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.codexQuietFrontend"),
                String(localized: "settings.terminal.codexQuiet", defaultValue: "Hide Codex Tool Calls"),
                subtitle: section == .personal
                    ? String(localized: "settings.personal.quietRequirement", defaultValue: "Requires the fullscreen Codex transcript. Ctrl+T shows details; inline scrollback keeps standard rendering. Errors and approvals stay visible.", bundle: .module)
                    : String(localized: "settings.terminal.codexQuiet.subtitle", defaultValue: "New terminals start quiet. Ctrl+T shows or hides tool details. Errors and approvals stay visible. Incompatible launches use stock Codex.")
            ) {
                Toggle("", isOn: Binding(get: { codexQuiet.current }, set: { codexQuiet.set($0) }))
                    .labelsHidden().controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalCodexQuietToggle")
            }
            VStack(alignment: .leading, spacing: 8) {
                if let status = quietStatus {
                    Text(String.localizedStringWithFormat(String(localized: "settings.terminal.codexQuiet.versions", defaultValue: "Bundled: %@ · Installed Codex: %@"), status.bundledVersion ?? "—", status.stockVersion ?? "—"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(status.compatible
                        ? String(localized: "settings.terminal.codexQuiet.ready", defaultValue: "Compatible. New Codex terminals can use quiet mode.")
                        : String(localized: "settings.terminal.codexQuiet.fallback", defaultValue: "Stock Codex will be used. The quiet frontend needs a compatible build and a running stock daemon."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(String(localized: "settings.terminal.codexQuiet.check", defaultValue: "Check Compatibility")) {
                        checkingQuiet = true
                        tasks.replaceOnMainActor("quiet-status") {
                            quietStatus = await hostActions.quietCodexStatus(); checkingQuiet = false
                        }
                    }.disabled(checkingQuiet)
                    Button(String(localized: "settings.terminal.codexQuiet.builds", defaultValue: "Build / Update…")) { hostActions.openQuietCodexBuilds() }
                }
                Text(String(localized: "settings.terminal.codexQuiet.maintenance", defaultValue: "Codex updates normally. A new version may need its quiet patch reviewed and rebuilt. Build / Update opens GitHub; it never replaces a running app or updates Codex."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            .task { quietStatus = await hostActions.quietCodexStatus() }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.autoResumeAgentSessions"),
                String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"),
                subtitle: String(localized: "settings.terminal.agentAutoResume.subtitle", defaultValue: "Reopening cmux resumes agent sessions automatically.")
            ) {
                Toggle("", isOn: Binding(get: { autoResume.current }, set: { autoResume.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.enabled"),
                String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"),
                subtitle: String(localized: "settings.terminal.agentHibernation.subtitle", defaultValue: "Hibernates idle background agent terminals above the live terminal limit. Even when this is off, cmux may hibernate them under memory pressure.")
            ) {
                Toggle("", isOn: Binding(get: { hibernation.current }, set: { hibernation.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentHibernationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.idleSeconds"),
                String(localized: "settings.terminal.agentHibernation.idleSeconds", defaultValue: "Hibernate After Idle Seconds"),
                subtitle: String(localized: "settings.terminal.agentHibernation.idleSeconds.subtitle", defaultValue: "A terminal must have no output and report an idle agent lifecycle for this long before it can be hibernated."),
                controlWidth: 140
            ) {
                Stepper(
                    "\(Int(idleSeconds.current))",
                    value: Binding(get: { idleSeconds.current }, set: { idleSeconds.set($0) }),
                    in: 5...604_800,
                    step: 60
                )
                .accessibilityIdentifier("SettingsTerminalAgentHibernationIdleSecondsStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.maxLiveTerminals"),
                String(localized: "settings.terminal.agentHibernation.maxLiveTerminals", defaultValue: "Max Live Agent Terminals"),
                subtitle: String(localized: "settings.terminal.agentHibernation.maxLiveTerminals.subtitle", defaultValue: "Visible terminals stay live. Extra idle background agent terminals hibernate oldest first."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(maxLive.current)",
                    value: Binding(get: { maxLive.current }, set: { maxLive.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .accessibilityIdentifier("SettingsTerminalAgentHibernationMaxLiveStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.enabled"),
                String(localized: "settings.terminal.rendererRealization", defaultValue: "Reclaim Offscreen Terminal Memory"),
                subtitle: String(localized: "settings.terminal.rendererRealization.subtitle", defaultValue: "Frees graphics memory from terminals that are out of view. Their processes keep running.")
            ) {
                Toggle("", isOn: Binding(get: { rendererReclaim.current }, set: { rendererReclaim.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalRendererRealizationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.idleSeconds"),
                String(localized: "settings.terminal.rendererRealization.idleSeconds", defaultValue: "Reclaim After Idle Seconds"),
                subtitle: String(localized: "settings.terminal.rendererRealization.idleSeconds.subtitle", defaultValue: "An off-screen terminal must stay off-screen this long before its renderer memory is reclaimed."),
                controlWidth: 140
            ) {
                Stepper(
                    "\(Int(rendererIdleSeconds.current))",
                    value: Binding(get: { rendererIdleSeconds.current }, set: { rendererIdleSeconds.set($0) }),
                    in: 5...604_800,
                    step: 10
                )
                .accessibilityIdentifier("SettingsTerminalRendererRealizationIdleSecondsStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.rendererRealization.maxWarmRenderers"),
                String(localized: "settings.terminal.rendererRealization.maxWarmRenderers", defaultValue: "Max Warm Renderers"),
                subtitle: String(localized: "settings.terminal.rendererRealization.maxWarmRenderers.subtitle", defaultValue: "The most recently visible terminals keep their renderer ready so switching stays instant. Extra off-screen renderers are reclaimed oldest first."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(rendererMaxWarm.current)",
                    value: Binding(get: { rendererMaxWarm.current }, set: { rendererMaxWarm.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .accessibilityIdentifier("SettingsTerminalRendererRealizationMaxWarmStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:\(section.rawValue):memory-guardrail",
                String(localized: "settings.terminal.memoryGuardrail", defaultValue: "Runaway Memory Guardrail"),
                subtitle: String(localized: "settings.terminal.memoryGuardrail.subtitle", defaultValue: "Warns when the processes in one pane use too much memory.")
            ) {
                Toggle("", isOn: Binding(get: { memGuardrailEnabled.current }, set: { memGuardrailEnabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalMemoryGuardrailToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:\(section.rawValue):memory-guardrail-threshold",
                String(localized: "settings.terminal.memoryGuardrail.threshold", defaultValue: "Memory Warning Threshold (GB)"),
                subtitle: String(localized: "settings.terminal.memoryGuardrail.threshold.subtitle", defaultValue: "A pane is flagged once its combined process-tree memory crosses this many gigabytes."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(Int(memGuardrailThresholdGB.current))",
                    value: Binding(get: { memGuardrailThresholdGB.current }, set: { memGuardrailThresholdGB.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .disabled(!memGuardrailEnabled.current)
                .accessibilityIdentifier("SettingsTerminalMemoryGuardrailThresholdStepper")
            }
        }
        .task {
            let models: [any SettingObservationStarting] = [
                autoResume, codexQuiet, agentOrchestration, hibernation, idleSeconds, maxLive, rendererReclaim, rendererIdleSeconds, rendererMaxWarm, memGuardrailEnabled, memGuardrailThresholdGB
            ]
            models.forEach { $0.startObserving() }
        }
    }
}
