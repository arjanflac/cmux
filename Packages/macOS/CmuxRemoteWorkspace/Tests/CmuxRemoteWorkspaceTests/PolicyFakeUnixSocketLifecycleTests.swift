import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Policy Unix socket fixture lifetime")
struct PolicyFakeUnixSocketLifecycleTests {
    @Test("An interrupted accept does not abandon the listening fixture")
    func interruptedAcceptStillServesItsRequest() throws {
        final class Interruption: @unchecked Sendable {
            let lock = NSLock()
            var pending = true
            func accept(_ fd: Int32) -> Int32 {
                lock.lock()
                let interrupt = pending
                pending = false
                lock.unlock()
                if interrupt { errno = EINTR; return -1 }
                return Darwin.accept(fd, nil, nil)
            }
        }
        let interruption = Interruption()
        let server = try PolicyFakeUnixSocketServer(acceptClient: interruption.accept)
        defer { server.close() }
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(server.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(connected == 0)
        let request = Data("{\"id\":\"interrupted-accept\",\"method\":\"system.ping\"}\n".utf8)
        let written = request.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        try #require(written == request.count)
        _ = shutdown(client, SHUT_WR)
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(client, &bytes, bytes.count)
        #expect(count > 0, "A transient EINTR must not silently stop the fixture's accept loop")
        #expect(server.requests == [request])
    }
}
