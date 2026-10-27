import Darwin
import Foundation
import Testing

@Suite("Cloud fixture descriptor ownership", .timeLimit(.minutes(1)))
struct CloudLinkBlockingTestServerTests {
    @Test("a timed out join retains its socket until the worker exits")
    func timeoutRetainsWorkerDescriptor() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let listener = pair[0]
        let peer = pair[1]
        defer { Darwin.close(peer) }
        try #require(fcntl(peer, F_SETFL, O_NONBLOCK) == 0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = CloudLinkBlockingTestServer(ownedListener: listener) { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 1) == .success)
        withKnownIssue("The deliberately blocked worker exceeds the short join deadline") {
            server.cancel(joinTimeout: .milliseconds(1))
        }
        var byte: UInt8 = 0
        let beforeExit = Darwin.read(peer, &byte, 1)
        let beforeExitError = errno
        #expect(beforeExit == -1)
        #expect(beforeExitError == EAGAIN || beforeExitError == EWOULDBLOCK)
        release.signal()
        await server.value
        // EOF proves the worker released its socket without inspecting a
        // descriptor number that another parallel test could already reuse.
        #expect(Darwin.read(peer, &byte, 1) == 0)
    }
}
