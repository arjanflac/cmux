import Darwin
import Foundation

extension CMUXCLI {
    /// Explicit orchestration commands never discover their caller from a daemon environment.
    func runAgentOrchestratorCommand(_ args: [String], client: SocketClient, windowOverride: String?) throws {
        let usage = Self.agentTaskUsage
        let command = args[0]
        if command == "mcp" {
            try runAgentTaskMCP(Array(args.dropFirst()), client: client)
            return
        }
        if command == "bridge" {
            guard args.count == 3, args[1] == "--scope-file" else { throw CLIError(message: usage) }
            let credential = try readAgentScopeFile(args[2])
            let request = try readOrchestrationJSON(.standardInput)
            let result = try client.sendV2(method: "agent.task.bridge", params: ["scope": credential, "envelope": request], responseTimeout: 25)
            try printOrchestrationJSON(result)
            return
        }
        var params: [String: Any] = [:]
        var index = 1
        var method = "agent.task." + command
        var waits = false
        var message: String?
        var promptFile: String?
        if command == "schedule" {
            guard index < args.count else { throw CLIError(message: usage) }
            params["schedule_action"] = args[index]; index += 1
            method = "agent.task.schedule"
            if index < args.count, !args[index].hasPrefix("--") {
                params["schedule_id"] = args[index]; index += 1
            }
        } else if command != "panel" {
            guard index < args.count else { throw CLIError(message: usage) }
            let key = ["result", "wait-turn"].contains(command) ? "operation_id" : "task_id"
            params[key] = args[index]; index += 1
            if command == "ack" {
                guard index < args.count else { throw CLIError(message: usage) }
                params["event_id"] = args[index]; index += 1
            }
        }
        while index < args.count {
            let flag = args[index]
            if flag == "--" { message = args.dropFirst(index + 1).joined(separator: " "); break }
            if flag == "--wait" { waits = true; index += 1; continue }
            guard flag.hasPrefix("--"), index + 1 < args.count else { throw CLIError(message: usage) }
            let value = args[index + 1]; index += 2
            switch flag {
            case "--workspace": params["workspace_id"] = try resolveWorkspaceId(value, client: client, windowHandle: windowOverride)
            case "--surface":
                guard let surface = UUID(uuidString: value) else { throw CLIError(message: usage) }
                params["surface_id"] = surface.uuidString
            case "--prompt-file": promptFile = value
            case "--request-id": params["request_id"] = value
            case "--owner": params["owner_task_id"] = value
            case "--target": params["target_task_id"] = value
            case "--provider": params["provider"] = value
            case "--cwd": params["cwd"] = resolvePath(value)
            case "--model": params["model"] = value
            case "--effort": params["effort"] = value
            case "--permission-mode": params["permission_mode"] = value
            case "--at": params["due_at"] = value
            case "--expires": params["expires_at"] = value
            case "--timezone": params["time_zone"] = value
            case "--misfire": params["misfire"] = value
            case "--repeat-seconds": params["repeat_seconds"] = Int(value)
            case "--max-runs": params["max_runs"] = Int(value)
            case "--after": params["after_sequence"] = Int64(value)
            case "--session": params["session_id"] = value
            case "--frontend-pid": params["frontend_pid"] = Int(value)
            case "--invocation": params["invocation_id"] = value
            case "--interaction": params["interaction_id"] = value
            case "--response-file":
                let file = value == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: resolvePath(value)))
                defer { if value != "-" { try? file.close() } }
                params["response"] = try readOrchestrationJSON(file)
            default: throw CLIError(message: usage)
            }
        }
        if let promptFile {
            guard message == nil else { throw CLIError(message: usage) }
            let file = promptFile == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: resolvePath(promptFile)))
            defer { if promptFile != "-" { try? file.close() } }
            let data = try file.read(upToCount: 200_001) ?? Data()
            guard data.count <= 200_000, let text = String(data: data, encoding: .utf8) else { throw CLIError(message: usage) }
            message = text
        }
        if let message { params["prompt"] = message }
        let mutation = ["send", "ack", "respond"].contains(command)
            || (command == "schedule" && ["create", "pause", "resume", "cancel"].contains(params["schedule_action"] as? String ?? ""))
        if mutation {
            params["request_id"] = params["request_id"] ?? UUID().uuidString
        }
        var result = try client.sendV2(method: method, params: params, responseTimeout: 25)
        if waits, let operation = result["operationID"] as? String ?? result["id"] as? String {
            while !["completed", "cancelled", "failed", "disconnected", "uncertain", "needsInput"].contains(result["phase"] as? String ?? "") {
                result = try client.sendV2(method: "agent.task.wait-turn", params: ["operation_id": operation], responseTimeout: 25)
            }
        }
        try printOrchestrationJSON(result)
    }

    /// Reads a transport-only capability; it is never placed in a prompt or command argument.
    func readAgentScopeFile(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: resolvePath(path))
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_size <= 16_384 else {
            throw CLIError(message: String(localized: "cli.agentTask.error.invalidOrExpiredScope", defaultValue: "Invalid or expired cmux session scope."))
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CLIError(message: String(localized: "cli.agentTask.error.invalidScope", defaultValue: "Invalid cmux session scope.")) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        return try readOrchestrationJSON(file)
    }

    func readOrchestrationJSON(_ file: FileHandle) throws -> [String: Any] {
        let data = try file.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: String(localized: "cli.agentTask.error.expectedJSONObject", defaultValue: "Expected one bounded JSON object."))
        }
        return value
    }

    func printOrchestrationJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
