import Foundation
import CryptoKit
import Darwin

protocol AgentCodexTransport: Sendable {
    var messages: AsyncThrowingStream<ChiefJSON, any Error> { get }
    func connect() async throws
    func request(_ method: String, _ params: ChiefJSON) async throws -> ChiefJSON
    func notify(_ method: String, _ params: ChiefJSON) async throws
    func close() async
}

/// One native, event-driven connection to the existing shared Codex daemon.
actor AgentCodexConnection: AgentCodexTransport {
    enum Failure: Error { case unavailable, closed, invalidHandshake, rpc(String), deadline, overloaded }
    nonisolated let messages: AsyncThrowingStream<ChiefJSON, any Error>
    private let messageSink: AsyncThrowingStream<ChiefJSON, any Error>.Continuation
    private let path: String
    private var fd: Int32?
    // Dispatch sources bridge nonblocking POSIX readiness into the actor; they do not synchronize state.
    private var reader: (any DispatchSourceRead)?
    private var writer: (any DispatchSourceWrite)?
    private var rawConsumer: Task<Void, Never>?
    private var generation = UUID()
    private var output = Data()
    private var input = Data()
    private var frames = AgentWebSocketFrames()
    private var upgraded = false
    private var accept = ""
    private var opening: [CheckedContinuation<Void, any Error>] = []
    private var openDeadline: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<ChiefJSON, any Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var closed = false

    init(path: String) {
        self.path = path
        let (messages, sink) = AsyncThrowingStream.makeStream(of: ChiefJSON.self, bufferingPolicy: .bufferingOldest(256))
        self.messages = messages
        self.messageSink = sink
    }

    func connect() async throws {
        guard !closed else { throw Failure.closed }
        if upgraded { return }
        try await withCheckedThrowingContinuation { continuation in
            opening.append(continuation)
            guard fd == nil else { return }
            do { try openSocket() } catch { fail(error) }
        }
    }

    func request(_ method: String, _ params: ChiefJSON = .object([:])) async throws -> ChiefJSON {
        try await connect()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.expire(id)
            }
            do { try send(.object(["id": .string(id), "method": .string(method), "params": params])) }
            catch { finish(id, result: .failure(error)) }
        }
    }

    func notify(_ method: String, _ params: ChiefJSON = .object([:])) throws {
        try send(.object(["method": .string(method), "params": params]))
    }

    func close() { fail(Failure.closed) }

    private func openSocket() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let name = Array(path.utf8CString)
        guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: name.map { UInt8(bitPattern: $0) }) }
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Failure.unavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { Darwin.close(socketFD); throw Failure.unavailable }
        fd = socketFD
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let token = generation
        let (raw, sink) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(64))
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .global(qos: .utility))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count > 0 {
                if case .dropped = sink.yield(Data(buffer.prefix(count))) { sink.finish(throwing: Failure.overloaded) }
            } else if count == 0 { sink.finish(throwing: Failure.closed) }
            else if errno != EAGAIN && errno != EINTR { sink.finish(throwing: Failure.closed) }
        }
        source.setCancelHandler { Darwin.close(socketFD); sink.finish() }
        reader = source
        rawConsumer = Task { [weak self] in
            do {
                for try await data in raw { try await self?.receive(data, generation: token) }
            } catch { await self?.fail(error, generation: token) }
        }
        source.resume()
        openDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.fail(Failure.deadline, generation: token)
        }
        output = Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
        try flush()
    }

    private func receive(_ data: Data, generation token: UUID) throws {
        guard token == generation else { return }
        var payload = data
        if !upgraded {
            input.append(data)
            guard let end = input.range(of: Data("\r\n\r\n".utf8)) else {
                guard input.count < 16_384 else { throw Failure.invalidHandshake }; return
            }
            let header = String(decoding: input[..<end.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { first, _ in first })
            guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
                  headers["sec-websocket-accept"] == accept,
                  headers["upgrade"]?.lowercased() == "websocket" else { throw Failure.invalidHandshake }
            payload = Data(input[end.upperBound...]); input = Data(); upgraded = true
            openDeadline?.cancel(); openDeadline = nil
            let waiters = opening; opening.removeAll(); for waiter in waiters { waiter.resume() }
        }
        for frame in try frames.receive(payload) {
            switch frame {
            case .closed: throw Failure.closed
            case .ping(let bytes): output.append(try AgentWebSocketFrames.clientFrame(bytes, opcode: 10)); try flush()
            case .text(let bytes):
                let value = try ChiefJSON(parsing: bytes)
                if let id = value["id"]?.string, pending[id] != nil {
                    if let error = value["error"] { finish(id, result: .failure(Failure.rpc(error["message"]?.string ?? "Request rejected"))) }
                    else { finish(id, result: .success(value["result"] ?? .null)) }
                } else if case .dropped = messageSink.yield(value) { throw Failure.overloaded }
            }
        }
    }

    private func send(_ value: ChiefJSON) throws {
        guard upgraded, fd != nil else { throw Failure.closed }
        guard output.count < AgentWebSocketFrames.limit else { throw Failure.overloaded }
        output.append(try AgentWebSocketFrames.clientFrame(Data(value.compactText.utf8)))
        try flush()
    }

    private func flush() throws {
        guard let fd else { throw Failure.closed }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { output.removeFirst(count); continue }
            if count < 0 && errno == EINTR { continue }
            guard count < 0 && errno == EAGAIN else { throw Failure.closed }
            if writer == nil {
                let token = generation
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .global(qos: .utility))
                source.setEventHandler { [weak self] in Task { await self?.flushReady(generation: token) } }
                writer = source; source.resume()
            }
            return
        }
        writer?.cancel(); writer = nil
    }

    private func flushReady(generation token: UUID) {
        guard token == generation else { return }
        do { try flush() } catch { fail(error) }
    }

    private func expire(_ id: String) { finish(id, result: .failure(Failure.deadline)) }
    private func finish(_ id: String, result: Result<ChiefJSON, any Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func fail(_ error: any Error, generation token: UUID? = nil) {
        if let token, token != generation { return }
        closed = true
        generation = UUID(); upgraded = false; fd = nil
        writer?.cancel(); writer = nil; reader?.cancel(); reader = nil
        rawConsumer?.cancel(); rawConsumer = nil
        openDeadline?.cancel(); openDeadline = nil
        let waiters = opening; opening.removeAll(); for waiter in waiters { waiter.resume(throwing: error) }
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
        messageSink.finish(throwing: error)
    }
}
