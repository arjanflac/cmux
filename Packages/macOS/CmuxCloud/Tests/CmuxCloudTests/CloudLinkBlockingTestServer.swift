import Foundation
import Testing
@testable import CmuxCloud

/// POSIX fixture I/O must never occupy Swift's bounded cooperative executor.
/// The operation checks cancellation around its bounded socket polls; joining
/// here prevents a test from closing and reusing its descriptors too early.
/// Unchecked Sendable: the lock protects cancellation and the group/first-value
/// completion synchronize joining. Private POSIX I/O runs on the owned thread.
final class CloudLinkBlockingTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let finished = DispatchGroup()
    private let completion = CloudLinkFirstValue<Bool>()

    init(operation: @escaping @Sendable (CloudLinkBlockingTestServer) -> Void) {
        finished.enter()
        let thread = Thread { [self] in
            operation(self)
            completion.resolve(true)
            finished.leave()
        }
        thread.name = "cmux-cloud-test-socket"
        thread.start()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if finished.wait(timeout: .now() + 1) != .success {
            Issue.record("The owned socket fixture did not stop before descriptor cleanup")
        }
    }

    var value: Void {
        get async { _ = await completion.result }
    }
}
