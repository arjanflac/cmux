import Foundation

extension CMUXCLI {
    /// A provider-owned stdio tool connection. It has no listener or global registration.
    func runAgentTaskMCP(_ args: [String], client: SocketClient) throws {
        guard args.count == 2, args[0] == "--scope-file" else { throw CLIError(message: Self.agentTaskUsage) }
        let scopePath = args[1]
        _ = try readAgentScopeFile(scopePath)
        let connectionID = UUID().uuidString
        var buffer = Data()
        while let bytes = try FileHandle.standardInput.read(upToCount: 4096), !bytes.isEmpty {
            buffer.append(bytes)
            guard buffer.count <= 262_144 else { throw CLIError(message: String(localized: "cli.agentTask.error.mcpRequestLimit", defaultValue: "MCP request exceeds the session limit.")) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                var requestID: Any = NSNull()
                do {
                    guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                        throw CLIError(message: String(localized: "cli.agentTask.error.expectedJSONRPC", defaultValue: "Expected a JSON-RPC request."))
                    }
                    guard let id = request["id"] else { continue }
                    requestID = id
                    let params = request["params"] as? [String: Any] ?? [:]
                    let result: [String: Any]
                    switch method {
                    case "initialize":
                        result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [String: Any]()],
                                  "serverInfo": ["name": "cmux-workers", "version": "1"]]
                    case "ping": result = [:]
                    case "tools/list": result = ["tools": [agentTaskMCPTool()]]
                    case "tools/call":
                        guard params["name"] as? String == "cmux_tasks", let arguments = params["arguments"] as? [String: Any],
                              let action = arguments["action"] as? String else { throw CLIError(message: String(localized: "cli.agentTask.error.unknownTool", defaultValue: "Unknown cmux tool.")) }
                        let mutations: Set<String> = ["start", "send", "cancel", "respond", "ack", "schedule.create", "schedule.pause", "schedule.resume", "schedule.cancel"]
                        let operation: String
                        if mutations.contains(action) {
                            guard let stable = arguments["request_id"] as? String, UUID(uuidString: stable) != nil else {
                                throw CLIError(message: String(localized: "cli.agentTask.error.stableRequestID", defaultValue: "A mutation requires a stable UUID request_id. Reuse it only when retrying the same action."))
                            }
                            operation = stable
                        } else { operation = connectionID + ":" + String(describing: id) }
                        let scope = try readAgentScopeFile(scopePath)
                        let envelope: [String: Any] = ["request_id": operation,
                            "caller_session_id": scope["session_id"] ?? NSNull(), "arguments": arguments]
                        do {
                            var response = try client.sendV2(method: "agent.task.bridge", params: ["scope": scope, "envelope": envelope], responseTimeout: 25)
                            guard response.removeValue(forKey: "_cmux_should_respond") as? Bool == true else { continue }
                            let failed = response.removeValue(forKey: "_cmux_tool_error") as? Bool == true
                            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                            result = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": failed]
                        } catch {
                            result = ["content": [["type": "text", "text": String(format: String(localized: "cli.agentTask.error.unconfirmedResult", defaultValue: "cmux operation did not return a confirmed result. Inspect its request_id before retrying: %@"), String(describing: error))]], "isError": true]
                        }
                    default:
                        try writeAgentMCP(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
                        continue
                    }
                    try writeAgentMCP(["jsonrpc": "2.0", "id": id, "result": result])
                } catch {
                    try writeAgentMCP(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32602, "message": String(describing: error)]])
                }
            }
        }
    }

    private func agentTaskMCPTool() -> [String: Any] {
        ["name": "cmux_tasks",
         "description": "Manage this cmux conversation's background workers, inbox and schedules. Mutations require a stable UUID request_id; reuse it only for an identical retry. Inspect uncertain work instead of resubmitting.",
         "inputSchema": ["type": "object", "required": ["action"], "properties": [
             "action": ["type": "string", "enum": ["start", "send", "read", "turns", "result", "wait", "cancel", "interactions", "respond", "workers", "inbox", "ack", "schedule.create", "schedule.list", "schedule.read", "schedule.pause", "schedule.resume", "schedule.cancel"]],
             "cursor": ["type": "string", "format": "uuid"],
             "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 20],
             "include_retired": ["type": "boolean", "default": false],
             "lifecycle": ["type": "string", "enum": ["persistent", "oneShot"]],
             "request_id": ["type": "string"], "task_id": ["type": "string"], "operation_id": ["type": "string"],
             "provider": ["type": "string", "enum": ["codex", "claude", "opencode"]],
             "prompt": ["type": "string"], "model": ["type": "string"], "effort": ["type": "string"],
             "cwd": ["type": "string"], "due_at": ["type": "string"], "target_task_id": ["type": "string"],
             "schedule_id": ["type": "string"], "time_zone": ["type": "string"],
             "misfire": ["type": "string", "enum": ["hold", "skip", "coalesceOne"]],
             "max_runs": ["type": "integer", "minimum": 1, "maximum": 100],
             "repeat_seconds": ["type": "integer", "minimum": 60], "event_id": ["type": "string"],
             "interaction_id": ["type": "string"], "response": ["type": "object"]], "additionalProperties": false]]
    }

    private func writeAgentMCP(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
