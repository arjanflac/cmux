import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// Provider evidence is scoped to the account the restoring CLI will actually exec.
struct AgentRestoreCodexEvidence {
    /// Independently verifies a saved resume as a view of the existing managed daemon.
    func managedFrontend(
        record: ControlSurfaceRestoreRecord, sessionID: String, effectiveHome: String?,
        frontendExecutable: String, enabled: Bool,
        verify: (CodexManagedDaemonAttachPlan) -> Bool = CodexManagedDaemonAttachProbe().verify
    ) -> CodexManagedDaemonAttachPlan? {
        guard enabled, record.kind == "codex", record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.checkpointID.flatMap(UUID.init(uuidString:)) == UUID(uuidString: sessionID),
              let cwd = record.workingDirectory ?? record.launchCommand?.workingDirectory,
              cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd),
              record.launchCommand?.externalLauncher == nil else { return nil }
        let capture = record.launchCommand.map { command in
            AgentLaunchCommand(launcher: command.launcher, externalLauncher: command.externalLauncher,
                executablePath: command.executablePath, arguments: command.arguments,
                workingDirectory: command.workingDirectory, environment: command.environment,
                verificationHome: command.verificationHome, capturedAt: command.capturedAt,
                source: command.source, launcherPrefix: command.launcherPrefix)
        }
        let request = AgentRestoreRequest(mode: .resumeAgent, kind: "codex", checkpointID: sessionID,
            source: record.source, workingDirectory: cwd, environment: record.environment,
            launchCommand: capture, preparedArguments: record.preparedArguments,
            preparedArgumentsWorkingDirectory: record.preparedArgumentsWorkingDirectory,
            observedPermissionMode: record.permissionMode)
        guard let invocation = AgentRestorePlanner(executableFileResolver: AgentRestoreExecutableFileResolver())
                .invocation(for: request, ambientEnvironment: ProcessInfo.processInfo.environment),
              let stock = CodexManagedDaemonAttachProbe().stockExecutable(for: invocation, home: NSHomeDirectory()),
              let effectiveHome,
              URL(fileURLWithPath: CodexRestoreAccount().home(environment: invocation.environment,
                workingDirectory: cwd, fallbackHome: NSHomeDirectory())).standardizedFileURL
                == URL(fileURLWithPath: effectiveHome).standardizedFileURL else { return nil }
        return CodexManagedDaemonAttachPlan.verified(invocation: invocation, sessionID: sessionID,
            frontendExecutable: frontendExecutable, stockExecutable: stock, workingDirectory: cwd,
            fallbackHome: NSHomeDirectory(), verify: verify)
    }

    func inspect(
        record: ControlSurfaceRestoreRecord,
        sessionID: String,
        effectiveHome: String?
    ) -> CodexWriterLockInspection? {
        guard record.kind == "codex", record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue else {
            return nil
        }
        let arguments = record.preparedArguments ?? record.launchCommand?.arguments ?? []
        // Remote app-server ownership cannot be inferred from a local lock.
        if CodexRestoreAccount().usesRemoteProvider(arguments: arguments) {
            return nil
        }
        // Same-build CLI supplies the final invocation account. A legacy caller
        // without that evidence must continue using complete process evidence.
        guard let effectiveHome, effectiveHome.hasPrefix("/") else { return nil }
        return CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: effectiveHome)
    }
}
