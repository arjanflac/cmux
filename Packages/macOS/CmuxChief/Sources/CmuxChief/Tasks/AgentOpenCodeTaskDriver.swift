import Foundation

/// Managed OpenCode turns through ``AgentOpenCodeSession``, headless only.
///
/// OpenCode's `run` interface cannot answer approvals or questions and has no
/// safe terminal inspection yet, so terminal presentation and unrestricted
/// permissions are rejected rather than imitated. Cancellation succeeds only
/// when the session reports the turn cancelled.
actor AgentOpenCodeTaskDriver {
    private struct Turn {
        let operationID: UUID
        var sink: AgentTaskEventSink
        var settled: AgentTaskEvent?
    }

    private let session: AgentOpenCodeSession
    private let cancelDeadline: Duration
    private var turns: [UUID: Turn] = [:]
    private var outcomes = AgentTurnOutcomeWaiters()
    private var uncertain: Set<UUID> = []

    init(session: AgentOpenCodeSession, cancelDeadline: Duration) {
        self.session = session
        self.cancelDeadline = cancelDeadline
    }

    func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard request.presentation == .background else {
            throw AgentManagedTaskError.unsupported("opencode_terminal_presentation")
        }
        guard (request.permissionMode ?? .providerDefault) == .providerDefault else {
            throw AgentManagedTaskError.unsupported("opencode_unrestricted_permissions")
        }
        return try await run(id, operation: id, sessionID: nil, prompt: request.prompt,
                             directory: request.workingDirectory, model: request.model, effort: request.effort)
    }

    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard let sessionID = record.sessionID, !sessionID.isEmpty else { throw AgentManagedTaskError.missingSession }
        return try await run(id, operation: request.operationID, sessionID: sessionID, prompt: request.prompt,
                             directory: record.workingDirectory, model: record.model, effort: record.effort)
    }

    private func run(_ id: UUID, operation: UUID, sessionID: String?, prompt: String, directory: URL,
                     model: String?, effort: String?) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard turns[id] == nil else { throw AgentManagedTaskError.busy }
        let (stream, sink) = AgentTaskEventSink.make()
        turns[id] = Turn(operationID: operation, sink: sink)
        uncertain.remove(id)
        let events: AsyncThrowingStream<AgentTaskEvent, any Error>
        do {
            events = try await session.run(taskID: id, sessionID: sessionID, prompt: prompt, workingDirectory: directory,
                                           model: model, effort: effort)
        } catch {
            // Validation or spawn failed: the prompt never reached OpenCode.
            turns.removeValue(forKey: id)
            throw (error as? AgentManagedTaskError) ?? AgentManagedTaskError.notSent(String(describing: error))
        }
        Task { [weak self] in
            do {
                for try await event in events { await self?.receive(event, id: id, operation: operation) }
                await self?.ended(id, operation: operation, error: nil)
            } catch {
                await self?.ended(id, operation: operation, error: error)
            }
        }
        return stream
    }

    private func receive(_ incoming: AgentTaskEvent, id: UUID, operation: UUID) {
        guard turns[id]?.operationID == operation else { return }
        // The run process has no answer channel. Settle this submitted turn as failed,
        // retaining the exact session for an explicit interactive handoff.
        let event: AgentTaskEvent
        if case .needsInput(let detail) = incoming { event = .failed(detail) }
        else { event = incoming }
        turns[id]?.sink.yield(event)
        switch event {
        case .completed, .cancelled, .failed, .disconnected, .needsInput: turns[id]?.settled = event
        case .session, .running: break
        }
    }

    private func ended(_ id: UUID, operation: UUID, error: (any Error)?) {
        guard var turn = turns[id], turn.operationID == operation else { return }
        turns.removeValue(forKey: id)
        let outcome: AgentTaskEvent
        if let settled = turn.settled {
            outcome = settled
        } else {
            outcome = .disconnected(error.map { String(describing: $0) } ?? "stream_ended_without_completion")
            turn.sink.yield(outcome)
        }
        turn.sink.finish()
        if case .disconnected = outcome { uncertain.insert(id) }
        outcomes.record(outcome, id: id, operation: operation)
    }

    /// Stops the owned process group and waits for the session's reported outcome.
    func cancel(id: UUID) async throws {
        guard let turn = turns[id] else {
            throw uncertain.contains(id) ? AgentManagedTaskError.cancellationUnconfirmed : AgentManagedTaskError.noActiveTurn
        }
        let operation = turn.operationID
        try await session.cancel(taskID: id)
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

    func hasActiveTurn(id: UUID) -> Bool { turns[id] != nil }
}
