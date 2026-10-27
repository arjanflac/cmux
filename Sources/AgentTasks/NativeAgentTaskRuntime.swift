import CmuxChief
import CmuxSettings
import Foundation

/// Composes the native task domain with the shared daemon and terminal presenter.
@MainActor
final class NativeAgentTaskRuntime {
    let coordinator: AgentTaskCoordinator
    let backend: AgentManagedTaskBackend
    let host: NativeAgentTaskHost
    let toolRouter: AgentTaskToolRouter
    let rootDirectory: URL
    let turnRepository: AgentTaskFileTurnRepository
    private var orchestrationState: NativeAgentOrchestration?
    private var restoreTask: Task<Void, any Error>?
    private var observedTargets: [String: Set<UUID>] = [:]
    private var activityTask: Task<Void, Never>?
    private var notices: Task<Void, Never>?

    init() {
        let host = NativeAgentTaskHost()
        self.host = host
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux").path ?? "cmux"
        let socket = TerminalController.shared.currentSocketPathForRemoteRestore() ?? ""
        let toolRouter = AgentTaskToolRouter()
        self.toolRouter = toolRouter
        backend = AgentManagedTaskBackend(socketPath: codexHome + "/app-server-control/app-server-control.sock",
                                         taskCommand: [cli, "--socket", socket, "task"],
                                         cancelTerminal: { id in try await host.interrupt(id) }, toolRouter: toolRouter)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux/agent-tasks/" + (Bundle.main.bundleIdentifier ?? "cmux"))
        rootDirectory = root
        let turnRepository = AgentTaskFileTurnRepository(directory: root.appendingPathComponent("turns"))
        self.turnRepository = turnRepository
        coordinator = AgentTaskCoordinator(backend: backend, repository: AgentTaskFileRepository(directory: root),
                                           present: { record, request in try host.open(record, request: request) },
                                           reconnect: { record, request in try host.open(record, request: request, reconnectOnly: true) },
                                           turnRepository: turnRepository)
        let events = coordinator.changes()
        notices = Task {
            for await record in events {
                host.notify(record)
                if record.provider == .codex, let session = record.sessionID, UUID(uuidString: session) != nil {
                    if let workspaceID = self.workspaceID(for: record) { self.observe(session: session, workspaceID: workspaceID) }
                }
            }
        }
        Task { [weak self] in
            await toolRouter.install(enabled: { [weak self] in
                guard let self else { return false }
                return await self.orchestrationEnabled()
            }, handler: { [weak self] call in
                guard let self else { throw CocoaError(.userCancelled) }
                let service = try await self.orchestrator()
                return try await service.nativeTool(call)
            })
        }
    }

    func orchestrationEnabled() -> Bool {
        UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().terminal.agentOrchestration)
    }

    /// One app-owned control plane, with no service or provider process per task.
    func orchestrator() async throws -> NativeAgentOrchestration {
        if let orchestrationState { return orchestrationState }
        let state = try NativeAgentOrchestration(runtime: self, directory: rootDirectory)
        orchestrationState = state
        coordinator.setReceiptHandler { [weak state] record, _ in
            guard let state else { throw CocoaError(.userCancelled) }
            do { try await state.recordChanged(record) }
            catch { state.noteStorageFailure(error); throw error }
        }
        try await state.restore()
        return state
    }

    /// Saved runtime UUIDs are never guessed by title or directory after relaunch.
    func workspaceID(for record: AgentTaskRecord) -> UUID? {
        if let stable = record.workspaceStableID {
            return AppDelegate.shared?.mainWindowContexts.values.lazy.flatMap { $0.tabManager.tabs }
                .first { $0.stableId == stable && !$0.isRemoteWorkspace }?.id
        }
        return AppDelegate.shared?.workspaceFor(tabId: record.workspaceID)?.isRemoteWorkspace == false ? record.workspaceID : nil
    }

    /// Imports and manual command proposals do not admit daemon observations.
    nonisolated static func observedSession(_ binding: SurfaceResumeBindingSnapshot) -> String? {
        guard binding.kind == "codex", binding.isAgentHookBinding, binding.hasCompleteManagedSessionIdentity,
              let raw = binding.checkpointId, let id = UUID(uuidString: raw) else { return nil }
        return id.uuidString.lowercased()
    }

    /// Identity comes from verified per-surface bindings, never cwd, title or daemon environment.
    func observe(workspace: Workspace) {
        for binding in workspace.surfaceResumeBindingsByPanelId.values {
            if let session = Self.observedSession(binding) { observe(session: session, workspaceID: workspace.id) }
        }
    }

    private func applyActivity(_ activity: AgentSessionActivity) {
        let historical = observedTargets[activity.sessionID] ?? []
        let liveOwners = historical.filter { id in
            AppDelegate.shared?.workspaceFor(tabId: id)?.surfaceResumeBindingsByPanelId.values.contains {
                Self.observedSession($0) == activity.sessionID
            } == true
        }
        let taskOwners = Set(coordinator.records.values.filter {
            $0.provider == .codex && $0.sessionID == activity.sessionID
        }.compactMap { workspaceID(for: $0) })
        // A moved live view transfers ownership. A closed view retains its last
        // association when there is no live replacement elsewhere.
        let destinations = liveOwners.isEmpty ? historical.union(taskOwners) : Set(liveOwners).union(taskOwners)
        for id in historical.union(destinations) {
            guard let workspace = AppDelegate.shared?.workspaceFor(tabId: id), !workspace.isRemoteWorkspace else { continue }
            let previous = workspace.observedCodexActivityBySessionID[activity.sessionID]
            let next = destinations.contains(id) ? activity.phase.rawValue : nil
            guard previous != next else { continue }
            workspace.observedCodexActivityBySessionID[activity.sessionID] = next
            WorkspaceActivityReorderController.shared.observedSessionActivityChanged(workspaceId: id, previous: previous, current: next)
        }
    }

    private func observe(session: String, workspaceID: UUID) {
        guard AppDelegate.shared?.workspaceFor(tabId: workspaceID)?.isRemoteWorkspace == false else { return }
        observedTargets[session, default: []].insert(workspaceID)
        if activityTask == nil {
            activityTask = Task { [weak self, backend] in
                let stream = await backend.sessionActivityChanges()
                for await activity in stream { self?.applyActivity(activity) }
            }
        }
        Task { [weak self, backend] in
            await backend.observeSession(session)
            if let activity = await backend.sessionActivitySnapshot(session) { self?.applyActivity(activity) }
        }
    }

    func restore() async throws {
        if let restoreTask { return try await restoreTask.value }
        let task = Task { try await coordinator.restore() }
        restoreTask = task
        try await task.value
        for record in coordinator.records.values where record.provider == .codex {
            if let session = record.sessionID, let workspaceID = workspaceID(for: record) { observe(session: session, workspaceID: workspaceID) }
        }
    }
}
