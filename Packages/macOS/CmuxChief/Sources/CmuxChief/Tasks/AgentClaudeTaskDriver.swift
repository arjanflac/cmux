import CmuxHomeCore
import Foundation

/// Managed Claude Code turns: headless through a strict ``ClaudeCodeBrain``, or a first terminal turn via hooks.
///
/// A headless conversation keeps its brain (one `claude -p` process) between
/// turns so a follow-up reuses the live session. At most `idleLimit` idle
/// brains are retained; the least recently used is stopped first, and
/// ``park(id:)`` stops one explicitly (for example before an interactive
/// terminal resumes the session, so there is never a second writer). A cold
/// follow-up resumes exactly the saved session and never falls back to a new
/// one or resends a prompt.
///
/// Permission requests stay pending as ``AgentTaskInteraction`` values until
/// answered; nothing is answered automatically. Bypass is used only for an
/// explicit ``AgentTaskRequest/PermissionMode/unrestricted`` request.
actor AgentClaudeTaskDriver {
    private struct Turn {
        let operationID: UUID
        var sink: AgentTaskEventSink
        let headless: Bool
        var session: String?
        var cancelRequested = false
        var settling = false
        var answer = ""
        var startupDeadline: Task<Void, Never>?

        init(operationID: UUID, sink: AgentTaskEventSink, headless: Bool, session: String? = nil) {
            self.operationID = operationID
            self.sink = sink
            self.headless = headless
            self.session = session
        }
    }

    private struct Retained {
        let driver: any AgentClaudeDriver
        var session: String?
        var lastUsed: Int
    }

    private let taskCommand: [String]
    private let cancelTerminal: @Sendable (UUID) async throws -> Void
    private let factory: @Sendable (ClaudeCodeBrain.Configuration) -> any AgentClaudeDriver
    private let cancelDeadline: Duration
    private let idleLimit: Int
    private var turns: [UUID: Turn] = [:]
    private var retained: [UUID: Retained] = [:]
    private var useCounter = 0
    private var pending: [UUID: [AgentTaskInteraction]] = [:]
    private var outcomes = AgentTurnOutcomeWaiters()
    private var uncertain: Set<UUID> = []

    init(taskCommand: [String], cancelTerminal: @escaping @Sendable (UUID) async throws -> Void,
         cancelDeadline: Duration, idleLimit: Int = 1,
         factory: @escaping @Sendable (ClaudeCodeBrain.Configuration) -> any AgentClaudeDriver) {
        self.taskCommand = taskCommand
        self.cancelTerminal = cancelTerminal
        self.cancelDeadline = cancelDeadline
        self.idleLimit = idleLimit
        self.factory = factory
    }

    /// The strict brain configuration of one managed conversation.
    ///
    /// Provider defaults pass no permission mode and, without a model, no
    /// `--model`; only an explicit unrestricted request selects bypass.
    static func configuration(model: String?, effort: String?,
                              permission: AgentTaskRequest.PermissionMode) -> ClaudeCodeBrain.Configuration {
        ClaudeCodeBrain.Configuration(model: model ?? "", effort: effort,
                                      extraArguments: permission == .unrestricted ? ["--permission-mode", "bypassPermissions"] : [],
                                      managedConversation: true)
    }

    // MARK: Submission

    func start(id: UUID, request: AgentTaskRequest) throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard turns[id] == nil, retained[id] == nil else { throw AgentManagedTaskError.busy }
        let (stream, sink) = AgentTaskEventSink.make()
        uncertain.remove(id)
        if request.presentation == .terminal {
            // Claude supports caller-supplied session IDs. Its SessionStart hook
            // confirms startup; this event only requests presentation.
            let session = UUID().uuidString.lowercased()
            turns[id] = Turn(operationID: id, sink: sink, headless: false, session: session)
            yield(.session(session), id: id)
            turns[id]?.startupDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.terminalStartupExpired(id, operation: id)
            }
            return stream
        }
        let driver = factory(Self.configuration(model: request.model, effort: request.effort,
                                                permission: request.permissionMode ?? .providerDefault))
        retained[id] = Retained(driver: driver, session: nil, lastUsed: nextUse())
        turns[id] = Turn(operationID: id, sink: sink, headless: true)
        let input = ChiefTurnRequest(conversation: ConversationID(id.uuidString), resumeSession: nil,
                                     userText: request.prompt, attachmentPaths: [], replyContext: nil,
                                     systemPrompt: AgentTaskContext.text(id: id, request: request, command: taskCommand),
                                     workingDirectory: request.workingDirectory,
                                     environment: ["CMUX_CLAUDE_HOOKS_DISABLED": "1"], promptID: id)
        consume(id, operation: id, events: driver.run(input))
        return stream
    }

    /// Submits once to the exact saved session, warm or by strict resume.
    ///
    /// A cold resume uses provider-default permissions: the record does not yet
    /// carry the original permission mode, and defaults never escalate.
    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard turns[id] == nil else { throw AgentManagedTaskError.busy }
        guard !uncertain.contains(id) else { throw AgentManagedTaskError.cancellationUnconfirmed }
        guard let session = record.sessionID, !session.isEmpty else { throw AgentManagedTaskError.missingSession }
        let driver: any AgentClaudeDriver
        if let live = retained[id] {
            guard live.session == session else { throw AgentManagedTaskError.sessionMismatch }
            driver = live.driver
            retained[id]?.lastUsed = nextUse()
        } else {
            driver = factory(Self.configuration(model: record.model, effort: record.effort, permission: record.permissionMode ?? .providerDefault))
            retained[id] = Retained(driver: driver, session: session, lastUsed: nextUse())
        }
        let (stream, sink) = AgentTaskEventSink.make()
        uncertain.remove(id)
        turns[id] = Turn(operationID: request.operationID, sink: sink, headless: true)
        let context = AgentTaskRequest(provider: .claude, prompt: record.title, workspaceID: record.workspaceID,
                                       workingDirectory: record.workingDirectory, presentation: .background,
                                       parentTaskID: record.parentTaskID, workspaceStableID: record.workspaceStableID)
        let input = ChiefTurnRequest(conversation: ConversationID(id.uuidString), resumeSession: session,
                                     userText: request.prompt, attachmentPaths: [], replyContext: nil,
                                     systemPrompt: AgentTaskContext.text(id: id, request: context, command: taskCommand),
                                     workingDirectory: record.workingDirectory,
                                     environment: ["CMUX_CLAUDE_HOOKS_DISABLED": "1"], promptID: request.operationID)
        consume(id, operation: request.operationID, events: driver.run(input))
        evictIdle()
        return stream
    }

    private func nextUse() -> Int {
        useCounter += 1
        return useCounter
    }

    private func consume(_ id: UUID, operation: UUID, events: AsyncThrowingStream<ChiefTurnEvent, any Error>) {
        Task { [weak self] in
            do {
                for try await event in events { await self?.receive(event, id: id, operation: operation) }
                await self?.streamEnded(id, operation: operation, error: nil)
            } catch {
                await self?.streamEnded(id, operation: operation, error: error)
            }
        }
    }

    private func receive(_ event: ChiefTurnEvent, id: UUID, operation: UUID) async {
        guard let turn = turns[id], turn.operationID == operation, !turn.settling else { return }
        switch event {
        case .session(let session):
            // A managed brain reports its session once Claude Code echoed this prompt.
            if let expected = retained[id]?.session, expected != session {
                await settle(id, outcome: .disconnected("claude_session_changed"))
                return
            }
            retained[id]?.session = session
            turns[id]?.session = session
            yield(.session(session), id: id)
            yield(.running, id: id)
        case .textDelta(let text):
            guard let size = turns[id]?.answer.utf8.count, size < 1_000_000 else { return }
            turns[id]?.answer += text
        case .approvalRequested(let requestID, let prompt, let options):
            let declineOnly = options == ClaudeCodeBrain.managedDeclineOnlyOptions
            let interaction = AgentTaskInteraction(
                taskID: id, requestID: requestID, kind: declineOnly ? .userInput : .toolApproval, method: "can_use_tool",
                summary: prompt, options: options, answer: declineOnly ? .denyOnly : .allowOrDeny,
                request: Data(ChiefJSON.object(["request_id": .string(requestID), "prompt": .string(prompt)]).compactText.utf8))
            pending[id, default: []].removeAll { $0.requestID == requestID }
            pending[id, default: []].append(interaction)
            yield(.needsInput(declineOnly ? "question_answer_unsupported" : "approval_required"), id: id)
        case .finished:
            end(id, outcome: .completed(turns[id]?.answer ?? ""))
        case .failed(let message):
            end(id, outcome: .failed(message))
        default:
            break
        }
    }

    private func streamEnded(_ id: UUID, operation: UUID, error: (any Error)?) async {
        guard let turn = turns[id], turn.operationID == operation, !turn.settling else { return }
        let outcome: AgentTaskEvent
        if let managed = error as? ClaudeManagedTurnError {
            outcome = Self.outcome(managed, cancelRequested: turn.cancelRequested)
        } else if let error {
            outcome = .disconnected(String(describing: error))
        } else {
            outcome = .disconnected("stream_ended_without_completion")
        }
        await settle(id, outcome: outcome)
    }

    /// Publishes uncertainty without treating lost completion evidence as permission to stop work.
    ///
    /// An uncertain retained process is quarantined: it cannot receive another
    /// prompt, be handed to an interactive writer, or be evicted as known idle.
    private func settle(_ id: UUID, outcome: AgentTaskEvent) async {
        guard turns[id]?.settling == false else { return }
        end(id, outcome: outcome)
    }

    /// What a managed brain's thrown outcome establishes about the turn.
    private static func outcome(_ error: ClaudeManagedTurnError, cancelRequested: Bool) -> AgentTaskEvent {
        switch error {
        case .interrupted: return cancelRequested ? .cancelled : .failed("claude_turn_interrupted")
        case .notSent(let reason): return .failed("claude_prompt_not_sent: " + reason)
        case .busy: return .failed("claude_conversation_busy")
        case .sessionChanged(let session): return .disconnected("claude_session_changed: " + session)
        case .unconfirmed(let reason): return .disconnected(reason)
        case .staleRequest: return .disconnected("claude_stale_request")
        }
    }

    private func yield(_ event: AgentTaskEvent, id: UUID) {
        turns[id]?.sink.yield(event)
    }

    private func end(_ id: UUID, outcome: AgentTaskEvent) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        turn.startupDeadline?.cancel()
        turn.sink.yield(outcome)
        turn.sink.finish()
        pending.removeValue(forKey: id)
        if case .disconnected = outcome { uncertain.insert(id) }
        outcomes.record(outcome, id: id, operation: turn.operationID)
        evictIdle()
    }

    /// Stops the least recently used idle brains beyond the retention bound.
    private func evictIdle() {
        let idle = retained.filter { turns[$0.key] == nil && !uncertain.contains($0.key) }
        guard idle.count > idleLimit else { return }
        for (id, entry) in idle.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(idle.count - idleLimit) {
            retained.removeValue(forKey: id)
            Task { await entry.driver.shutdown() }
        }
    }

    private func dropRetained(_ id: UUID) async {
        guard let entry = retained.removeValue(forKey: id) else { return }
        await entry.driver.shutdown()
    }

    // MARK: Terminal hooks

    /// Receives only this controlled terminal Claude session's supported hook payload.
    func reportClaude(id: UUID, session: String, event: String, text: String?) throws {
        guard let turn = turns[id], !turn.headless else { throw AgentManagedTaskError.noActiveTurn }
        guard turn.session == session else {
            end(id, outcome: .disconnected("claude_session_changed"))
            return
        }
        switch event {
        case "started":
            turns[id]?.startupDeadline?.cancel()
            turns[id]?.startupDeadline = nil
            yield(.running, id: id)
        case "completed": end(id, outcome: .completed(String((text ?? "").prefix(1_000_000))))
        case "failed": end(id, outcome: .failed(text ?? "claude_turn_failed"))
        // A session that ended after an explicit cancellation request is stopped work.
        case "ended": end(id, outcome: turn.cancelRequested ? .cancelled : .failed("claude_ended_without_completion"))
        default: throw AgentManagedTaskError.invalidResponse("unknown_task_event")
        }
    }

    private func terminalStartupExpired(_ id: UUID, operation: UUID) {
        guard turns[id]?.operationID == operation else { return }
        end(id, outcome: .disconnected("claude_startup_unconfirmed"))
    }

    // MARK: Interactions

    func interactions(id: UUID) -> [AgentTaskInteraction] { pending[id] ?? [] }

    /// Answers one pending permission through Claude Code's native control protocol.
    func respond(id: UUID, requestID: String, response: ChiefJSON) async throws {
        guard let turn = turns[id], let interaction = pending[id]?.first(where: { $0.requestID == requestID }),
              let driver = retained[id]?.driver else { throw AgentManagedTaskError.staleInteraction }
        let allow: Bool
        switch response["behavior"]?.string ?? "" {
        case "allow" where interaction.answer == .allowOrDeny: allow = true
        case "deny": allow = false
        default: throw AgentManagedTaskError.invalidResponse("behavior_must_be_allow_or_deny")
        }
        pending[id]?.removeAll { $0.requestID == requestID }
        do {
            try await driver.answerPermission(requestID, allow: allow, conversation: ConversationID(id.uuidString))
        } catch {
            throw AgentManagedTaskError.staleInteraction
        }
        if turns[id]?.operationID == turn.operationID, pending[id]?.isEmpty ?? true { yield(.running, id: id) }
    }

    // MARK: Cancellation and handoff

    /// Requests interruption and waits for Claude Code (or the terminal hook) to report the outcome.
    func cancel(id: UUID) async throws {
        guard let turn = turns[id] else {
            throw uncertain.contains(id) ? AgentManagedTaskError.cancellationUnconfirmed : AgentManagedTaskError.noActiveTurn
        }
        let operation = turn.operationID
        turns[id]?.cancelRequested = true
        if turn.headless {
            guard let driver = retained[id]?.driver else { throw AgentManagedTaskError.cancellationUnconfirmed }
            await driver.interrupt(conversation: ConversationID(id.uuidString))
        } else {
            try await cancelTerminal(id)
        }
        try AgentTurnOutcomeWaiters.confirmCancellation(await awaitOutcome(id, operation: operation))
    }

    private func awaitOutcome(_ id: UUID, operation: UUID) async -> AgentTaskEvent? {
        if let outcome = outcomes.outcome(id: id, operation: operation) { return outcome }
        guard turns[id]?.operationID == operation else { return nil }
        let token = UUID()
        let deadline = cancelDeadline
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            await self?.expireOutcome(id, token: token)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { outcomes.add(id: id, token: token, continuation: $0) }
    }

    private func expireOutcome(_ id: UUID, token: UUID) {
        outcomes.expire(id: id, token: token)
    }

    func hasActiveTurn(id: UUID) -> Bool { turns[id] != nil || uncertain.contains(id) }

    /// Stops an idle retained process so another client can own the session; never stops active work.
    func park(id: UUID) async throws {
        guard turns[id] == nil else { throw AgentManagedTaskError.busy }
        guard !uncertain.contains(id) else { throw AgentManagedTaskError.cancellationUnconfirmed }
        await dropRetained(id)
    }
}
