import Foundation

extension CMUXCLI {
    static var agentTaskUsage: String {
        let syntax = """
        cmux task start --provider codex|claude|opencode --workspace <id|ref> --cwd <dir>
                        [--model <id>] [--effort <level>] [--parent-task <id>]
                        [--background|--terminal] [--request-id <uuid>]
                        [--permission-mode <mode>] [--lifecycle persistent|oneShot] [--prompt-file <path|->] [--wait] -- <task>
        cmux task read|wait|cancel <task-id>
        cmux task attach <task-id> [--workspace <id|ref>]
        cmux task list
        cmux task workers --owner <task-id> [--cursor <uuid>] [--limit <1-50>] [--include-retired]
        cmux task send <task-id> [--request-id <uuid>] [--prompt-file <path|->] [--wait] -- <message>
        cmux task turns <task-id>
        cmux task result|wait-turn <operation-id>
        cmux task inbox <parent-task-id> [--after <sequence>]
        cmux task ack <parent-task-id> <event-id>
        cmux task schedule create --owner <task-id> --at <ISO8601> [--request-id <uuid>]
                                 [--target <task-id> | --provider codex|claude|opencode
                                  --workspace <id|ref> --cwd <dir> [--model <id>] [--effort <level>]
                                  [--permission-mode <mode>] [--lifecycle persistent|oneShot]]
                                 [--timezone <IANA-zone>] [--expires <ISO8601>]
                                 [--misfire hold|skip|coalesceOne] [--repeat-seconds <seconds>]
                                 [--max-runs <limit>] [--prompt-file <path|->] -- <message>
        cmux task schedule list --owner <task-id>
        cmux task schedule read|pause|resume|cancel <schedule-id> --owner <task-id>
        """
        return syntax + "\n\n" + [
            String(localized: "cli.agentTask.help", defaultValue: "Tasks start in the background by default (--background). Use --terminal for a visible initial Codex turn; Claude and OpenCode use background workers and can attach after becoming idle. Use attach to open a task's terminal in an existing workspace."),
            String(localized: "cli.agentTask.help.turns", defaultValue: "Use send for a follow-up. Keep a stable --request-id UUID for each action; reuse it only to retry that same action. --wait also returns when input is needed (needsInput) or the provider disconnects (disconnected). Use turns, result and wait-turn to inspect turns; use inbox and ack to receive and acknowledge child-task events."),
            String(localized: "cli.agentTask.help.schedules", defaultValue: "Schedules dispatch only while cmux is open, with no daemon or global hooks. Missed runs are held by default (--misfire hold). --at and --expires require ISO 8601 timestamps with an explicit offset, for example 2026-10-26T09:00:00-07:00 or 2026-10-26T16:00:00Z. --timezone supplies the schedule's IANA time zone. Omit --target and --provider to send to the owner.")
        ].joined(separator: "\n\n")
    }

    func runAgentTaskCommand(_ args: [String], client: SocketClient, windowOverride: String?) throws {
        let usage = Self.agentTaskUsage
        let options = args.prefix(while: { $0 != "--" })
        guard let command = args.first, !options.contains("--help") else { print(usage); return }
        if ["send", "turns", "result", "wait-turn", "workers", "inbox", "ack", "schedule", "panel", "bridge", "interactions", "respond", "mcp"].contains(command) {
            try runAgentOrchestratorCommand(args, client: client, windowOverride: windowOverride)
            return
        }
        var params: [String: Any] = [:]
        var wait = command == "wait"
        let method: String
        if command == "start" {
            method = "agent.task.start"
            var workspace: String?, promptFile: String?, prompt: String?
            var index = 1
            while index < args.count {
                let arg = args[index]
                if arg == "--" { prompt = args.dropFirst(index + 1).joined(separator: " "); break }
                if arg == "--background" { params["background"] = true; index += 1; continue }
                if arg == "--terminal" { params["background"] = false; index += 1; continue }
                if arg == "--wait" { wait = true; index += 1; continue }
                guard index + 1 < args.count else { throw CLIError(message: usage) }
                let value = args[index + 1]
                switch arg {
                case "--workspace": workspace = value
                case "--provider": params["provider"] = value
                case "--cwd": params["cwd"] = resolvePath(value)
                case "--model": params["model"] = value
                case "--effort": params["effort"] = value
                case "--parent-task": params["parent_task_id"] = value
                case "--request-id": params["request_id"] = value
                case "--permission-mode": params["permission_mode"] = value
                case "--lifecycle": params["lifecycle"] = value
                case "--prompt-file": promptFile = value
                default: throw CLIError(message: usage)
                }
                index += 2
            }
            guard let target = workspace else {
                throw CLIError(message: String(localized: "cli.agentTask.workspace", defaultValue: "Specify the existing target --workspace; a focused project is never guessed."))
            }
            params["request_id"] = params["request_id"] ?? UUID().uuidString
            params["background"] = params["background"] ?? true
            params["workspace_id"] = try resolveWorkspaceId(target, client: client, windowHandle: windowOverride)
            params["provider"] = params["provider"] ?? "codex"
            params["cwd"] = params["cwd"] ?? FileManager.default.currentDirectoryPath
            if let promptFile {
                guard prompt == nil else { throw CLIError(message: String(localized: "cli.agentTask.prompt", defaultValue: "Give one prompt source.")) }
                let data: Data
                let input: FileHandle
                if promptFile == "-" { input = .standardInput }
                else { input = try FileHandle(forReadingFrom: URL(fileURLWithPath: resolvePath(promptFile))) }
                defer { if promptFile != "-" { try? input.close() } }
                data = try readAgentTaskInput(input, maximum: 200_000, usage: usage)
                prompt = String(decoding: data, as: UTF8.self)
            }
            guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError(message: usage) }
            params["prompt"] = prompt
        } else if command == "attach", args.count == 2 || args.count == 4 {
            method = "agent.task.attach"
            params["task_id"] = args[1]
            if args.count == 4 {
                guard args[2] == "--workspace" else { throw CLIError(message: usage) }
                params["workspace_id"] = try resolveWorkspaceId(args[3], client: client, windowHandle: windowOverride)
            }
        } else if command == "list" { method = "agent.task.list" }
        else if ["read", "wait", "cancel", "report"].contains(command), args.count >= 2 {
            method = command == "wait" ? "agent.task.read" : "agent.task." + command
            params["task_id"] = args[1]
            if command == "report" {
                guard let marker = args.firstIndex(of: "--event"), marker + 1 < args.count else { throw CLIError(message: usage) }
                let payload = try JSONSerialization.jsonObject(with: readAgentTaskInput(.standardInput, maximum: 2_000_000, usage: usage)) as? [String: Any] ?? [:]
                params["event"] = args[marker + 1]
                if let owner = args.firstIndex(of: "--owner-pid"), owner + 1 < args.count {
                    params["owner_pid"] = Int(args[owner + 1])
                }
                params["session_id"] = payload["session_id"]
                params["text"] = payload["last_assistant_message"] ?? payload["error_details"] ?? payload["error"]
            }
        } else { throw CLIError(message: usage) }
        var result = try client.sendV2(method: method, params: params)
        if wait, let id = result["id"] as? String {
            // Native event waits avoid a per-task polling worker.
            while !["completed", "cancelled", "failed", "disconnected", "needsInput"].contains(result["phase"] as? String ?? "") {
                result = try client.sendV2(method: "agent.task.wait", params: ["task_id": id], responseTimeout: 20)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
        if wait, ["failed", "cancelled", "disconnected"].contains(result["phase"] as? String ?? "") { throw CLIError(message: String(localized: "cli.agentTask.unsuccessful", defaultValue: "Task did not complete successfully.")) }
    }

    private func readAgentTaskInput(_ input: FileHandle, maximum: Int, usage: String) throws -> Data {
        var result = Data()
        while let chunk = try input.read(upToCount: min(65_536, maximum + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= maximum else { throw CLIError(message: usage) }
        }
        return result
    }

}
