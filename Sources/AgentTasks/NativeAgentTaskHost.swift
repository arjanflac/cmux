import AppKit
import CmuxChief
import CmuxFoundation
import Foundation

/// Presents managed tasks through the app's existing workspace/surface actions.
@MainActor
final class NativeAgentTaskHost {
    private var surfaces: [UUID: (workspace: UUID, surface: UUID, session: String)] = [:]
    private var lastNotice: [UUID: AgentTaskRecord.Phase] = [:]
    private var owners: [UUID: AgentPIDProcessIdentity] = [:]

    func open(_ record: AgentTaskRecord, request: AgentTaskRequest) throws -> UUID {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: record.workspaceID),
              !workspace.isRemoteWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId,
              let session = record.sessionID else { throw CocoaError(.fileNoSuchFile) }
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let cli = resources.appendingPathComponent("bin/cmux").path
        guard let socket = TerminalController.shared.currentSocketPathForRemoteRestore() else { throw CocoaError(.fileReadUnknown) }
        let arguments = try AgentTaskTerminalPlan().arguments(record: record, request: request, cmuxExecutable: cli, cmuxSocket: socket)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-task-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let promptFile = directory.appendingPathComponent("prompt")
        let launcher = directory.appendingPathComponent("launch.sh")
        let quote = AgentTaskTerminalPlan.shellWord
        var script = "#!/bin/sh\n"
        if record.provider == .claude {
            try Data(request.prompt.utf8).write(to: promptFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
            script += "prompt=$(cat \(quote(promptFile.path))) || exit 1\n"
        }
        script += "rm -f -- \(quote(promptFile.path)) \(quote(launcher.path))\nrmdir -- \(quote(directory.path))\nexec " + arguments.map(quote).joined(separator: " ")
        if record.provider == .claude { script += " \"$prompt\"" }
        script += "\n"
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launcher.path)
        guard let panel = workspace.newTerminalSurface(inPane: pane, focus: false,
                workingDirectory: record.workingDirectory.path,
                initialCommand: "/bin/sh " + quote(launcher.path),
                startupEnvironment: ["CMUX_COMPUTER_USE_MCP_DISABLED": "1", "CMUX_CODEX_HOOKS_DISABLED": "1",
                                     "CMUX_AGENT_TASK_ID": record.id.uuidString],
                inheritStartupWork: false) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        workspace.setPanelCustomTitle(panelId: panel.id, title: record.title)
        var resume = record.provider == .codex ? ["codex", "resume", session] : ["claude", "--resume", session, "--permission-mode", "bypassPermissions"]
        if let model = request.model { resume += ["--model", model] }
        workspace.setSurfaceResumeBinding(SurfaceResumeBindingSnapshot(name: record.title,
            kind: record.provider.rawValue, command: "cd -- " + quote(record.workingDirectory.path) + " && " + resume.map(quote).joined(separator: " "),
            cwd: record.workingDirectory.path, checkpointId: session, source: "cmux-managed-task",
            environment: ["CMUX_COMPUTER_USE_MCP_DISABLED": "1", "CMUX_CODEX_HOOKS_DISABLED": "1"],
            permissionMode: record.provider == .claude ? "bypassPermissions" : nil, autoResume: true), panelId: panel.id)
        surfaces[record.id] = (record.workspaceID, panel.id, session)
        return panel.id
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
        guard lastNotice[record.id] != record.phase else { return }
        lastNotice[record.id] = record.phase
        let title: String
        switch record.phase {
        case .completed: title = String(localized: "agentTask.completed", defaultValue: "Task completed")
        case .needsInput: title = String(localized: "agentTask.needsInput", defaultValue: "Task needs attention")
        case .failed: title = String(localized: "agentTask.failed", defaultValue: "Task failed")
        case .disconnected: title = String(localized: "agentTask.disconnected", defaultValue: "Task connection lost")
        default: return
        }
        TerminalNotificationStore.shared.addNotification(tabId: record.workspaceID, surfaceId: record.surfaceID,
            title: title, subtitle: record.provider.rawValue, body: record.title,
            correlationKey: "agent-task-" + record.id.uuidString + "-" + record.phase.rawValue)
    }
}
