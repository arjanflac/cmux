import CmuxChief
import Foundation

/// Composes the native task domain with the shared daemon and terminal presenter.
@MainActor
final class NativeAgentTaskRuntime {
    let coordinator: AgentTaskCoordinator
    let backend: AgentManagedTaskBackend
    let host: NativeAgentTaskHost
    private var restoreTask: Task<Void, any Error>?
    private var notices: Task<Void, Never>?

    init() {
        let host = NativeAgentTaskHost()
        self.host = host
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path ?? "cmux"
        let socket = TerminalController.shared.currentSocketPathForRemoteRestore() ?? ""
        backend = AgentManagedTaskBackend(socketPath: codexHome + "/app-server-control/app-server-control.sock",
                                         taskCommand: [cli, "--socket", socket, "task"],
                                         cancelTerminal: { id in try await host.interrupt(id) })
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux/agent-tasks/" + (Bundle.main.bundleIdentifier ?? "cmux"))
        coordinator = AgentTaskCoordinator(backend: backend, repository: AgentTaskFileRepository(directory: root),
                                           present: { record, request in try host.open(record, request: request) })
        let events = coordinator.changes()
        notices = Task {
            for await record in events { host.notify(record) }
        }
    }

    func restore() async throws {
        if let restoreTask { return try await restoreTask.value }
        let task = Task { try await coordinator.restore() }
        restoreTask = task
        try await task.value
    }
}
