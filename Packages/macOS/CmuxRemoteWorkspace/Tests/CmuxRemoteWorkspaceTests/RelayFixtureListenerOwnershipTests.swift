import Darwin
import Foundation
import Testing

@Suite("Relay fixture listener ownership", .timeLimit(.minutes(1)))
struct RelayFixtureListenerOwnershipTests {
    @Test("a delayed accept keeps its listener after cancellation until the worker exits")
    func cancelledAcceptRetainsListenerUntilWorkerExits() throws {
        // Unchecked Sendable: the lock protects the sole descriptor receipt.
        final class Receipt: @unchecked Sendable {
            let lock = NSLock()
            private var descriptor: Int32 = -1
            func record(_ value: Int32) { lock.lock(); descriptor = value; lock.unlock() }
            func read() -> Int32 { lock.lock(); defer { lock.unlock() }; return descriptor }
        }
        let receipt = Receipt()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try FakeUnixSocketServer(response: Data(), acceptClient: { fd in
            receipt.record(fd)
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            errno = ECANCELED
            return -1
        })
        var cancelled = false
        defer {
            release.signal()
            if !cancelled { server.close() }
        }
        // Make the real listener readable so a polling accept loop reaches
        // the injected accept operation without using any user's socket.
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { Darwin.close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(server.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        try #require(entered.wait(timeout: .now() + 1) == .success)
        withKnownIssue("The deliberately delayed accept exceeds its short join deadline", isIntermittent: true) {
            server.close(joinTimeout: .milliseconds(1))
        }
        cancelled = true
        // getsockname verifies the exact listening socket, rather than only
        // testing that an unrelated reused descriptor happens to be open.
        #expect(Self.boundPath(receipt.read()) == server.path)
        release.signal()
        #expect(server.waitForWorkerCompletion(timeout: .seconds(1)))
    }

    private static func boundPath(_ descriptor: Int32) -> String? {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0, address.sun_family == sa_family_t(AF_UNIX) else { return nil }
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        return withUnsafePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
