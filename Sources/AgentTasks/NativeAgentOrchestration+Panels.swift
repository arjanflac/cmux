import CmuxChief
import CmuxFoundation
import Foundation

extension NativeAgentOrchestration {
    /// The broker checks live process generation, executable and current selected chat.
    func verifyPanel(_ panel: NativeAgentTaskPanel) -> Bool {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceID), !workspace.isRemoteWorkspace,
              let terminal = workspace.terminalPanel(for: panel.surfaceID),
              terminal.surface.foregroundProcessID() == Int(panel.process.pid),
              AgentPIDProcessIdentity(pid: panel.process.pid) == panel.process,
              let binding = workspace.surfaceResumeBindingsByPanelId[panel.surfaceID],
              NativeAgentTaskRuntime.observedSession(binding) == panel.sessionID,
              let process = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: Int(panel.process.pid), expectedIdentity: panel.process),
              let executable = process.arguments.first,
              let expected = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-codex-quiet"),
              URL(fileURLWithPath: executable).standardizedFileURL == expected.standardizedFileURL,
              process.environment["CMUX_CODEX_INVOCATION_ID"] == panel.invocationID,
              ["0", "1"].contains(process.environment["CMUX_ORCHESTRATOR_ENABLED"] ?? "") else { return false }
        return true
    }

    func panel(_ params: [String: Any]) async throws -> Data {
        guard let workspaceID = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              let surfaceID = (params["surface_id"] as? String).flatMap(UUID.init(uuidString:)),
              let session = params["session_id"] as? String, UUID(uuidString: session) != nil,
              let pid = params["frontend_pid"] as? Int, let processID = Int32(exactly: pid), processID > 0,
              let process = AgentPIDProcessIdentity(pid: processID),
              let invocation = params["invocation_id"] as? String, UUID(uuidString: invocation) != nil,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceID) else { throw CocoaError(.fileReadNoPermission) }
        // Legacy first-turn receipts can remain disconnected after an app restart.
        // A proven interactive view gets its own controller enrollment; don't rewrite
        // that historical receipt or inherit its uncertainty as the user's new turn.
        let existing = runtime.coordinator.records.values.first {
            $0.provider == .codex && $0.sessionID == session && $0.latestOperationID != nil
                && $0.workspaceStableID == workspace.stableId
        }
        let ownerID = existing?.id ?? identity("cmux-enrolled:codex:" + workspace.stableId.uuidString + ":" + session)
        let generation = "task:" + ownerID.uuidString + ":" + authority.epoch.uuidString
        var registration = NativeAgentTaskPanel(id: identity(surfaceID.uuidString + ":" + invocation),
            workspaceID: workspaceID, surfaceID: surfaceID, ownerTaskID: ownerID, sessionID: session,
            process: process, invocationID: invocation, generation: generation, paths: nil, renewedAt: .distantPast)
        guard verifyPanel(registration) else { throw CocoaError(.fileReadNoPermission) }
        if existing == nil {
            let binding = workspace.surfaceResumeBindingsByPanelId[surfaceID]
            let cwd = binding?.cwd ?? workspace.currentDirectory
            let request = AgentTaskRequest(provider: .codex, prompt: "cmux conversation", workspaceID: workspaceID,
                workingDirectory: URL(fileURLWithPath: cwd), presentation: .background, workspaceStableID: workspace.stableId)
            _ = try await runtime.coordinator.enrollSession(request, sessionID: session, id: ownerID)
        }
        let capability = try await issueScope(ownerID: ownerID, generation: generation)
        // Authority may have suspended; recheck the current process/chat immediately before issuance.
        guard verifyPanel(registration) else { throw CocoaError(.fileReadNoPermission) }
        let scopeData = try data(["version": 1, "registration_id": registration.id.uuidString,
            "owner_task_id": ownerID.uuidString, "session_id": session, "binding_generation": generation,
            "token": capability.token])
        let snapshot = try await snapshotData(registration)
        let paths = try await panelsStore.put(registration.id, scope: scopeData, snapshot: snapshot)
        registration.paths = (paths.snapshot, paths.scope)
        registration.renewedAt = Date()
        panels[registration.id] = registration
        await armTimer()
        return try data(["snapshot_path": paths.snapshot.path, "scope_file": paths.scope.path])
    }

    func issueScope(ownerID: UUID, generation: String, depth: Int = 0) async throws -> AgentTaskScopeGrant {
        guard depth <= 4 else { throw CocoaError(.fileReadNoPermission) }
        guard let owner = try await runtime.coordinator.record(ownerID), let session = owner.sessionID,
              let workspace = owner.workspaceStableID else { throw CocoaError(.fileReadNoPermission) }
        // Legacy completed fixtures are not silently adopted into a new control lineage.
        let targets = runtime.coordinator.childTaskIDs(of: ownerID)
        var lifetime: TimeInterval = 8 * 60 * 60
        if let parent = owner.parentTaskID {
            let parentGeneration = "task:" + parent.uuidString + ":" + authority.epoch.uuidString
            let parentCapability = try await issueScope(ownerID: parent, generation: parentGeneration, depth: depth + 1)
            _ = try await authority.allowChild(owner: parentCapability.scope, newChildID: ownerID)
            lifetime = min(lifetime, parentCapability.scope.expiresAt.timeIntervalSinceNow - 1)
        }
        return try await authority.issue(ownerTaskID: ownerID, providerSessionID: session,
            workspaceStableID: workspace, bindingGeneration: generation,
            allowedOperations: Set(AgentTaskScopeOperation.allCases), allowedTargets: targets,
            lifetime: lifetime, parentTaskID: owner.parentTaskID)
    }

    func snapshotData(_ panel: NativeAgentTaskPanel) async throws -> Data {
        let children = runtime.coordinator.records.values.filter { $0.parentTaskID == panel.ownerTaskID }
        let unread = try await journal.unreadInboxCount(ownerTaskID: panel.ownerTaskID)
        let now = Date().timeIntervalSince1970
        return try data(["version": 1, "session_id": panel.sessionID, "frontend_pid": Int(panel.process.pid),
            "invocation_id": panel.invocationID, "updated_at": now, "expires_at": now + 60,
            "running": children.filter { $0.phase == .running || $0.phase == .starting }.count,
            "needs_input": children.filter { $0.phase == .needsInput }.count,
            "unread": unread,
            "disconnected": children.filter { $0.phase == .disconnected }.count])
    }

    func refreshPanels() async throws {
        for id in Array(panels.keys) {
            guard var panel = panels[id] else { continue }
            guard verifyPanel(panel) else {
                panels.removeValue(forKey: id)
                try await panelsStore.remove(id)
                continue
            }
            if panel.renewedAt.timeIntervalSinceNow < -20 * 60 {
                let capability = try await issueScope(ownerID: panel.ownerTaskID, generation: panel.generation)
                let scope = try data(["version": 1, "registration_id": panel.id.uuidString,
                    "owner_task_id": panel.ownerTaskID.uuidString, "session_id": panel.sessionID,
                    "binding_generation": panel.generation, "token": capability.token])
                let snapshot = try await snapshotData(panel)
                _ = try await panelsStore.put(id, scope: scope, snapshot: snapshot)
                panel.renewedAt = Date(); panels[id] = panel
            } else {
                let snapshot = try await snapshotData(panel)
                try await panelsStore.update(id, snapshot: snapshot)
            }
        }
    }

    func bridge(_ params: [String: Any]) async throws -> Data {
        guard let credential = params["scope"] as? [String: Any],
              let token = credential["token"] as? String,
              let registrationID = (credential["registration_id"] as? String).flatMap(UUID.init(uuidString:)),
              let registration = panels[registrationID], verifyPanel(registration),
              let envelope = params["envelope"] as? [String: Any],
              envelope["caller_session_id"] as? String == registration.sessionID,
              let rawArgs = envelope["arguments"] as? [String: Any] else {
            throw CocoaError(.fileReadNoPermission)
        }
        let args = normalize(rawArgs)
        let scope = try await authority.validate(token: token, callerSessionID: registration.sessionID,
            bindingGeneration: registration.generation, operation: .read)
        guard verifyPanel(registration) else { throw CocoaError(.fileReadNoPermission) }
        let caller = "panel:" + registration.id.uuidString
        let key = registration.sessionID + ":" + (envelope["provider_turn_id"] as? String ?? "") + ":" + (envelope["request_id"] as? String ?? "")
        let responds = claimResponse(key, caller: caller)
        return try await toolReply(envelope, arguments: args, scope: scope, responds: responds)
    }

    func claimResponse(_ key: String, caller: String) -> Bool {
        if let existing = responseOwners[key] { return existing == caller }
        guard responseOwners.count < 10_000 else { return false }
        responseOwners[key] = caller
        return true
    }

    func operation(for action: String) -> AgentTaskScopeOperation {
        if action == "start" { return .createChild }
        if action == "send" || action.hasPrefix("schedule.") || action == "respond" { return .send }
        if action == "cancel" { return .cancel }
        if action == "interactions" { return .inspect }
        return .read
    }

    func targetID(_ args: [String: Any]) -> UUID? {
        (args["task_id"] as? String ?? args["target_task_id"] as? String).flatMap(UUID.init(uuidString:))
    }
}
