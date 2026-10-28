import Darwin
import Foundation

/// Owns the launch and bounded cleanup of one probe. Escalation runs on the
/// synchronous caller, so a delayed dispatch timer cannot leave the child alive.
final class ProbeChildSupervisor {
    private let child: Process
    private let finished = DispatchSemaphore(value: 0)
    private var owner: ProbeChildIdentity?

    init(_ child: Process) {
        precondition(!child.isRunning)
        self.child = child
        let finished = self.finished
        child.terminationHandler = { _ in finished.signal() }
    }

    func launch() throws {
        try child.run()
        owner = ProbeChildIdentity(child.processIdentifier)
    }

    /// A timed-out probe fails even when TERM causes a successful exit. Every
    /// wait is bounded; every signal rechecks the exact owned child generation.
    func completedWithinDeadline(timeout: TimeInterval, terminationGrace: TimeInterval) -> Bool {
        if finished.wait(timeout: .now() + timeout) == .success { return true }
        if child.isRunning, owner?.isCurrent == true { child.terminate() }
        if finished.wait(timeout: .now() + terminationGrace) == .success { return false }
        if child.isRunning, owner?.isCurrent == true {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
        // The kernel/termination callback may still be delayed after SIGKILL.
        // Do not turn that into an unbounded wait or signal a reused PID.
        _ = finished.wait(timeout: .now() + 0.5)
        return false
    }
}

/// Exact generation of the child created by this probe, not an inherited agent PID.
private struct ProbeChildIdentity: Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    init?(_ pid: Int32) {
        guard let info = Self.info(pid) else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    var isCurrent: Bool {
        guard let info = Self.info(pid) else { return false }
        return info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.pbi_ppid == UInt32(getpid()),
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }
}
