import Darwin
import Foundation
import Testing
@testable import CmuxCloud

/// POSIX fixture I/O must never occupy Swift's bounded cooperative executor.
/// The operation checks cancellation around bounded socket polls. Cancellation
/// normally joins cleanup; if that join expires, the worker still owns its
/// listener until exit, so the caller cannot close and reuse it underneath I/O.
/// Unchecked Sendable: the lock protects cancellation and the group/first-value
/// completion synchronize joining. Private POSIX I/O runs on the owned thread.
final class CloudLinkBlockingTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let finished = DispatchGroup()
    private let completion = CloudLinkFirstValue<Bool>()

    init(ownedListener: Int32, operation: @escaping @Sendable (CloudLinkBlockingTestServer) -> Void) {
        finished.enter()
        let thread = Thread { [self] in
            defer {
                Darwin.close(ownedListener)
                completion.resolve(true)
                finished.leave()
            }
            operation(self)
        }
        thread.name = "cmux-cloud-test-socket"
        thread.start()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel(joinTimeout: DispatchTimeInterval = .seconds(1)) {
        lock.lock()
        cancelled = true
        lock.unlock()
        if finished.wait(timeout: .now() + joinTimeout) != .success {
            Issue.record("The owned socket fixture did not stop before its join deadline")
        }
    }

    var value: Void {
        get async { _ = await completion.result }
    }
}
