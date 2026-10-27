import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexManagedDaemonAttachTests {
    private let session = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
    private func plan(_ arguments: [String]? = nil, accepted: Bool = true) -> CodexManagedDaemonAttachPlan? {
        CodexManagedDaemonAttachPlan.verified(invocation: AgentRestoreInvocation(
            arguments: arguments ?? ["/stock/codex", "resume", session], workingDirectory: "/project",
            environment: ["CODEX_HOME": "/account"], codexResumeSessionID: session),
            sessionID: session, frontendExecutable: "/cmux/Contents/Resources/bin/cmux-codex-quiet",
            stockExecutable: "/stock/codex", workingDirectory: "/project", fallbackHome: "/home",
            verify: { _ in accepted })
    }

    @Test("A verified frontend attaches despite the daemon's writer lock, without granting a stock writer")
    func heldWriterOnlyAdmitsVerifiedFrontend() throws {
        let frontend = try #require(plan())
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: false, indexComplete: true,
            writerLock: .active, managedFrontend: frontend) == .claimLaunch)
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: false, indexComplete: true,
            writerLock: .active) == .refreshEvidence)
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: true, indexComplete: true,
            writerLock: .active, managedFrontend: frontend) == .observeOwner)
        #expect(frontend.arguments == [frontend.frontendExecutable, "resume", session])
        #expect(frontend.environment["CODEX_HOME"] == "/account")
        #expect(frontend.environment["CMUX_QUIET_STOCK_CODEX"] == "/stock/codex")
    }

    @Test("Missing proof and unsupported launches never become attach plans")
    func unsupportedInputFailsClosed() {
        #expect(plan(accepted: false) == nil)
        for tail in [["resume", "other"], ["resume", session, "hello"], ["fork", session],
                     ["resume", session, "--no-daemon"], ["resume", session, "--remote", "unix://other"],
                     ["resume", session, "--cd", "/other"], ["resume", session, "-c", "model_provider=other"]] {
            #expect(plan(["/stock/codex"] + tail) == nil)
        }
        #expect(plan(["/stock/codex", "--model", "gpt-6.1-sol", "resume", session, "-c", "model_reasoning_effort=\"high\""]) != nil)
    }

    @Test("Attach keeps saved permissions and never grants stock-writer availability")
    func preservesExplicitPermissions() throws {
        let arguments = ["/stock/codex", "--sandbox", "read-only", "resume", session, "--ask-for-approval", "on-request"]
        let frontend = try #require(plan(arguments))
        #expect(Array(frontend.arguments.dropFirst()) == Array(arguments.dropFirst()))
        #expect(!frontend.arguments.contains("--yolo"))
        #expect(AgentRestoreEvidencePolicy().decision(hasLiveOwner: false, indexComplete: false,
            writerLock: .unavailable) == .refreshEvidence)
    }

    @Test("A different stored checkpoint cannot acquire frontend proof")
    func checkpointMismatchDoesNotProbe() {
        var probes = 0
        let result = CodexManagedDaemonAttachPlan.verified(invocation: AgentRestoreInvocation(
            arguments: ["/stock/codex", "resume", session], workingDirectory: "/project",
            environment: [:], codexResumeSessionID: "01a176fc-d044-7e62-92bb-de6c5c50c0d2"),
            sessionID: session, frontendExecutable: "/cmux/bin/cmux-codex-quiet",
            stockExecutable: "/stock/codex", workingDirectory: "/project", fallbackHome: "/home",
            verify: { _ in probes += 1; return true })
        #expect(result == nil)
        #expect(probes == 0)
    }

    @Test("Stock resolution skips executable scripts and nonregular paths without executing them")
    func resolverRejectsWrappersAndPipes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-stock-resolver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("wrapper")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let fifo = root.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o700) == 0)
        let stock = root.appendingPathComponent("codex")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: stock)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stock.path)
        for custom in [fifo.path, script.path] {
            let invocation = AgentRestoreInvocation(arguments: [script.path, "resume", session],
                workingDirectory: root.path, environment: ["CMUX_CUSTOM_CODEX_PATH": custom, "PATH": root.path],
                codexResumeSessionID: session)
            #expect(CodexManagedDaemonAttachProbe().stockExecutable(for: invocation, home: root.path) == stock.path)
        }
    }

    @Test("An owned native probe that ignores TERM is killed and returns within the bound")
    func uncooperativeProbeIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-probe-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let termFile = root.appendingPathComponent("term.receipt")
        let script = """
        $SIG{TERM}=sub { open(my $f,'>',$ARGV[0]) or die; print $f 'TERM'; close($f); };
        $|=1; print "READY\\n";
        while (1) { select(undef,undef,undef,0.05); }
        """
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", script, termFile.path]
        child.environment = [:]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        let supervisor = ProbeChildSupervisor(child)
        try supervisor.launch()
        try output.fileHandleForWriting.close()
        defer {
            if child.isRunning { _ = supervisor.completedWithinDeadline(timeout: 0, terminationGrace: 0.1) }
            try? output.fileHandleForReading.close()
        }
        try #require(try awaitProbeReady(output.fileHandleForReading), "Child must install its TERM handler before supervision starts")
        let start = ContinuousClock.now
        #expect(!supervisor.completedWithinDeadline(timeout: 0.1, terminationGrace: 0.1))
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(try String(contentsOf: termFile, encoding: .utf8) == "TERM")
        #expect(!child.isRunning)
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)
        let presence = kill(child.processIdentifier, 0)
        let presenceError = errno
        #expect(presence == -1 && presenceError == ESRCH, "Only the spawned probe must have exited and been reaped")
    }

    @Test("The probe startup deadline does not depend on child readiness")
    func startupDeadlineRemainsBounded() {
        let start = ContinuousClock.now
        #expect(!CodexManagedDaemonAttachProbe().run("/usr/bin/perl", arguments: ["-e", "sleep 5"],
            environment: [:], cwd: "/", timeout: 0.001, terminationGrace: 0.1))
        #expect(start.duration(to: .now) < .seconds(2))
    }

    private func awaitProbeReady(_ handle: FileHandle) throws -> Bool {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var bytes = Data()
        while bytes.count < 6 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = deadline - now
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorState, 1, Int32(min((remaining + 999_999) / 1_000_000, 5_000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, let chunk = try handle.read(upToCount: 6 - bytes.count), !chunk.isEmpty else { return false }
            bytes.append(chunk)
        }
        return bytes == Data("READY\n".utf8)
    }

    @Test("A normally exiting native probe completes before either termination deadline")
    func normalProbeExitsWithoutWaitingForDeadline() {
        let start = ContinuousClock.now
        #expect(CodexManagedDaemonAttachProbe().run("/usr/bin/perl", arguments: ["-e", "print 'probe-ok'"],
            environment: [:], cwd: "/", expectedOutput: "probe-ok", timeout: 3, terminationGrace: 0.1))
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test("A timed-out probe cannot succeed by exiting zero in its TERM handler")
    func timedOutProbeFailsEvenWhenTerminationExitsZero() {
        #expect(!CodexManagedDaemonAttachProbe().run("/usr/bin/perl",
            arguments: ["-e", "$SIG{TERM}=sub { exit 0 }; while (1) { select(undef,undef,undef,0.05); }"],
            environment: [:], cwd: "/", timeout: 0.3, terminationGrace: 0.1))
    }
}
