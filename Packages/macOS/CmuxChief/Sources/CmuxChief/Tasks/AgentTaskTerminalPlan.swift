import Foundation

/// Safe argv for a task view, using installed harnesses without modifying them.
public struct AgentTaskTerminalPlan: Sendable {
    /// Builds an interactive terminal command. Prompt text is supplied separately by the launcher.
    public init() {}

    /// Uses normal Codex resume or Claude Code with task-scoped supported hooks.
    public func arguments(record: AgentTaskRecord, request: AgentTaskRequest,
                          cmuxExecutable: String, cmuxSocket: String) throws -> [String] {
        guard let session = record.sessionID else { throw CocoaError(.fileReadUnknown) }
        if record.provider == .codex {
            var arguments = ["codex", "resume", session]
            if let model = request.model { arguments += ["--model", model] }
            return arguments
        }
        var hooks: [String: Any] = [:]
        for (hook, event) in [("SessionStart", "started"), ("Stop", "completed"), ("StopFailure", "failed"), ("SessionEnd", "ended")] {
            var command = [cmuxExecutable, "--socket", cmuxSocket, "task", "report", record.id.uuidString, "--event", event]
                .map(Self.shellWord).joined(separator: " ")
            if hook == "SessionStart" { command += " --owner-pid \"$PPID\"" }
            command += " >/dev/null"
            hooks[hook] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        }
        let settings = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys])
        var arguments = ["claude", "--session-id", session, "--permission-mode", "bypassPermissions", "--settings", String(decoding: settings, as: UTF8.self)]
        arguments += ["--append-system-prompt", AgentTaskContext.text(id: record.id, request: request,
                          command: [cmuxExecutable, "--socket", cmuxSocket, "task"])]
        if let model = request.model { arguments += ["--model", model] }
        if let effort = request.effort { arguments += ["--effort", effort] }
        return arguments
    }

    /// Describes current surface presence independently of the provider receipt.
    ///
    /// - Parameters:
    ///   - record: The saved task receipt.
    ///   - surfaceIsPresent: Whether the app currently has its mapped terminal surface.
    /// - Returns: A wire status; surface presence does not imply a connected provider.
    public func liveSurfaceStatus(record: AgentTaskRecord, surfaceIsPresent: Bool) -> String {
        guard record.presentation == .terminal else { return "headless" }
        guard record.surfaceID != nil else { return "not_created" }
        return surfaceIsPresent ? "surface_present" : "surface_missing"
    }

    /// Quotes a shell word without evaluating task text or command substitutions.
    public static func shellWord(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
