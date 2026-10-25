import Foundation

/// Explicit identities travel with managed work, rather than relying on the
/// shared daemon's environment (which belongs to its original launcher).
enum AgentTaskContext {
    static func text(id: UUID, request: AgentTaskRequest, command: [String]) -> String {
        let launch = (command + ["start", "--workspace", request.workspaceID.uuidString,
                                 "--cwd", request.workingDirectory.path, "--parent-task", id.uuidString])
            .map(AgentTaskTerminalPlan.shellWord).joined(separator: " ")
        return """
        This is cmux managed task \(id.uuidString) in existing workspace \(request.workspaceID.uuidString).
        If the user requests further delegation, use this native task command with an explicit provider and prompt:
        \(launch) --provider codex|claude [--model MODEL] --wait -- 'TASK'
        Use a different existing workspace ID and directory when explicitly delegating to a different project.
        Never infer task identity or destination from CMUX environment variables: the shared daemon may have inherited another terminal's environment.
        Tasks open terminal tabs without changing focus. Use --background only if the user explicitly requests headless work.
        The task receipt is for the first provider turn; ordinary follow-up conversation remains in its terminal or phone client.
        """
    }
}
