import CmuxChief
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Local-only task commands. Remote relays cannot launch local agent work.
    nonisolated func agentTaskResponse(_ request: ControlRequest) async -> String {
        let result: V2CallResult
        do {
            guard request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] == nil else {
                throw CocoaError(.fileReadNoPermission)
            }
            let params = request.params.mapValues(\.foundationObject)
            let runtime = await agentTaskRuntimeForControl()
            try await runtime.restore()
            switch request.method {
            case "agent.task.start":
                guard let provider = (params["provider"] as? String).flatMap(AgentTaskRequest.Provider.init(rawValue:)),
                      let prompt = params["prompt"] as? String, prompt.utf8.count <= 200_000,
                      let workspaceID = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
                      let cwd = params["cwd"] as? String, cwd.hasPrefix("/"),
                      await MainActor.run(body: { AppDelegate.shared?.workspaceFor(tabId: workspaceID)?.isRemoteWorkspace == false }) else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                if let parent = params["parent_task_id"] as? String, UUID(uuidString: parent) == nil {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                let task = AgentTaskRequest(provider: provider, prompt: prompt, workspaceID: workspaceID,
                    workingDirectory: URL(fileURLWithPath: cwd), model: params["model"] as? String,
                    effort: params["effort"] as? String,
                    presentation: (params["background"] as? Bool) == true ? .background : .terminal,
                    parentTaskID: (params["parent_task_id"] as? String).flatMap(UUID.init(uuidString:)))
                let record = try await runtime.coordinator.start(task)
                result = .ok(try await taskPayload(record))
            case "agent.task.list":
                let records = await runtime.coordinator.records.values.sorted { $0.createdAt > $1.createdAt }
                var rows: [[String: Any]] = []
                for record in records.prefix(50) {
                    var row = try await taskPayload(record)
                    row.removeValue(forKey: "result")
                    rows.append(row)
                }
                result = .ok(["tasks": rows, "has_more": records.count > 50])
            case "agent.task.read", "agent.task.wait", "agent.task.cancel", "agent.task.report":
                guard let id = (params["task_id"] as? String).flatMap(UUID.init(uuidString:)),
                      let record = try await runtime.coordinator.record(id) else { throw CocoaError(.fileNoSuchFile) }
                if request.method == "agent.task.cancel" { try await runtime.coordinator.cancel(id) }
                if request.method == "agent.task.wait" { _ = try await runtime.coordinator.wait(id) }
                if request.method == "agent.task.report", !record.phase.isFinished {
                    guard let session = params["session_id"] as? String, let event = params["event"] as? String else {
                        throw CocoaError(.validationMissingMandatoryProperty)
                    }
                    if event == "started", let pid = params["owner_pid"] as? Int {
                        await runtime.host.confirmOwner(id, session: session, pid: pid)
                    }
                    try await runtime.backend.reportClaude(id: id, session: session, event: event, text: params["text"] as? String)
                }
                let latest = try await runtime.coordinator.record(id) ?? record
                result = .ok(try await taskPayload(latest))
            default: result = .err(code: "method_not_found", message: String(localized: "cli.agentTask.unknownMethod", defaultValue: "Unknown task method"), data: nil)
            }
        } catch {
            result = .err(code: "task_error", message: String(describing: error), data: nil)
        }
        return Self.v2Encoder.response(id: request.id, Self.controlCallResult(fromLegacy: result))
    }

    private func agentTaskRuntimeForControl() -> NativeAgentTaskRuntime {
        if let agentTaskRuntime { return agentTaskRuntime }
        let runtime = NativeAgentTaskRuntime()
        agentTaskRuntime = runtime
        return runtime
    }

    /// Runtime diagnostics never rewrite a saved receipt or retry accepted work.
    private nonisolated func taskPayload(_ record: AgentTaskRecord) async throws -> [String: Any] {
        let present = await MainActor.run {
            guard let surface = record.surfaceID,
                  let workspace = AppDelegate.shared?.workspaceFor(tabId: record.workspaceID) else { return false }
            return workspace.terminalPanel(for: surface) != nil && workspace.surfaceIdFromPanelId(surface) != nil
        }
        var payload = try Self.taskJSON(record)
        payload["live_surface_status"] = AgentTaskTerminalPlan().liveSurfaceStatus(record: record, surfaceIsPresent: present)
        return payload
    }

    private nonisolated static func taskJSON(_ record: AgentTaskRecord) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any] ?? [:]
    }
}
