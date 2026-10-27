import Foundation

/// A verified view-only restore through cmux's bundled, daemon-only Codex frontend.
///
/// This plan never authorizes the stock CLI to ignore a writer lock. Consumers must
/// execute ``frontendExecutable`` directly, reverify immediately before exec, and
/// retain the ordinary session launch lease and surface-binding claim.
public struct CodexManagedDaemonAttachPlan: Sendable, Equatable {
    /// Exact bundled frontend, never a PATH lookup or a caller-selected replacement.
    public let frontendExecutable: String
    /// Native stock executable used only for the frontend's supported helper paths.
    public let stockExecutable: String
    /// Original saved invocation, including its unchanged permission arguments.
    public let invocation: AgentRestoreInvocation
    /// Exact existing provider checkpoint.
    public let sessionID: String
    /// Applied saved working directory.
    public let workingDirectory: String
    /// Exact provider account, pinned for both the probe and final frontend.
    public let codexHome: String

    /// Arguments for the derived frontend, containing no initial input.
    public var arguments: [String] { [frontendExecutable] + invocation.arguments.dropFirst() }

    /// Environment for probing and launching the same existing managed daemon.
    public var environment: [String: String] {
        var value = invocation.environment
        value["CODEX_HOME"] = codexHome
        value["CMUX_QUIET_STOCK_CODEX"] = stockExecutable
        return value
    }

    /// Builds a plan only after an injected verifier establishes frontend/daemon compatibility.
    /// - Parameters:
    ///   - invocation: Independently planned saved Codex resume, not arbitrary shell input.
    ///   - sessionID: Checkpoint from the current surface restore record.
    ///   - frontendExecutable: The owning bundle's exact frontend resource path.
    ///   - stockExecutable: Resolved native stock executable; the live verifier rejects scripts.
    ///   - workingDirectory: Existing saved directory actually used for execution.
    ///   - fallbackHome: User home used only when the saved account has no explicit home.
    ///   - verify: Read-only, bounded compatibility verifier; false never falls back to stock.
    /// - Returns: Verified attach plan, or nil when any identity or eligibility check fails.
    public static func verified(
        invocation: AgentRestoreInvocation, sessionID: String,
        frontendExecutable: String, stockExecutable: String,
        workingDirectory: String, fallbackHome: String,
        verify: (Self) -> Bool
    ) -> Self? {
        guard let session = UUID(uuidString: sessionID),
              invocation.codexResumeSessionID.flatMap(UUID.init(uuidString:)) == session,
              invocation.preflightInvocations.isEmpty,
              invocation.arguments.first.map({ ($0 as NSString).lastPathComponent }) == "codex",
              frontendExecutable.hasPrefix("/"), stockExecutable.hasPrefix("/"),
              workingDirectory.hasPrefix("/"),
              URL(fileURLWithPath: frontendExecutable).standardizedFileURL != URL(fileURLWithPath: stockExecutable).standardizedFileURL,
              eligible(Array(invocation.arguments.dropFirst()), session: session, cwd: workingDirectory) else { return nil }
        let plan = Self(frontendExecutable: frontendExecutable, stockExecutable: stockExecutable,
            invocation: invocation, sessionID: sessionID, workingDirectory: workingDirectory,
            codexHome: CodexRestoreAccount().home(environment: invocation.environment,
                workingDirectory: workingDirectory, fallbackHome: fallbackHome))
        return verify(plan) ? plan : nil
    }

    private static func eligible(_ arguments: [String], session: UUID, cwd: String) -> Bool {
        var index = 0
        var resumed = false
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "resume":
                guard !resumed, index + 1 < arguments.count,
                      UUID(uuidString: arguments[index + 1]) == session else { return false }
                resumed = true; index += 2
            case "-m", "--model", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else { return false }
                if argument == "-C" || argument == "--cd" {
                    guard URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL == URL(fileURLWithPath: cwd).standardizedFileURL else { return false }
                }
                index += 2
            case "--dangerously-bypass-approvals-and-sandbox", "--yolo": index += 1
            case "-c", "--config":
                guard index + 1 < arguments.count, safeConfig(arguments[index + 1]) else { return false }
                index += 2
            default:
                guard (argument.hasPrefix("--config=") || argument.hasPrefix("-c=")),
                      let value = argument.split(separator: "=", maxSplits: 1).last,
                      safeConfig(String(value)) else { return false }
                index += 1
            }
        }
        return resumed
    }

    private static func safeConfig(_ value: String) -> Bool {
        if value == "check_for_update_on_startup=false" { return true }
        let prefix = "model_reasoning_effort="
        guard value.hasPrefix(prefix) else { return false }
        let raw = String(value.dropFirst(prefix.count))
        let effort: String
        if raw.count >= 2, (raw.first == "\"" && raw.last == "\"" || raw.first == "'" && raw.last == "'") {
            effort = String(raw.dropFirst().dropLast())
        } else { effort = raw }
        return ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"].contains(effort)
    }
}
