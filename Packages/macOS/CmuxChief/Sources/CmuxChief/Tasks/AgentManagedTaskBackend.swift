import Foundation
import CmuxHomeCore

/// Authoritative status of an explicitly bound cmux-owned Codex chat.
public struct AgentSessionActivity: Sendable, Equatable {
    public enum Phase: String, Sendable { case working, attention, idle, unknown }
    public let sessionID: String
    public let phase: Phase
    public init(sessionID: String, phase: Phase) { self.sessionID = sessionID; self.phase = phase }
}

/// Executes explicit Codex tasks on the existing daemon and Claude tasks through Claude Code.
public actor AgentManagedTaskBackend: AgentTaskBackend {
    private struct Running {
        let request: AgentTaskRequest
        let sink: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation
        var session: String?
        var turn: String?
        var answer = ""
        var ready = false
        var finished = false
        var buffered: [AgentTaskEvent] = []
        var admitting = true
    }
    private let socketPath: String
    private let taskCommand: [String]
    private let cancelTerminal: @Sendable (UUID) async throws -> Void
    private let connectionFactory: @Sendable (String) -> any AgentCodexTransport
    private let claudeFactory: @Sendable (ClaudeCodeBrain.Configuration) -> any ChiefBrain
    private var connection: (any AgentCodexTransport)?
    private var startup: Task<any AgentCodexTransport, any Error>?
    private var reader: Task<Void, Never>?
    private var connectionID = UUID()
    private var running: [UUID: Running] = [:]
    private var observationRecovery: Task<Void, Never>?
    private var recoveryGeneration = UUID()
    private var desiredObservedSessions: Set<String> = []
    private var observedSessions: Set<String> = []
    private var observationVersions: [String: Int] = [:]
    private var activitySinks: [UUID: AsyncStream<AgentSessionActivity>.Continuation] = [:]
    private var lastActivities: [String: AgentSessionActivity.Phase] = [:]
    private var bySession: [String: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var uncertain: Set<UUID> = []
    private var claudeBrains: [UUID: any ChiefBrain] = [:]
    private var claudeReaders: [UUID: Task<Void, Never>] = [:]
    private var admissionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var startupDeadlines: [UUID: Task<Void, Never>] = [:]

    /// Uses the already-running managed daemon; it never creates a standalone server.
    public init(socketPath: String, taskCommand: [String] = ["cmux", "task"], cancelTerminal: @escaping @Sendable (UUID) async throws -> Void) {
        self.socketPath = socketPath
        self.taskCommand = taskCommand
        self.cancelTerminal = cancelTerminal
        connectionFactory = { AgentCodexConnection(path: $0) }
        claudeFactory = { ClaudeCodeBrain(configuration: $0) }
    }

    init(connection: any AgentCodexTransport, claudeFactory: @escaping @Sendable (ClaudeCodeBrain.Configuration) -> any ChiefBrain = { ClaudeCodeBrain(configuration: $0) }) {
        socketPath = ""
        taskCommand = ["cmux", "task"]
        cancelTerminal = { _ in throw CocoaError(.featureUnsupported) }
        connectionFactory = { _ in connection }
        self.claudeFactory = claudeFactory
    }

    /// One event stream on the existing transport; never loads/resumes a thread or starts work.
    public func sessionActivityChanges() -> AsyncStream<AgentSessionActivity> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: AgentSessionActivity.self, bufferingPolicy: .bufferingNewest(256))
        activitySinks[token] = pair.continuation
        for (session, phase) in lastActivities { pair.continuation.yield(.init(sessionID: session, phase: phase)) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeActivitySink(token) } }
        return pair.stream
    }

    public func sessionActivitySnapshot(_ session: String) -> AgentSessionActivity? {
        lastActivities[session].map { AgentSessionActivity(sessionID: session, phase: $0) }
    }

    private func removeActivitySink(_ token: UUID) { activitySinks.removeValue(forKey: token) }

    /// Reads only an exact saved session's metadata. Concurrent notifications win over the snapshot.
    public func observeSession(_ session: String) async {
        guard UUID(uuidString: session) != nil else { return }
        desiredObservedSessions.insert(session)
        guard observedSessions.insert(session).inserted else { return }
        var version = observationVersions[session, default: 0]
        var readConnection: UUID?
        do {
            let server = try await server()
            readConnection = connectionID
            version = observationVersions[session, default: 0]
            let result = try await server.request("thread/read", .object(["threadId": .string(session), "includeTurns": .bool(false)]))
            guard readConnection == connectionID, observationVersions[session, default: 0] == version else { return }
            publishActivity(session, status: result["thread"]?["status"])
        } catch {
            guard observationVersions[session, default: 0] == version,
                  readConnection == nil || readConnection == connectionID else { return }
            observedSessions.remove(session)
            publishActivity(session, status: nil)
            if readConnection == nil, observationRecovery == nil { scheduleObservationRecovery() }
        }
    }

    private func publishActivity(_ session: String, status: ChiefJSON?) {
        let phase: AgentSessionActivity.Phase
        switch status?["type"]?.string {
        case "active":
            let flags = status?["activeFlags"]?.array ?? []
            phase = flags.contains { ["waitingOnApproval", "waitingOnUserInput"].contains($0.string ?? "") } ? .attention : .working
        case "idle", "notLoaded": phase = .idle
        default: phase = .unknown
        }
        guard lastActivities[session] != phase else { return }
        lastActivities[session] = phase
        for sink in activitySinks.values { sink.yield(.init(sessionID: session, phase: phase)) }
    }

    /// Accepts one task without retrying its prompt or changing the normal launcher.
    public func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard running[id] == nil, !cancelled.contains(id), !Task.isCancelled else { throw CancellationError() }
        let (stream, sink) = AsyncThrowingStream.makeStream(of: AgentTaskEvent.self, bufferingPolicy: .bufferingOldest(32))
        running[id] = Running(request: request, sink: sink)
        defer {
            running[id]?.admitting = false
            for waiter in admissionWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        }
        if request.provider == .claude {
            if request.presentation == .terminal {
                let session = UUID().uuidString.lowercased()
                running[id]?.session = session; bySession[session] = id
                // Claude supports caller-supplied session IDs. Its SessionStart
                // callback confirms startup; this event only requests presentation.
                ready(id, session: session)
                startupDeadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await self?.claudeStartupExpired(id)
                }
            } else { startBackgroundClaude(id, request: request) }
            return stream
        }
        do {
            let server = try await server()
            try checkCancellation(id)
            var params: [String: ChiefJSON] = [
                "cwd": .string(request.workingDirectory.path), "approvalPolicy": .string("never"),
                "sandbox": .string("danger-full-access"),
                "developerInstructions": .string(AgentTaskContext.text(id: id, request: request, command: taskCommand)),
            ]
            if let model = request.model { params["model"] = .string(model) }
            let created = try await server.request("thread/start", .object(params))
            guard let session = created["thread"]?["id"]?.string else { throw AgentCodexConnection.Failure.rpc("Missing thread ID") }
            running[id]?.session = session; bySession[session] = id
            try checkCancellation(id)
            var turn: [String: ChiefJSON] = [
                "threadId": .string(session),
                "input": .array([.object(["type": .string("text"), "text": .string(request.prompt)])]),
                "approvalPolicy": .string("never"), "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
            ]
            if let effort = request.effort { turn["effort"] = .string(effort) }
            let accepted = try await server.request("turn/start", .object(turn))
            running[id]?.turn = accepted["turn"]?["id"]?.string ?? running[id]?.turn
            // A real accepted turn makes this a managed task, not an empty-thread
            // reservation that rewrites ordinary `codex` launch behavior.
            ready(id, session: session)
            emit(.running, id: id)
        } catch {
            if error is CancellationError {
                running[id]?.ready = true
                emit(.cancelled, id: id)
                end(id)
                return stream
            }
            uncertain.insert(id)
            // Preserve the exact thread even when turn acceptance is uncertain.
            // Never retry a timed-out prompt; the user can inspect this session.
            if let session = running[id]?.session { ready(id, session: session) }
            else { running[id]?.ready = true }
            emit(.disconnected(String(describing: error)), id: id)
            end(id)
        }
        return stream
    }

    /// Confirms provider interruption before the coordinator records cancellation.
    public func cancel(id: UUID) async throws {
        cancelled.insert(id)
        if running[id]?.admitting == true {
            await withCheckedContinuation { admissionWaiters[id, default: []].append($0) }
        }
        guard let task = running[id] else {
            if uncertain.contains(id) { throw AgentCodexConnection.Failure.rpc("Provider state is unknown; inspect the session before retrying") }
            return
        }
        if let brain = claudeBrains[id] {
            await brain.interrupt(conversation: ConversationID(id.uuidString))
            await brain.shutdown()
        } else if task.request.provider == .claude {
            try await cancelTerminal(id)
        } else if let session = task.session, let turn = task.turn, let connection {
            _ = try await connection.request("turn/interrupt", .object(["threadId": .string(session), "turnId": .string(turn)]))
        } else {
            throw AgentCodexConnection.Failure.rpc("Cannot confirm the task's active turn")
        }
        end(id)
    }

    /// Receives only this controlled Claude session's supported hook payload.
    public func reportClaude(id: UUID, session: String, event: String, text: String?) throws {
        guard let task = running[id], task.request.provider == .claude,
              task.request.presentation == .terminal else {
            throw AgentCodexConnection.Failure.rpc("Task/session mismatch")
        }
        guard task.session == session else {
            uncertain.insert(id)
            emit(.disconnected("claude_session_changed"), id: id)
            end(id)
            return
        }
        switch event {
        case "started":
            startupDeadlines.removeValue(forKey: id)?.cancel()
            emit(.running, id: id)
        case "completed": emit(.completed(String((text ?? "").prefix(1_000_000))), id: id)
        case "failed": emit(.failed(text ?? "claude_turn_failed"), id: id)
        case "ended": emit(.failed("claude_ended_without_completion"), id: id)
        default: throw AgentCodexConnection.Failure.rpc("Unknown task event")
        }
    }

    private func checkCancellation(_ id: UUID) throws {
        if cancelled.contains(id) || Task.isCancelled { throw CancellationError() }
    }

    private func server() async throws -> any AgentCodexTransport {
        if let startup { return try await startup.value }
        let connection = connectionFactory(socketPath)
        let token = UUID()
        connectionID = token
        self.connection = connection
        reader = Task { [weak self] in
            do { for try await value in connection.messages { await self?.receive(value) } }
            catch { await self?.lostConnection(String(describing: error), token: token) }
        }
        let task = Task {
            try await connection.connect()
            _ = try await connection.request("initialize", .object([
                "clientInfo": .object(["name": .string("cmux_managed_tasks"), "version": .string("0.1")]),
                "capabilities": .object([:]),
            ]))
            try await connection.notify("initialized", .object([:]))
            return connection
        }
        startup = task
        do { return try await task.value }
        catch {
            if token == connectionID {
                connectionID = UUID(); startup = nil; self.connection = nil
                reader?.cancel(); reader = nil
            }
            await connection.close()
            throw error
        }
    }

    private func receive(_ value: ChiefJSON) {
        guard let method = value["method"]?.string, let params = value["params"] else { return }
        let session = params["threadId"]?.string ?? params["thread"]?["id"]?.string
        if let session, method == "thread/status/changed", observedSessions.contains(session) {
            observationVersions[session, default: 0] += 1
            publishActivity(session, status: params["status"])
        }
        guard let session, let id = bySession[session], running[id] != nil else { return }
        switch method {
        case "turn/started":
            running[id]?.turn = params["turn"]?["id"]?.string
            emit(.running, id: id)
        case "thread/status/changed":
            let flags = params["status"]?["activeFlags"]?.array ?? []
            if flags.contains(where: { ["waitingOnApproval", "waitingOnUserInput"].contains($0.string ?? "") }) {
                emit(.needsInput("attention_required"), id: id)
            } else if params["status"]?["type"]?.string == "active" { emit(.running, id: id) }
        case "item/completed":
            if let item = params["item"], item["type"]?.string == "agentMessage",
               item["phase"]?.string != "commentary", let text = item["text"]?.string {
                running[id]?.answer = String(text.prefix(1_000_000))
            }
        case "turn/completed":
            let status = params["turn"]?["status"]?.string
            if status == "completed" { emit(.completed(running[id]?.answer ?? ""), id: id) }
            else if status == "interrupted", cancelled.contains(id) { emit(.cancelled, id: id) }
            else { emit(.failed(params["turn"]?["error"]?["message"]?.string ?? status ?? "Turn failed"), id: id) }
        case "item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "mcpServer/elicitation/request":
            // Never answer a control request automatically. The existing terminal
            // and ChatGPT phone client retain their normal answer path.
            emit(.needsInput("attention_required"), id: id)
        default: break
        }
    }

    private func ready(_ id: UUID, session: String) {
        guard var task = running[id] else { return }
        task.ready = true
        running[id] = task
        task.sink.yield(.session(session))
        for event in task.buffered { task.sink.yield(event) }
        running[id]?.buffered.removeAll()
        if task.finished { end(id) }
    }

    private func emit(_ event: AgentTaskEvent, id: UUID) {
        guard var task = running[id] else { return }
        let terminal: Bool
        switch event { case .completed, .cancelled, .failed: terminal = true; default: terminal = false }
        if task.ready { task.sink.yield(event) }
        else { task.buffered.append(event) }
        task.finished = terminal || task.finished
        running[id] = task
        if terminal && task.ready { end(id) }
    }

    private func end(_ id: UUID) {
        guard let task = running.removeValue(forKey: id) else { return }
        startupDeadlines.removeValue(forKey: id)?.cancel()
        task.sink.finish()
        if let session = task.session {
            bySession.removeValue(forKey: session)
            if task.request.provider == .codex, let connection {
                Task { _ = try? await connection.request("thread/unsubscribe", .object(["threadId": .string(session)])) }
            }
        }
        claudeReaders.removeValue(forKey: id)?.cancel()
        if let brain = claudeBrains.removeValue(forKey: id) { Task { await brain.shutdown() } }
    }

    private func lostConnection(_ reason: String, token: UUID) {
        guard token == connectionID else { return }
        connectionID = UUID()
        startup = nil; connection = nil
        let observed = observedSessions
        observedSessions.removeAll()
        for session in observed { observationVersions[session, default: 0] += 1; publishActivity(session, status: nil) }
        scheduleObservationRecovery()
        for (id, task) in running where task.request.provider == .codex {
            uncertain.insert(id)
            emit(.disconnected(reason), id: id); end(id)
        }
    }

    /// A bounded transport reconnect, never a prompt/turn retry or a daemon restart.
    private func scheduleObservationRecovery() {
        guard !desiredObservedSessions.isEmpty else { return }
        observationRecovery?.cancel()
        let generation = UUID(); recoveryGeneration = generation
        observationRecovery = Task { [weak self] in await self?.recoverObservations(generation) }
    }

    private func recoverObservations(_ generation: UUID) async {
        defer { if recoveryGeneration == generation { observationRecovery = nil } }
        for delay in [1, 3, 10] {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard recoveryGeneration == generation else { return }
            do {
                _ = try await server()
                for session in desiredObservedSessions { await observeSession(session) }
                return
            } catch { /* Keep status unknown; no work is replayed. */ }
        }
    }

    private func claudeStartupExpired(_ id: UUID) {
        guard running[id] != nil else { return }
        uncertain.insert(id)
        emit(.disconnected("claude_startup_unconfirmed"), id: id)
        end(id)
    }

    private func startBackgroundClaude(_ id: UUID, request: AgentTaskRequest) {
        let brain = claudeFactory(.init(model: request.model ?? "opus", effort: request.effort,
                                                        dangerouslySkipPermissions: true, extraArguments: ["--permission-mode", "bypassPermissions"]))
        claudeBrains[id] = brain
        running[id]?.ready = true
        let context = AgentTaskContext.text(id: id, request: request, command: taskCommand)
        claudeReaders[id] = Task { [weak self] in
            var answer = ""
            let input = ChiefTurnRequest(conversation: ConversationID(id.uuidString), resumeSession: nil,
                                         userText: request.prompt, attachmentPaths: [], replyContext: nil,
                                         systemPrompt: context, workingDirectory: request.workingDirectory,
                                         environment: ["CMUX_CLAUDE_HOOKS_DISABLED": "1"])
            do {
                for try await event in brain.run(input) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .session(let session): await self?.backgroundSession(id, session: session)
                    case .textDelta(let text): answer += text
                    case .finished: await self?.emit(.completed(answer), id: id)
                    case .failed(let error): await self?.emit(.failed(error), id: id)
                    case .approvalRequested, .question:
                        // Explicit headless execution has no interactive reply
                        // surface. Preserve the decision; never auto-answer it.
                        await self?.emit(.failed("background_input_required"), id: id)
                    default: break
                    }
                }
                await self?.backgroundStreamEnded(id, reason: "stream_ended_without_completion")
            } catch { await self?.backgroundStreamEnded(id, reason: String(describing: error)) }
        }
    }

    private func backgroundStreamEnded(_ id: UUID, reason: String) {
        guard running[id] != nil else { return }
        uncertain.insert(id)
        emit(.disconnected(reason), id: id)
        end(id)
    }

    private func backgroundSession(_ id: UUID, session: String) {
        running[id]?.session = session
        emit(.session(session), id: id); emit(.running, id: id)
    }
}
