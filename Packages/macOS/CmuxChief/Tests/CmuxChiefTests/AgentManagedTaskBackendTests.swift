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
    var methods: [String] = []

    init(failAcceptance: Bool = false) {
        let pair = AsyncThrowingStream.makeStream(of: ChiefJSON.self)
        messages = pair.stream; sink = pair.continuation
        self.failAcceptance = failAcceptance
    }
    func connect() {}
    func close() { sink.finish() }
    func notify(_ method: String, _ params: ChiefJSON) {}
    func request(_ method: String, _ params: ChiefJSON) throws -> ChiefJSON {
        methods.append(method)
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
