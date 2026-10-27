import Darwin
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Pass-through rewriter for policy tests: the policy gate lives inside the
/// relay server, so a trivial conformer is enough to exercise it end to end.
struct PolicyPassthroughRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return commandLine
        }
        var params = request["params"] as? [String: Any] ?? [:]
        params["_cmux_remote_workspace_id"] = UUID().uuidString
        params["_cmux_remote_relay_request_authentication_code"] = "test"
        request["params"] = params
        guard let rewritten = try? JSONSerialization.data(withJSONObject: request) else {
            return commandLine
        }
        return rewritten + Data([0x0A])
    }
}

/// Multi-connection stand-in for the local cmux control socket: accepts any
/// number of connections, records every request, answers each with a fixed
/// `{"ok":true,"result":{}}` line. The relay must forward authorized commands
/// here and must never connect for denied ones.
/// Unchecked Sendable: the lock protects requests, stop state and live descriptor
/// identities. The dedicated worker owns descriptor closure; close joins it.
final class PolicyFakeUnixSocketServer: @unchecked Sendable {
    let path: String
    private let responseBody: Data
    private let lock = NSLock()
    private var _requests: [Data] = []
    private let listenFD: Int32
    private var shouldStop = false
    private var listenerOpen = true
    private var activeClient: Int32?
    private var replying = false
    private let workerFinished = DispatchGroup()

    var requests: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    init(responseBody: Data = Data("{\"ok\":true,\"result\":{}}\n".utf8),
         acceptClient: @escaping @Sendable (Int32) -> Int32 = { Darwin.accept($0, nil, nil) }) throws {
        self.responseBody = responseBody
        path = NSTemporaryDirectory() + "cmux-relay-policy-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"])
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0 else {
            let bindErrno = errno
            Darwin.close(fd)
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(bindErrno), userInfo: [NSLocalizedDescriptionKey: "bind() failed errno=\(bindErrno)"])
        }
        guard listen(fd, 8) == 0 else {
            let listenErrno = errno
            Darwin.close(fd)
            throw NSError(domain: "PolicyFakeUnixSocketServer", code: Int(listenErrno), userInfo: [NSLocalizedDescriptionKey: "listen() failed errno=\(listenErrno)"])
        }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let failure = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        listenFD = fd
        workerFinished.enter()
        let workerFinished = self.workerFinished
        Thread.detachNewThread { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.listenerOpen = false
                    Darwin.close(fd)
                    self.lock.unlock()
                } else { Darwin.close(fd) }
                workerFinished.leave()
            }
            while true {
                guard let self else { return }
                self.lock.lock()
                let stopping = self.shouldStop
                self.lock.unlock()
                if stopping { return }
                var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&readiness, 1, 20)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 || readiness.revents & Int16(POLLNVAL) != 0 { return }
                if ready == 0 { continue }
                let client = acceptClient(fd)
                if client < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                if client < 0 { return }
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                self.lock.lock()
                let stopped = self.shouldStop
                if !stopped { self.activeClient = client }
                self.lock.unlock()
                if stopped {
                    Darwin.close(client)
                    return
                }
                self.serve(client: client)
                self.lock.lock()
                self.activeClient = nil
                self.replying = false
                Darwin.close(client)
                self.lock.unlock()
            }
        }
    }

    private func serve(client: Int32) {
        var request = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &scratch, scratch.count)
            if count < 0 && errno == EINTR { continue }
            if count > 0 {
                request.append(scratch, count: count)
                continue
            }
            break
        }
        lock.lock()
        guard !shouldStop else { lock.unlock(); return }
        _requests.append(request)
        replying = true
        lock.unlock()
        // A fixture stop must not shut down its own write or wait for a peer
        // that stopped reading. The worker closes the descriptor after this
        // cancellable nonblocking reply; no socket syscall holds the state lock.
        guard fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK) == 0 else { return }
        var sent = 0
        while sent < responseBody.count {
            lock.lock()
            let stopped = shouldStop
            lock.unlock()
            if stopped { return }
            let count = responseBody.withUnsafeBytes { raw in
                Darwin.write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            }
            if count > 0 { sent += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var ready = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&ready, 1, 20)
                continue
            }
            return
        }
    }

    func close() {
        lock.lock()
        guard !shouldStop else { lock.unlock(); return }
        shouldStop = true
        if let activeClient, !replying { _ = shutdown(activeClient, SHUT_RDWR) }
        // Closing a listener alone need not wake another thread's accept.
        // Stop and join the worker before its descriptor can be reused.
        if listenerOpen { _ = shutdown(listenFD, SHUT_RDWR) }
        lock.unlock()
        if workerFinished.wait(timeout: .now() + 1) != .success {
            Issue.record("The owned Unix socket fixture did not stop before descriptor cleanup")
        }
        unlink(path)
    }
}

/// One-shot relay client: performs the documented HMAC challenge-response,
/// sends exactly one command line, then collects the response until close.
struct PolicyRelayExchange {
    let responseLines: [[String: Any]]
    let rawResponse: String
    let closedByPeer: Bool
}

func runPolicyRelayExchange(
    port: Int,
    relayID: String,
    tokenHex: String,
    commandLine: String
) throws -> PolicyRelayExchange {
    let queue = DispatchQueue(label: "relay-policy-test-client")
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var received = Data()
        var closed = false
    }
    let state = State()
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: UInt16(port))!,
        using: .tcp
    )
    connection.start(queue: queue)
    @Sendable func receiveLoop(_ connection: NWConnection, _ state: State) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            state.lock.lock()
            if let data { state.received.append(data) }
            if isComplete || error != nil { state.closed = true }
            let done = state.closed
            state.lock.unlock()
            if !done { receiveLoop(connection, state) }
        }
    }
    receiveLoop(connection, state)

    func wait(_ timeout: TimeInterval = 5.0, _ predicate: (Data, Bool) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            state.lock.lock()
            let snapshot = state.received
            let isClosed = state.closed
            state.lock.unlock()
            if predicate(snapshot, isClosed) { return true }
            usleep(20_000)
        }
        return false
    }
    func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    defer { connection.cancel() }

    // Challenge.
    guard wait(5.0, { data, _ in data.contains(0x0A) }) else {
        Issue.record("timed out waiting for relay challenge")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }
    state.lock.lock()
    let challengeLine = state.received.split(separator: 0x0A).first.map { Data($0) } ?? Data()
    state.received.removeAll(keepingCapacity: true)
    state.lock.unlock()
    let challenge = try JSONSerialization.jsonObject(with: challengeLine) as? [String: Any]
    let nonce = try #require(challenge?["nonce"] as? String)

    // Auth.
    let token = try #require(RemoteCLIRelayServer.Session.hexData(from: tokenHex))
    let message = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=1".utf8)
    let mac = RemoteCLIRelayServer.Session.authMAC(token: token, message: message)
    let auth: [String: Any] = [
        "relay_id": relayID,
        "mac": mac.map { String(format: "%02x", $0) }.joined(),
    ]
    send(connection, try JSONSerialization.data(withJSONObject: auth) + Data([0x0A]))
    guard wait(5.0, { data, _ in data.contains(0x0A) }) else {
        Issue.record("timed out waiting for relay auth response")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }
    state.lock.lock()
    let authLine = state.received.split(separator: 0x0A).first.map { Data($0) } ?? Data()
    state.received.removeAll(keepingCapacity: true)
    state.lock.unlock()
    let authResponse = try JSONSerialization.jsonObject(with: authLine) as? [String: Any]
    guard (authResponse?["ok"] as? Bool) == true else {
        Issue.record("relay authentication failed: \(String(decoding: authLine, as: UTF8.self))")
        return PolicyRelayExchange(responseLines: [], rawResponse: "", closedByPeer: false)
    }

    // Command; the relay answers then closes the connection.
    send(connection, Data(commandLine.utf8) + Data([0x0A]))
    if !wait(5.0, { _, closed in closed }) {
        state.lock.lock()
        let byteCount = state.received.count
        state.lock.unlock()
        Issue.record("Relay command response did not close within the fixture deadline (received \(byteCount) bytes)")
    }

    state.lock.lock()
    let raw = state.received
    let wasClosed = state.closed
    state.lock.unlock()
    let lines = raw.split(separator: 0x0A).compactMap {
        try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
    }
    return PolicyRelayExchange(
        responseLines: lines,
        rawResponse: String(decoding: raw, as: UTF8.self),
        closedByPeer: wasClosed
    )
}
