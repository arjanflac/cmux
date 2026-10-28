import Foundation
import CmuxHomeCore

/// Executes explicit managed conversations: Codex on the existing daemon, Claude Code, and OpenCode.
///
/// Every submission is sent at most once. A follow-up targets exactly the saved
/// provider session and never starts a fresh one; errors thrown by
/// ``continueTask(id:record:request:)`` mean nothing was sent, and uncertainty
/// after submission arrives as ``AgentTaskEvent/disconnected(_:)``.
///
/// Permissions are the provider's defaults unless the request explicitly asks
/// for ``AgentTaskRequest/PermissionMode/unrestricted``. Provider requests for a
/// decision stay pending as ``AgentTaskInteraction`` values; they are answered
/// only through ``respond(id:requestID:response:)``.
///
/// ``cancel(id:)`` interrupts at most the one owned live turn and returns only
/// after the provider reported it cancelled. An acknowledged interrupt request
/// is not proof: without a native outcome before the deadline it throws
/// ``AgentManagedTaskError/cancellationUnconfirmed``, and when the turn ended
/// otherwise it throws ``AgentManagedTaskError/cancellationSuperseded(_:)``.
///
/// ```swift
/// let backend = AgentManagedTaskBackend(socketPath: socket, cancelTerminal: { id in try await host.interrupt(id) })
/// let events = try await backend.continueTask(id: task, record: record,
///                                             request: AgentTaskTurnRequest(operationID: operation, prompt: "Next"))
/// ```
public actor AgentManagedTaskBackend: AgentTaskBackend {
    private let codex: AgentCodexTaskDriver
    private let claude: AgentClaudeTaskDriver
    private let openCode: AgentOpenCodeTaskDriver
    private var providers: [UUID: AgentTaskRequest.Provider] = [:]

    /// Uses the already-running managed daemon; it never creates a standalone server.
    ///
    /// - Parameters:
    ///   - socketPath: The verified existing Codex app-server control socket.
    ///   - taskCommand: The cmux task command quoted in delegation instructions.
    ///   - cancelTerminal: Interrupts a terminal-presented Claude task's view.
    public init(socketPath: String, taskCommand: [String] = ["cmux", "task"], cancelTerminal: @escaping @Sendable (UUID) async throws -> Void, toolRouter: AgentTaskToolRouter? = nil) {
        codex = AgentCodexTaskDriver(socketPath: socketPath, taskCommand: taskCommand, cancelDeadline: .seconds(30),
                                     connectionFactory: { AgentCodexConnection(path: $0) }, toolRouter: toolRouter)
        claude = AgentClaudeTaskDriver(taskCommand: taskCommand, cancelTerminal: cancelTerminal, cancelDeadline: .seconds(30),
                                       factory: { ClaudeCodeBrain(configuration: $0) })
        openCode = AgentOpenCodeTaskDriver(session: AgentOpenCodeSession(), cancelDeadline: .seconds(30))
    }

    init(connection: any AgentCodexTransport,
         claudeFactory: @escaping @Sendable (ClaudeCodeBrain.Configuration) -> any AgentClaudeDriver = { ClaudeCodeBrain(configuration: $0) },
         cancelTerminal: @escaping @Sendable (UUID) async throws -> Void = { _ in throw AgentManagedTaskError.unsupported("terminal") },
         openCode: AgentOpenCodeSession = AgentOpenCodeSession(),
         cancelDeadline: Duration = .seconds(30), idleClaudeLimit: Int = 1, toolRouter: AgentTaskToolRouter? = nil) {
        codex = AgentCodexTaskDriver(socketPath: "", taskCommand: ["cmux", "task"], cancelDeadline: cancelDeadline,
                                     connectionFactory: { _ in connection }, toolRouter: toolRouter)
        claude = AgentClaudeTaskDriver(taskCommand: ["cmux", "task"], cancelTerminal: cancelTerminal, cancelDeadline: cancelDeadline,
                                       idleLimit: idleClaudeLimit, factory: claudeFactory)
        self.openCode = AgentOpenCodeTaskDriver(session: openCode, cancelDeadline: cancelDeadline)
    }

    // MARK: Codex observation

    /// One event stream on the existing transport; never loads/resumes a thread or starts work.
    public func sessionActivityChanges() async -> AsyncStream<AgentSessionActivity> {
        await codex.sessionActivityChanges()
    }

    /// The last observed activity of an exact Codex session.
    public func sessionActivitySnapshot(_ session: String) async -> AgentSessionActivity? {
        await codex.sessionActivitySnapshot(session)
    }

    /// Reads only an exact saved session's metadata. Concurrent notifications win over the snapshot.
    public func observeSession(_ session: String) async {
        await codex.observeSession(session)
    }

    // MARK: AgentTaskBackend

    /// Accepts one task without retrying its prompt or changing the normal launcher.
    ///
    /// - Throws: ``AgentManagedTaskError`` when the request is rejected before
    ///   anything was sent, such as unsupported OpenCode terminal presentation.
    public func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard providers[id] == nil else { throw AgentManagedTaskError.busy }
        providers[id] = request.provider
        do {
            switch request.provider {
            case .codex: return try await codex.start(id: id, request: request)
            case .claude: return try await claude.start(id: id, request: request)
            case .opencode: return try await openCode.start(id: id, request: request)
            }
        } catch {
            providers.removeValue(forKey: id)
            throw error
        }
    }

    /// Submits once to the record's exact provider session.
    ///
    /// Codex reads the thread, rejects it when observed busy, joins it with
    /// `thread/resume` without overrides and sends `turn/start` once with
    /// `clientUserMessageId` set to the operation ID. Claude reuses the live
    /// process or strictly resumes the saved session. Cold continuations use
    /// provider-default permissions until the record carries the original mode.
    ///
    /// - Throws: ``AgentManagedTaskError`` before anything was sent: `busy`,
    ///   `missingSession`, `sessionMismatch`, `unsupported` or `notSent`.
    public func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        if let owner = providers[id], owner != record.provider { throw AgentManagedTaskError.sessionMismatch }
        providers[id] = record.provider
        switch record.provider {
        case .codex: return try await codex.continueTask(id: id, record: record, request: request)
        case .claude: return try await claude.continueTask(id: id, record: record, request: request)
        case .opencode: return try await openCode.continueTask(id: id, record: record, request: request)
        }
    }

    /// Interrupts only the live turn of `id` and returns once the provider confirmed cancellation.
    ///
    /// - Throws: ``AgentManagedTaskError/noActiveTurn``,
    ///   ``AgentManagedTaskError/cancellationUnconfirmed`` or
    ///   ``AgentManagedTaskError/cancellationSuperseded(_:)``; transport errors
    ///   from the interrupt request also leave the outcome unconfirmed.
    public func cancel(id: UUID) async throws {
        switch providers[id] {
        case .codex?: try await codex.cancel(id: id)
        case .claude?: try await claude.cancel(id: id)
        case .opencode?: try await openCode.cancel(id: id)
        case nil: throw AgentManagedTaskError.noActiveTurn
        }
    }

    // MARK: Interactions

    /// Provider requests pending in the live turn of `id`, oldest first.
    public func interactions(id: UUID) async -> [AgentTaskInteraction] {
        switch providers[id] {
        case .codex?: return await codex.interactions(id: id)
        case .claude?: return await claude.interactions(id: id)
        case .opencode?, nil: return []
        }
    }

    /// Answers one pending interaction exactly once.
    ///
    /// - Parameters:
    ///   - id: The managed task.
    ///   - requestID: ``AgentTaskInteraction/requestID`` of a pending interaction.
    ///   - response: A JSON object: the provider-native result for
    ///     ``AgentTaskInteraction/Answer/nativeResponse``, or
    ///     `{"behavior":"allow"}` / `{"behavior":"deny"}` for Claude Code.
    /// - Throws: ``AgentManagedTaskError/staleInteraction`` when the request is
    ///   no longer pending on the live connection or process,
    ///   ``AgentManagedTaskError/invalidResponse(_:)`` for an answer that does
    ///   not fit the request, and ``AgentManagedTaskError/unsupported(_:)``.
    public func respond(id: UUID, requestID: String, response: Data) async throws {
        let value: ChiefJSON
        do { value = try ChiefJSON(parsing: response) }
        catch { throw AgentManagedTaskError.invalidResponse("not_json") }
        try await respond(id: id, requestID: requestID, response: value)
    }

    func respond(id: UUID, requestID: String, response: ChiefJSON) async throws {
        switch providers[id] {
        case .codex?: try await codex.respond(id: id, requestID: requestID, response: response)
        case .claude?: try await claude.respond(id: id, requestID: requestID, response: response)
        case .opencode?: throw AgentManagedTaskError.unsupported("opencode_interactions")
        case nil: throw AgentManagedTaskError.staleInteraction
        }
    }

    // MARK: Presentation handoff

    /// Whether `id` has a live or uncertain owned turn; uncertainty is never treated as safely idle.
    public func hasActiveTurn(id: UUID) async -> Bool {
        switch providers[id] {
        case .codex?: return await codex.hasActiveTurn(id: id)
        case .claude?: return await claude.hasActiveTurn(id: id)
        case .opencode?: return await openCode.hasActiveTurn(id: id)
        case nil: return false
        }
    }

    /// Releases an idle worker's retained resources without archiving or deleting provider history.
    public func releaseIdleResources(id: UUID) async throws { try await park(id: id) }

    /// Releases an idle conversation's retained process so another client can own its session.
    ///
    /// Call before attaching an interactive Claude Code view, so the session never
    /// has two writers. Active work is never stopped to make room.
    ///
    /// - Throws: ``AgentManagedTaskError/busy`` while a turn is live.
    public func park(id: UUID) async throws {
        switch providers[id] {
        case .claude?: try await claude.park(id: id)
        case .codex?: if await codex.hasActiveTurn(id: id) { throw AgentManagedTaskError.busy }
        case .opencode?: if await openCode.hasActiveTurn(id: id) { throw AgentManagedTaskError.busy }
        case nil: return
        }
    }

    /// The provider-confirmed identity of the latest accepted Codex turn of `id`.
    public func providerTurn(id: UUID) async -> AgentManagedTurnIdentity? {
        await codex.providerTurn(id: id)
    }

    /// Receives only this controlled terminal Claude session's supported hook payload.
    public func reportClaude(id: UUID, session: String, event: String, text: String?) async throws {
        try await claude.reportClaude(id: id, session: session, event: event, text: text)
    }
}
