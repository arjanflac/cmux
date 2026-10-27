import CmuxSettings
import Foundation
import os

extension AppDelegate {
    /// Starts the one in-app scheduler only after stable workspace restoration is ready.
    func startAgentOrchestrationAfterRestore() {
        guard UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().terminal.agentOrchestration) else { return }
        Task { @MainActor in
            let runtime = TerminalController.shared.agentTaskRuntimeForControl()
            do {
                try await runtime.restore()
                _ = try await runtime.orchestrator()
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "cmux", category: "agent-orchestration")
                    .error("Orchestration recovery stopped: \(String(describing: error), privacy: .private)")
            }
        }
    }
}
