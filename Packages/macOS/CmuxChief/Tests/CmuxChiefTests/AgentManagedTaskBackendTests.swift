import Foundation
import CmuxHomeCore
import Testing
@testable import CmuxChief

@Suite("Managed provider protocol")
struct AgentManagedTaskBackendTests {
    private func request() -> AgentTaskRequest {
        AgentTaskRequest(provider: .codex, prompt: "Reply once", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), model: "gpt-6-luna", effort: "low",
                         presentation: .background)
    }

    @Test func boundSessionsObservePhoneActivityWithoutLoadingOrStartingWork() async throws {
        let session = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
        let transport = TaskProtocolFixture()
        let backend = AgentManagedTaskBackend(connection: transport)
        let stream = await backend.sessionActivityChanges()
        var iterator = stream.makeAsyncIterator()
        await backend.observeSession(session)
        #expect(await iterator.next() == .init(sessionID: session, phase: .idle))
        await transport.status(session: session, type: "active")
        #expect(await iterator.next() == .init(sessionID: session, phase: .working))
        await transport.status(session: session, type: "active", flags: ["waitingOnApproval"])
        #expect(await iterator.next() == .init(sessionID: session, phase: .attention))
        await transport.status(session: session, type: "idle")
        #expect(await iterator.next() == .init(sessionID: session, phase: .idle))
        await backend.observeSession(session)
        await backend.observeSession("not-an-identity")
        #expect(await transport.methods == ["initialize", "thread/read"])
        await transport.loseConnection()
        #expect(await iterator.next() == .init(sessionID: session, phase: .unknown))
    }

    @Test(.timeLimit(.minutes(1))) func aFailedSnapshotCannotOverwriteANewerAuthoritativeNotification() async throws {
        let session = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
        let transport = TaskProtocolFixture(holdRead: true)
        let backend = AgentManagedTaskBackend(connection: transport)
        var iterator = await backend.sessionActivityChanges().makeAsyncIterator()
        let read = Task { await backend.observeSession(session) }
        await transport.waitForRead()
        await transport.status(session: session, type: "active")
        #expect(await iterator.next() == .init(sessionID: session, phase: .working))
        await transport.failRead()
        await read.value
        #expect(await backend.sessionActivitySnapshot(session)?.phase == .working)
        await transport.status(session: session, type: "notLoaded")
        #expect(await iterator.next() == .init(sessionID: session, phase: .idle))
    }

    @Test(.timeLimit(.minutes(1))) func initialConnectionFailureRetriesOnlyMetadata() async throws {
        let session = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
        let transport = TaskProtocolFixture(connectFailures: 1)
        let backend = AgentManagedTaskBackend(connection: transport)
        var iterator = await backend.sessionActivityChanges().makeAsyncIterator()
        await backend.observeSession(session)
        #expect(await iterator.next() == .init(sessionID: session, phase: .unknown))
        #expect(await iterator.next() == .init(sessionID: session, phase: .idle))
        #expect(await transport.connectCount == 2)
        #expect(await transport.methods == ["initialize", "thread/read"])
    }

    @Test func completionBeforeTurnAcknowledgmentPreservesIdentityAndResult() async throws {
        let transport = TaskProtocolFixture()
        let backend = AgentManagedTaskBackend(connection: transport)
        let stream = try await backend.start(id: UUID(), request: request())
        var events: [AgentTaskEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events.first == .session("fixture-session"))
        #expect(events.contains(.completed("Confirmed result")))
        #expect(await transport.methods.filter { $0 == "turn/start" }.count == 1)
    }

    @Test func lostAcceptanceIsNeverRetriedOrReportedAsSuccessfulCancellation() async throws {
        let transport = TaskProtocolFixture(failAcceptance: true)
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        let stream = try await backend.start(id: id, request: request())
        var events: [AgentTaskEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events.first == .session("fixture-session"))
        #expect(events.contains { if case .disconnected = $0 { return true }; return false })
        #expect(!events.contains(.completed("Confirmed result")))
        await #expect(throws: (any Error).self) { try await backend.cancel(id: id) }
        #expect(await transport.methods.filter { $0 == "turn/start" }.count == 1)
    }

    @Test func backgroundClaudeUsesBypassAndCannotHangOnInvisibleApproval() async throws {
        let backend = AgentManagedTaskBackend(connection: TaskProtocolFixture(), claudeFactory: { configuration in
            let arguments = ClaudeCodeBrain.arguments(configuration, session: .new("fixture-session"), systemPrompt: "")
            #expect(arguments.contains("bypassPermissions"))
            return TaskApprovalBrain()
        })
        var input = request(); input.provider = .claude; input.model = "haiku"
        let id = UUID()
        let stream = try await backend.start(id: id, request: input)
        let event = await withTaskGroup(of: AgentTaskEvent?.self) { group in
            group.addTask {
                do {
                    for try await event in stream {
                        if case .failed = event { return event }
                    }
                } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let event = await group.next() ?? nil
            group.cancelAll()
            return event
        }
        #expect(event == .failed("background_input_required"))
        try await backend.cancel(id: id)
    }

    @Test func backgroundClaudeEOFWithoutCompletionEndsAsUncertain() async throws {
        let backend = AgentManagedTaskBackend(connection: TaskProtocolFixture(), claudeFactory: { _ in TaskApprovalBrain(approval: false) })
        var input = request(); input.provider = .claude; input.model = "haiku"
        let id = UUID()
        let stream = try await backend.start(id: id, request: input)
        let event = await withTaskGroup(of: AgentTaskEvent?.self) { group in
            group.addTask {
                do {
                    for try await event in stream { if case .disconnected = event { return event } }
                } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let event = await group.next() ?? nil
            group.cancelAll()
            return event
        }
        #expect(event == .disconnected("stream_ended_without_completion"))
        try? await backend.cancel(id: id)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_AGENT_TASK_LIVE"] == "1"))
    func liveLunaTaskUsesExistingDaemonAndReturnsAConfirmedResult() async throws {
        let path = NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"
        let backend = AgentManagedTaskBackend(socketPath: path, cancelTerminal: { _ in })
        var input = request()
        input.prompt = "Reply exactly CMUX_NATIVE_TASK_OK. Do not use tools."
        let id = UUID()
        let stream = try await backend.start(id: id, request: input)
        let session = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var session = ""
                for try await event in stream {
                    if case .session(let value) = event { session = value }
                    if case .completed(let text) = event {
                        #expect(text.contains("CMUX_NATIVE_TASK_OK"))
                        return session
                    }
                    if case .disconnected(let error) = event { throw LiveFailure.provider(error) }
                    if case .failed(let error) = event { throw LiveFailure.provider(error) }
                }
                throw LiveFailure.provider("No completion")
            }
            group.addTask { try await Task.sleep(for: .seconds(90)); throw LiveFailure.provider("Deadline") }
            let session = try await group.next() ?? ""
            group.cancelAll()
            return session
        }
        #expect(!session.isEmpty)
        print("Native Luna managed task completed on shared daemon: \(session)")
    }

    private enum LiveFailure: Error { case provider(String) }
}

private struct TaskApprovalBrain: ChiefBrain {
    var approval = true
    func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.session("claude-fixture-session"))
            if approval { continuation.yield(.approvalRequested(id: "permission", prompt: "Write a file?", options: ["allow", "deny"])) }
            continuation.finish()
        }
    }
    func respond(toApproval id: String, choice: String, conversation: ConversationID) async {}
    func interrupt(conversation: ConversationID) async {}
    func shutdown() async {}
}

private actor TaskProtocolFixture: AgentCodexTransport {
    nonisolated let messages: AsyncThrowingStream<ChiefJSON, any Error>
    private let sink: AsyncThrowingStream<ChiefJSON, any Error>.Continuation
    private let failAcceptance: Bool
    private let holdRead: Bool
    private var connectFailures: Int
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRead: CheckedContinuation<ChiefJSON, any Error>?
    private(set) var connectCount = 0
    private var connected = false
    var methods: [String] = []

    init(failAcceptance: Bool = false, holdRead: Bool = false, connectFailures: Int = 0) {
        let pair = AsyncThrowingStream.makeStream(of: ChiefJSON.self)
        messages = pair.stream; sink = pair.continuation
        self.failAcceptance = failAcceptance
        self.holdRead = holdRead; self.connectFailures = connectFailures
    }
    func connect() throws {
        connectCount += 1
        if connectFailures > 0 { connectFailures -= 1; throw URLError(.cannotConnectToHost) }
        connected = true
    }
    func close() { if connected { sink.finish() } }
    func waitForRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func failRead() {
        pendingRead?.resume(throwing: URLError(.timedOut)); pendingRead = nil
    }
    func notify(_ method: String, _ params: ChiefJSON) {}
    func status(session: String, type: String, flags: [String] = []) {
        sink.yield(.object(["method": .string("thread/status/changed"), "params": .object([
            "threadId": .string(session), "status": .object(["type": .string(type), "activeFlags": .array(flags.map(ChiefJSON.string))])])]))
    }
    func loseConnection() { sink.finish(throwing: URLError(.networkConnectionLost)) }
    func request(_ method: String, _ params: ChiefJSON) async throws -> ChiefJSON {
        methods.append(method)
        if method == "thread/read" {
            if holdRead {
                return try await withCheckedThrowingContinuation { pendingRead = $0
                    for waiter in readWaiters { waiter.resume() }; readWaiters.removeAll()
                }
            }
            return .object(["thread": .object(["status": .object(["type": .string("idle")])])])
        }
        if method == "thread/start" { return .object(["thread": .object(["id": .string("fixture-session")])]) }
        if method == "turn/start" {
            if failAcceptance { throw URLError(.networkConnectionLost) }
            sink.yield(.object(["method": .string("item/completed"), "params": .object([
                "threadId": .string("fixture-session"), "item": .object([
                    "type": .string("agentMessage"), "phase": .string("final_answer"), "text": .string("Confirmed result")])])]))
            sink.yield(.object(["method": .string("turn/completed"), "params": .object([
                "threadId": .string("fixture-session"), "turn": .object(["status": .string("completed")])])]))
            return .object(["turn": .object(["id": .string("fixture-turn")])])
        }
        return .object([:])
    }
}
