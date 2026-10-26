import AppKit
import CmuxChief
import CmuxControlSocket
import CmuxFoundation
import Foundation

/// Presents managed tasks through the app's existing workspace/surface actions.
@MainActor
final class NativeAgentTaskHost {
    private var surfaces: [UUID: (workspace: UUID, surface: UUID, session: String)] = [:]
    private var lastNotice: [UUID: String] = [:]
    private var owners: [UUID: AgentPIDProcessIdentity] = [:]

    func open(_ record: AgentTaskRecord, request: AgentTaskRequest, reconnectOnly: Bool = false) throws -> UUID {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: record.workspaceID),
              !workspace.isRemoteWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId,
              let session = record.sessionID else { throw CocoaError(.fileNoSuchFile) }
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let cli = resources.appendingPathComponent("bin/cmux").path
        guard let socket = TerminalController.shared.currentSocketPathForRemoteRestore() else { throw CocoaError(.fileReadUnknown) }
        let arguments: [String]
        if reconnectOnly { arguments = [cli, "--socket", socket, "restore", "--surface"] }
        else { arguments = try AgentTaskTerminalPlan().arguments(record: record, request: request, cmuxExecutable: cli, cmuxSocket: socket) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-task-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let promptFile = directory.appendingPathComponent("prompt")
        let launcher = directory.appendingPathComponent("launch.sh")
        let quote = AgentTaskTerminalPlan.shellWord
        var script = "#!/bin/sh\n"
        if record.provider == .claude && !reconnectOnly {
            try Data(request.prompt.utf8).write(to: promptFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
            script += "prompt=$(cat \(quote(promptFile.path))) || exit 1\n"
        }
        script += "rm -f -- \(quote(promptFile.path)) \(quote(launcher.path))\nrmdir -- \(quote(directory.path))\nexec " + arguments.map(quote).joined(separator: " ")
        if reconnectOnly { script += " \"$CMUX_SURFACE_ID\"" }
        else if record.provider == .claude { script += " \"$prompt\"" }
        script += "\n"
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launcher.path)
        let routing = ControlRoutingSelectors(hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: record.workspaceID, surfaceID: nil, paneID: pane.id)
        let inputs = ControlSurfaceCreateInputs(typeRaw: "terminal", providerRaw: nil, rendererRaw: nil,
            urlRaw: nil, workingDirectory: record.workingDirectory.path,
            initialCommand: "/bin/sh " + quote(launcher.path), tmuxStartCommand: nil,
            remotePTYSessionID: nil, remoteContextRaw: "local",
            startupEnvironment: ["CMUX_COMPUTER_USE_MCP_DISABLED": "1", "CMUX_CODEX_HOOKS_DISABLED": "1", "CMUX_AGENT_TASK_ID": record.id.uuidString],
            requestedPaneID: pane.id, requestedFocus: false)
        let resolution = TerminalController.shared.withSocketCommandPolicy(
            commandKey: "surface.create", isV2: true, params: ["focus": false]
        ) { TerminalController.shared.controlSurfaceCreate(routing: routing, inputs: inputs) }
        guard case let .created(_, createdWorkspace, _, surfaceID, _) = resolution,
              createdWorkspace == record.workspaceID,
              let panel = workspace.terminalPanel(for: surfaceID),
              workspace.surfaceIdFromPanelId(surfaceID) != nil else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        workspace.setPanelCustomTitle(panelId: panel.id, title: record.title)
        guard workspace.setSurfaceResumeBinding(Self.resumeBinding(provider: record.provider,
                sessionID: session, cwd: record.workingDirectory.path, model: request.model, title: record.title),
                panelId: panel.id) else { throw CocoaError(.fileWriteUnknown) }
        surfaces[record.id] = (record.workspaceID, panel.id, session)
        return panel.id
    }

    /// Uses the existing trusted managed-agent contract with shell-free resume argv.
    nonisolated static func resumeBinding(provider: AgentTaskRequest.Provider, sessionID: String,
            cwd: String, model: String?, title: String) -> SurfaceResumeBindingSnapshot {
        var arguments = provider == .codex ? ["codex", "resume", sessionID]
            : ["claude", "--resume", sessionID, "--permission-mode", "bypassPermissions"]
        if let model { arguments += ["--model", model] }
        return SurfaceResumeBindingSnapshot(name: title, kind: provider.rawValue,
            command: arguments.map(AgentTaskTerminalPlan.shellWord).joined(separator: " "),
            cwd: cwd, checkpointId: sessionID, source: "agent-hook",
            environment: ["CMUX_COMPUTER_USE_MCP_DISABLED": "1", "CMUX_CODEX_HOOKS_DISABLED": "1"],
            launchCommand: .init(executablePath: arguments[0], arguments: arguments,
                workingDirectory: cwd, source: "cmux-managed-task"),
            permissionMode: provider == .claude ? "bypassPermissions" : nil, autoResume: true)
    }

    func interrupt(_ id: UUID) throws {
        guard let target = surfaces[id],
              let owner = owners[id], AgentPIDProcessIdentity(pid: owner.pid) == owner,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: target.workspace),
              let binding = workspace.surfaceResumeBindingsByPanelId[target.surface],
              binding.checkpointId == target.session,
              let terminal = workspace.panels[target.surface] as? TerminalPanel,
              terminal.surface.foregroundProcessID() == Int(owner.pid) else {
            throw CocoaError(.userCancelled)
        }
        // The current native binding must still be the task's Claude session.
        guard terminal.surface.sendKeyText("\u{03}") else { throw CocoaError(.fileWriteUnknown) }
    }

    func confirmOwner(_ id: UUID, session: String, pid: Int) {
        owners.removeValue(forKey: id)
        guard let target = surfaces[id], target.session == session,
              let processID = Int32(exactly: pid),
              let terminal = AppDelegate.shared?.workspaceFor(tabId: target.workspace)?.panels[target.surface] as? TerminalPanel,
              terminal.surface.foregroundProcessID() == pid,
              let identity = AgentPIDProcessIdentity(pid: processID) else { return }
        owners[id] = identity
    }

    func notify(_ record: AgentTaskRecord) {
        let attachmentFailed = record.detail?.hasPrefix("terminal_attachment_failed:") == true
        let noticeKey = attachmentFailed ? "terminal_attachment_failed" : record.phase.rawValue
        guard lastNotice[record.id] != noticeKey else { return }
        lastNotice[record.id] = noticeKey
        let title: String
        if attachmentFailed { title = String(localized: "agentTask.needsInput", defaultValue: "Task needs attention") }
        else { switch record.phase {
        case .completed: title = String(localized: "agentTask.completed", defaultValue: "Task completed")
        case .needsInput: title = String(localized: "agentTask.needsInput", defaultValue: "Task needs attention")
        case .failed: title = String(localized: "agentTask.failed", defaultValue: "Task failed")
        case .disconnected: title = String(localized: "agentTask.disconnected", defaultValue: "Task connection lost")
        default: return
        } }
        TerminalNotificationStore.shared.addNotification(tabId: record.workspaceID, surfaceId: record.surfaceID,
            title: title, subtitle: record.provider.rawValue, body: attachmentFailed ? record.title + " — cmux task attach " + record.id.uuidString : record.title,
            correlationKey: "agent-task-" + record.id.uuidString + "-" + noticeKey)
    }
}
