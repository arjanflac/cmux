import CryptoKit
import Darwin
import Foundation

/// Bounded read-only verification of the installed derived frontend and existing stock daemon.
///
/// Only native executable `--version` and frontend `--cmux-check` processes run.
/// The frontend check verifies the private daemon endpoint and exact version;
/// it cannot resume a thread, start a turn, embed a backend or update a daemon.
public struct CodexManagedDaemonAttachProbe: Sendable {
    /// Creates a verifier with no persistent processes or connections.
    public init() {}

    /// Resolves a native stock executable without running shell wrappers.
    /// - Parameters:
    ///   - invocation: Saved launch and its final environment.
    ///   - home: User home used for the standard user-local CLI path.
    /// - Returns: An existing native executable, or nil. Scripts and cmux shims are skipped.
    public func stockExecutable(for invocation: AgentRestoreInvocation, home: String) -> String? {
        var candidates = [invocation.environment["CMUX_CUSTOM_CODEX_PATH"], invocation.arguments.first].compactMap { $0 }
        candidates += (invocation.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        candidates += [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first(where: nativeExecutable).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// Verifies the installed artifact, stock version and daemon-only invocation without submitting input.
    /// - Parameter plan: Candidate whose saved identity and narrow arguments were already validated.
    /// - Returns: True only when every check completes successfully. Errors never select stock fallback.
    public func verify(_ plan: CodexManagedDaemonAttachPlan) -> Bool {
        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
                sessionId: plan.sessionID, transcriptPath: nil, codexHome: plan.codexHome,
                allowLegacyFallbackForIndexedMissing: true),
              evidence.provenance.mayOwnBinding,
              UUID(uuidString: evidence.sessionId) == UUID(uuidString: plan.sessionID),
              nativeExecutable(plan.frontendExecutable), nativeExecutable(plan.stockExecutable),
              let binary = try? Data(contentsOf: URL(fileURLWithPath: plan.frontendExecutable), options: .mappedIfSafe),
              let manifestData = try? Data(contentsOf: URL(fileURLWithPath: plan.frontendExecutable)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("licenses/codex-quiet/manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["attach_only"] as? Bool == true,
              manifest["release"] as? String == "rust-v0.164.0",
              manifest["commit"] as? String == "6aaac694803004a63c6f393d153c96d22521a6b9",
              manifest["repository"] as? String == "https://github.com/openai/codex",
              manifest["binary_sha256"] as? String == SHA256.hash(data: binary).map({ String(format: "%02x", $0) }).joined(),
              run(plan.stockExecutable, arguments: ["--version"], environment: plan.environment,
                  cwd: plan.workingDirectory, expectedOutput: "codex-cli 0.164.0"),
              run(plan.frontendExecutable, arguments: ["--cmux-check"] + plan.arguments.dropFirst(),
                  environment: plan.environment, cwd: plan.workingDirectory) else { return false }
        return true
    }

    private func nativeExecutable(_ path: String) -> Bool {
        var metadata = stat()
        guard path.hasPrefix("/"), stat(path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), access(path, X_OK) == 0 else { return false }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else { return false }
        guard let data = try? file.read(upToCount: 4), data.count == 4 else { return false }
        return [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
                Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])].contains(data)
    }

    func run(_ executable: String, arguments: [String], environment: [String: String],
             cwd: String, expectedOutput: String? = nil,
             timeout: TimeInterval = 5, terminationGrace: TimeInterval = 0.25) -> Bool {
        let child = Process()
        let supervisor = ProbeChildSupervisor(child)
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let output = expectedOutput == nil ? nil : Pipe()
        child.standardOutput = output?.fileHandleForWriting ?? FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try supervisor.launch() } catch { return false }
        try? output?.fileHandleForWriting.close()
        defer { try? output?.fileHandleForReading.close() }
        guard supervisor.completedWithinDeadline(timeout: timeout, terminationGrace: terminationGrace) else { return false }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else { return false }
        if let expectedOutput {
            if let descriptor = output?.fileHandleForReading.fileDescriptor {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            }
            guard let bytes = try? output?.fileHandleForReading.read(upToCount: 512),
                  String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expectedOutput else { return false }
        }
        return true
    }
}
