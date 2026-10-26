import Foundation

extension CMUXCLI {
    static var agentTaskUsage: String {
        let syntax = """
        cmux task start --provider codex|claude --workspace <id|ref> --cwd <dir>
                        [--model <id>] [--effort <level>] [--parent-task <id>]
                        [--background] [--prompt-file <path|->] [--wait] -- <task>
        cmux task read|wait|cancel <task-id>
        cmux task attach <task-id> [--workspace <id|ref>]
        cmux task list


        """
        return syntax + "\n" + String(localized: "cli.agentTask.help", defaultValue: "Tasks open terminal tabs in an existing workspace. Use --background only for an explicitly requested headless task. Use --wait to return its result.")
    }

    func runAgentTaskCommand(_ args: [String], client: SocketClient, windowOverride: String?) throws {
        let usage = Self.agentTaskUsage
        let options = args.prefix(while: { $0 != "--" })
        guard let command = args.first, !options.contains("--help") else { print(usage); return }
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
                case "--prompt-file": promptFile = value
                default: throw CLIError(message: usage)
                }
                index += 2
            }
            guard let target = workspace else {
                throw CLIError(message: String(localized: "cli.agentTask.workspace", defaultValue: "Specify the existing target --workspace; a focused project is never guessed."))
            }
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
            while !["completed", "cancelled", "failed", "disconnected"].contains(result["phase"] as? String ?? "") {
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
