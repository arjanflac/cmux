import Foundation

/// Managed Codex turns and read-only session observation on the existing shared daemon.
///
/// Only a verified socket is used: the daemon is never embedded, restarted or
/// updated. A continuation targets exactly the saved thread: `thread/read`
/// rejects an observed busy thread, `thread/resume` only joins it (no
/// configuration, tool or instruction overrides) and `turn/start` is sent once
/// with `clientUserMessageId` set to the operation ID for correlation (not
/// deduplication).
///
/// Notifications are fenced by connection generation, session and the
/// accepted turn ID. Events that arrive before `turn/start` is acknowledged are
/// buffered (bounded) and replayed filtered to the accepted turn, so a
/// concurrent client's turn is never adopted. Cancellation interrupts the exact
/// accepted turn and succeeds only when Codex reports it interrupted.
actor AgentCodexTaskDriver {
    private struct Turn {
        let operationID: UUID
        var sink: AgentTaskEventSink
        var generation: UUID
        var session: String?
        var turnID: String?
        var submitted = false
        var acknowledged = false
        var admitting = true
        var early: [ChiefJSON] = []
        var earlyOverflow = false
        var foreignTurns: Set<String> = []
        var cancelRequested = false
        var answer = ""
        var handledToolCalls: Set<String> = []

        init(operationID: UUID, sink: AgentTaskEventSink, generation: UUID) {
            self.operationID = operationID
            self.sink = sink
            self.generation = generation
        }
    }

    private struct PendingRequest {
        let nativeID: ChiefJSON
        let params: ChiefJSON
        let generation: UUID
        let interaction: AgentTaskInteraction
    }

    /// Notifications buffered before `turn/start` is acknowledged.
    static let earlyEventLimit = 512
    private static let approvalDecisions: Set<String> = ["accept", "acceptForSession", "decline", "cancel"]

    private let socketPath: String
    private let taskCommand: [String]
    private let toolRouter: AgentTaskToolRouter?
    private let connectionFactory: @Sendable (String) -> any AgentCodexTransport
    private let cancelDeadline: Duration
    private var connection: (any AgentCodexTransport)?
    private var startup: Task<any AgentCodexTransport, any Error>?
    private var reader: Task<Void, Never>?
    private var connectionID = UUID()
    private var turns: [UUID: Turn] = [:]
    private var bySession: [String: UUID] = [:]
    private var uncertain: Set<UUID> = []
    private var identities: [UUID: AgentManagedTurnIdentity] = [:]
    private var pending: [UUID: [PendingRequest]] = [:]
    private var admissionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var outcomes = AgentTurnOutcomeWaiters()
    private var unsubscribing: [String: Task<Void, Never>] = [:]
    private var observationRecovery: Task<Void, Never>?
    private var recoveryGeneration = UUID()
    private var desiredObservedSessions: Set<String> = []
    private var observedSessions: Set<String> = []
    private var observationVersions: [String: Int] = [:]
    private var activitySinks: [UUID: AsyncStream<AgentSessionActivity>.Continuation] = [:]
    private var lastActivities: [String: AgentSessionActivity.Phase] = [:]

    init(socketPath: String, taskCommand: [String], cancelDeadline: Duration,
         connectionFactory: @escaping @Sendable (String) -> any AgentCodexTransport,
         toolRouter: AgentTaskToolRouter? = nil) {
        self.socketPath = socketPath
        self.taskCommand = taskCommand
        self.toolRouter = toolRouter
        self.cancelDeadline = cancelDeadline
        self.connectionFactory = connectionFactory
    }

    // MARK: Observation

    /// One event stream on the existing transport; never loads/resumes a thread or starts work.
    func sessionActivityChanges() -> AsyncStream<AgentSessionActivity> {
        let token = UUID()
        let pair = AsyncStream.makeStream(of: AgentSessionActivity.self, bufferingPolicy: .bufferingNewest(256))
        activitySinks[token] = pair.continuation
        for (session, phase) in lastActivities { pair.continuation.yield(.init(sessionID: session, phase: phase)) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeActivitySink(token) } }
        return pair.stream
    }

    func sessionActivitySnapshot(_ session: String) -> AgentSessionActivity? {
        lastActivities[session].map { AgentSessionActivity(sessionID: session, phase: $0) }
    }

    private func removeActivitySink(_ token: UUID) { activitySinks.removeValue(forKey: token) }

    /// Reads only an exact saved session's metadata. Concurrent notifications win over the snapshot.
    func observeSession(_ session: String) async {
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
            phase = Self.waitingOnUser(status) ? .attention : .working
        case "idle", "notLoaded": phase = .idle
        default: phase = .unknown
        }
        guard lastActivities[session] != phase else { return }
        lastActivities[session] = phase
        for sink in activitySinks.values { sink.yield(.init(sessionID: session, phase: phase)) }
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

    // MARK: Submission

    /// Creates a thread and submits the first turn once.
    func start(id: UUID, request: AgentTaskRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard turns[id] == nil else { throw AgentManagedTaskError.busy }
        try Task.checkCancellation()
        let (stream, sink) = AgentTaskEventSink.make()
        turns[id] = Turn(operationID: id, sink: sink, generation: connectionID)
        uncertain.remove(id)
        defer { finishAdmission(id) }
        // Provider defaults unless unrestricted work was explicitly requested.
        let unrestricted = request.permissionMode == .unrestricted
        let server: any AgentCodexTransport
        var turn: [String: ChiefJSON]
        do {
            server = try await self.server()
            turns[id]?.generation = connectionID
            try checkCancellation(id)
            var params: [String: ChiefJSON] = [
                "cwd": .string(request.workingDirectory.path),
                "developerInstructions": .string(AgentTaskContext.text(id: id, request: request, command: taskCommand)),
            ]
            if let toolRouter, await toolRouter.isEnabled() {
                params["dynamicTools"] = AgentTaskToolCatalog().tools()
                let config = try await server.request("config/read", .object(["cwd": .string(request.workingDirectory.path), "includeLayers": .bool(false)]))
                let inherited = config["config"]?["shell_environment_policy"]?["exclude"]?.array?.compactMap(\.string) ?? []
                let excluded = Array(Set(inherited + ["CMUX_*", "IN_CMUX"])).sorted()
                params["config"] = .object(["shell_environment_policy.exclude": .array(excluded.map(ChiefJSON.string))])
            }
            if unrestricted {
                params["approvalPolicy"] = .string("never")
                params["sandbox"] = .string("danger-full-access")
            }
            if let model = request.model { params["model"] = .string(model) }
            let created = try await server.request("thread/start", .object(params))
            guard let session = created["thread"]?["id"]?.string, !session.isEmpty else {
                throw AgentManagedTaskError.notSent("thread_start_missing_id")
            }
            try bind(id, session: session)
            turn = Self.turnParams(session: session, prompt: request.prompt, operationID: id)
            if unrestricted {
                turn["approvalPolicy"] = .string("never")
                turn["sandboxPolicy"] = .object(["type": .string("dangerFullAccess")])
            }
            if let effort = request.effort { turn["effort"] = .string(effort) }
        } catch {
            try abandonBeforeSubmission(id, error: error)
            return stream
        }
        await submit(id, server: server, params: turn)
        return stream
    }

    /// Submits once to the exact saved thread without overriding its configuration.
    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        guard turns[id] == nil else { throw AgentManagedTaskError.busy }
        guard let session = record.sessionID, !session.isEmpty else { throw AgentManagedTaskError.missingSession }
        try Task.checkCancellation()
        let (stream, sink) = AgentTaskEventSink.make()
        turns[id] = Turn(operationID: request.operationID, sink: sink, generation: connectionID)
        uncertain.remove(id)
        defer { finishAdmission(id) }
        let server: any AgentCodexTransport
        do {
            server = try await self.server()
            turns[id]?.generation = connectionID
            // Our own earlier unsubscribe must not land after this resume.
            if let unsubscribe = unsubscribing.removeValue(forKey: session) { await unsubscribe.value }
            try checkCancellation(id)
            let read = try await server.request("thread/read", .object(["threadId": .string(session), "includeTurns": .bool(false)]))
            try Self.requireIdle(read["thread"]?["status"], required: true)
            try bind(id, session: session)
            try checkCancellation(id)
            // Joins the exact thread; omitted fields keep its saved configuration.
            let resumed = try await server.request("thread/resume", .object([
                "threadId": .string(session), "excludeTurns": .bool(true),
            ]))
            if let resumedID = resumed["thread"]?["id"]?.string, resumedID != session {
                throw AgentManagedTaskError.sessionMismatch
            }
            try Self.requireIdle(resumed["thread"]?["status"], required: false)
        } catch {
            try abandonBeforeSubmission(id, error: error)
            return stream
        }
        await submit(id, server: server, params: Self.turnParams(session: session, prompt: request.prompt,
                                                                 operationID: request.operationID))
        return stream
    }

    private static func turnParams(session: String, prompt: String, operationID: UUID) -> [String: ChiefJSON] {
        [
            "threadId": .string(session),
            "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
            "clientUserMessageId": .string(operationID.uuidString.lowercased()),
        ]
    }

    /// An idle or unloaded thread may receive a turn; an observed active one is busy.
    private static func requireIdle(_ status: ChiefJSON?, required: Bool) throws {
        switch status?["type"]?.string {
        case "idle", "notLoaded": return
        case "active": throw AgentManagedTaskError.busy
        case nil where !required: return
        case let other: throw AgentManagedTaskError.notSent("thread_status_" + (other ?? "unknown"))
        }
    }

    private func bind(_ id: UUID, session: String) throws {
        if let owner = bySession[session], owner != id { throw AgentManagedTaskError.busy }
        bySession[session] = id
        turns[id]?.session = session
    }

    /// Sends `turn/start` exactly once; any failure after sending is uncertainty.
    private func submit(_ id: UUID, server: any AgentCodexTransport, params: [String: ChiefJSON]) async {
        guard turns[id] != nil else { return }
        if turns[id]?.cancelRequested == true || Task.isCancelled {
            end(id, outcome: .cancelled)
            return
        }
        turns[id]?.submitted = true
        do {
            let accepted = try await server.request("turn/start", .object(params))
            guard let turnID = accepted["turn"]?["id"]?.string, !turnID.isEmpty else {
                end(id, outcome: .disconnected("acceptance_unknown: turn_ack_missing_id"))
                return
            }
            acknowledge(id, turnID: turnID)
        } catch {
            // Never retried: the prompt may have been accepted.
            end(id, outcome: .disconnected("acceptance_unknown: \(error)"))
        }
    }

    /// Before `turn/start` nothing was sent: cancellation is definite, anything else rejects.
    private func abandonBeforeSubmission(_ id: UUID, error: any Error) throws {
        if error is CancellationError, turns[id]?.cancelRequested == true {
            end(id, outcome: .cancelled)
            return
        }
        let rejection = (error as? AgentManagedTaskError) ?? .notSent(String(describing: error))
        end(id, outcome: .failed(rejection.description), deliver: false)
        throw rejection
    }

    private func checkCancellation(_ id: UUID) throws {
        if turns[id]?.cancelRequested == true || Task.isCancelled { throw CancellationError() }
    }

    private func finishAdmission(_ id: UUID) {
        turns[id]?.admitting = false
        for waiter in admissionWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    private func acknowledge(_ id: UUID, turnID: String) {
        guard var turn = turns[id], let session = turn.session else { return }
        turn.turnID = turnID
        turn.acknowledged = true
        let early = turn.early
        turn.early = []
        turns[id] = turn
        identities[id] = AgentManagedTurnIdentity(operationID: turn.operationID, sessionID: session, providerTurnID: turnID,
                                                  joinedExistingTurn: turn.foreignTurns.contains(turnID))
        yield(.session(session), id: id)
        yield(.running, id: id)
        if turn.earlyOverflow {
            end(id, outcome: .disconnected("event_buffer_overflow"))
            return
        }
        for value in early {
            guard turns[id]?.operationID == turn.operationID else { return }
            route(value, id: id)
        }
    }

    // MARK: Events

    private func receive(_ value: ChiefJSON, token: UUID) {
        guard token == connectionID, let method = value["method"]?.string else { return }
        let params = value["params"] ?? .null
        guard let session = params["threadId"]?.string ?? params["thread"]?["id"]?.string else { return }
        if method == "thread/status/changed", observedSessions.contains(session) {
            observationVersions[session, default: 0] += 1
            publishActivity(session, status: params["status"])
        }
        guard let id = bySession[session], let turn = turns[id], turn.generation == token else { return }
        guard turn.acknowledged else {
            // Turns announced before our submission belong to another client.
            if method == "turn/started", !turn.submitted, let started = params["turn"]?["id"]?.string {
                turns[id]?.foreignTurns.insert(started)
            }
            if turn.early.count < Self.earlyEventLimit { turns[id]?.early.append(value) }
            else { turns[id]?.earlyOverflow = true }
            return
        }
        route(value, id: id)
    }

    /// Applies one event of the accepted turn; other turns' events are dropped.
    private func route(_ value: ChiefJSON, id: UUID) {
        guard let turn = turns[id], let own = turn.turnID, let method = value["method"]?.string else { return }
        let params = value["params"] ?? .null
        switch method {
        case "serverRequest/resolved":
            // Answered elsewhere (another client) or withdrawn by Codex.
            if let key = Self.requestKey(params["requestId"]) { removeRequest(id, key: key) }
            return
        case "thread/status/changed":
            let status = params["status"]
            if Self.waitingOnUser(status) { yield(.needsInput("attention_required"), id: id) }
            else if status?["type"]?.string == "active", pending[id]?.isEmpty ?? true { yield(.running, id: id) }
            return
        default:
            break
        }
        guard (params["turnId"]?.string ?? params["turn"]?["id"]?.string) == own else { return }
        if let nativeID = value["id"], !nativeID.isNull {
            if method == "item/tool/call", params["namespace"]?.string == "cmux_tasks", params["tool"]?.string == "task" {
                coordinatorTool(nativeID: nativeID, params: params, taskID: id)
                return
            }
            register(nativeID, method: method, params: params, id: id)
            return
        }
        switch method {
        case "turn/started":
            yield(.running, id: id)
        case "item/completed":
            if let item = params["item"], item["type"]?.string == "agentMessage",
               item["phase"]?.string != "commentary", let text = item["text"]?.string {
                turns[id]?.answer = String(text.prefix(1_000_000))
            }
        case "turn/completed":
            let outcome: AgentTaskEvent
            switch params["turn"]?["status"]?.string {
            case "completed": outcome = .completed(turn.answer)
            case "interrupted": outcome = turn.cancelRequested ? .cancelled : .failed("turn_interrupted")
            case "failed": outcome = .failed(params["turn"]?["error"]?["message"]?.string ?? "turn_failed")
            case let other: outcome = .disconnected("turn_completed_status_" + (other ?? "missing"))
            }
            end(id, outcome: outcome)
        default:
            break
        }
    }

    private static func waitingOnUser(_ status: ChiefJSON?) -> Bool {
        (status?["activeFlags"]?.array ?? []).contains { ["waitingOnApproval", "waitingOnUserInput"].contains($0.string ?? "") }
    }

    private func yield(_ event: AgentTaskEvent, id: UUID) {
        turns[id]?.sink.yield(event)
    }

    /// The driver supplies identity; model arguments cannot claim another parent or turn.
    private func coordinatorTool(nativeID: ChiefJSON, params: ChiefJSON, taskID: UUID) {
        guard let toolRouter, let turn = turns[taskID], let session = turn.session, let providerTurn = turn.turnID,
              let callID = params["callId"]?.string, !callID.isEmpty, callID.utf8.count <= 256,
              !turn.handledToolCalls.contains(callID), turn.handledToolCalls.count < 512,
              let connection else { return }
        turns[taskID]?.handledToolCalls.insert(callID)
        let rawArguments = params["arguments"] ?? .object([:])
        // Invalid tool arguments still need one owned validation reply. Keep actual
        // provider identities and let the broker reject an empty validation object.
        let args = (rawArguments.object == nil ? ChiefJSON.object([:]) : rawArguments).line
        guard args.count <= 262_144 else { return }
        let call = AgentTaskToolCall(taskID: taskID, sessionID: session, providerTurnID: providerTurn,
                                    callID: callID, connectionGeneration: turn.generation, arguments: args)
        Task { [weak self] in
            let result: ChiefJSON
            do {
                let bytes = try await toolRouter.call(call)
                var value = try ChiefJSON(parsing: bytes)
                guard value["_cmux_should_respond"] == .bool(true) else { return }
                let failed = value["_cmux_tool_error"] == .bool(true)
                if case .object(var object) = value {
                    object.removeValue(forKey: "_cmux_should_respond"); object.removeValue(forKey: "_cmux_tool_error")
                    value = .object(object)
                }
                result = .object(["success": .bool(!failed), "contentItems": .array([
                    .object(["type": .string("inputText"), "text": .string(value.compactText)])])])
            } catch {
                // No authoritative ownership receipt: another attached client may own
                // the response. Keep attention visible instead of racing a second reply.
                await self?.toolBridgeUnavailable(call)
                return
            }
            guard let self, await self.mayAnswer(call) else { return }
            try? await connection.respond(id: nativeID, result: result)
        }
    }

    private func toolBridgeUnavailable(_ call: AgentTaskToolCall) {
        guard mayAnswer(call) else { return }
        yield(.needsInput("coordination_bridge_unavailable"), id: call.taskID)
    }

    private func mayAnswer(_ call: AgentTaskToolCall) -> Bool {
        connectionID == call.connectionGeneration && turns[call.taskID]?.turnID == call.providerTurnID
            && turns[call.taskID]?.session == call.sessionID
    }

    private func end(_ id: UUID, outcome: AgentTaskEvent, deliver: Bool = true) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        if deliver {
            // Preserve the exact thread even when acceptance is uncertain.
            if !turn.acknowledged, let session = turn.session { turn.sink.yield(.session(session)) }
            turn.sink.yield(outcome)
        }
        turn.sink.finish()
        pending.removeValue(forKey: id)
        if case .disconnected = outcome { uncertain.insert(id) }
        outcomes.record(outcome, id: id, operation: turn.operationID)
        guard let session = turn.session, bySession[session] == id else { return }
        bySession.removeValue(forKey: session)
        guard let connection, turn.generation == connectionID else { return }
        let previous = unsubscribing[session]
        unsubscribing[session] = Task {
            await previous?.value
            _ = try? await connection.request("thread/unsubscribe", .object(["threadId": .string(session)]))
        }
    }

    // MARK: Interactions

    private static func requestKey(_ id: ChiefJSON?) -> String? {
        switch id {
        case .string(let value)?: return value
        case .number(let value)? where value.rounded() == value && abs(value) < 9_007_199_254_740_992:
            return String(Int64(value))
        default: return nil
        }
    }

    private func register(_ nativeID: ChiefJSON, method: String, params: ChiefJSON, id: UUID) {
        guard let key = Self.requestKey(nativeID), let turn = turns[id] else {
            yield(.needsInput("attention_unanswerable_request"), id: id)
            return
        }
        let kind: AgentTaskInteraction.Kind
        switch method {
        case "item/commandExecution/requestApproval": kind = .commandApproval
        case "item/fileChange/requestApproval": kind = .fileChangeApproval
        case "item/permissions/requestApproval": kind = .permissionApproval
        case "item/tool/requestUserInput": kind = .userInput
        case "mcpServer/elicitation/request": kind = .elicitation
        default: kind = .unknown
        }
        let offered = (params["availableDecisions"]?.array ?? []).compactMap { $0.string ?? $0.object?.keys.first }
        let options: [String]
        switch kind {
        case .commandApproval, .fileChangeApproval: options = offered.isEmpty ? ["accept", "acceptForSession", "decline", "cancel"] : offered
        case .elicitation: options = ["accept", "decline", "cancel"]
        default: options = offered
        }
        let summary = params["reason"]?.string ?? params["command"]?.string ?? params["message"]?.string ?? method
        let interaction = AgentTaskInteraction(
            taskID: id, requestID: key, kind: kind, method: method, summary: String(summary.prefix(4096)),
            options: options, answer: kind == .unknown ? .unsupported : .nativeResponse,
            request: Data(params.compactText.utf8))
        pending[id, default: []].removeAll { $0.interaction.requestID == key }
        pending[id, default: []].append(PendingRequest(nativeID: nativeID, params: params, generation: turn.generation,
                                                       interaction: interaction))
        // Never answered automatically; it stays pending until the user decides.
        yield(.needsInput(kind == .unknown ? "attention_unsupported_request" : "approval_required"), id: id)
    }

    private func removeRequest(_ id: UUID, key: String) {
        guard pending[id]?.contains(where: { $0.interaction.requestID == key }) == true else { return }
        pending[id]?.removeAll { $0.interaction.requestID == key }
        if pending[id]?.isEmpty ?? true { yield(.running, id: id) }
    }

    func interactions(id: UUID) -> [AgentTaskInteraction] {
        (pending[id] ?? []).filter { $0.generation == connectionID }.map(\.interaction)
    }

    /// Delivers one validated provider-native answer for a request of the live turn.
    func respond(id: UUID, requestID: String, response: ChiefJSON) async throws {
        guard let request = pending[id]?.first(where: { $0.interaction.requestID == requestID }),
              request.generation == connectionID, turns[id]?.generation == connectionID,
              let connection else { throw AgentManagedTaskError.staleInteraction }
        try Self.validate(response, for: request)
        // One-shot: removed before sending, so a concurrent duplicate is stale.
        pending[id]?.removeAll { $0.interaction.requestID == requestID }
        try await connection.respond(id: request.nativeID, result: response)
        if pending[id]?.isEmpty ?? true { yield(.running, id: id) }
    }

    private static func validate(_ response: ChiefJSON, for request: PendingRequest) throws {
        guard response.object != nil else { throw AgentManagedTaskError.invalidResponse("not_an_object") }
        switch request.interaction.kind {
        case .commandApproval, .fileChangeApproval:
            guard let decision = response["decision"] else { throw AgentManagedTaskError.invalidResponse("missing_decision") }
            let offered = request.params["availableDecisions"]?.array
            if let offered, !offered.isEmpty {
                guard offered.contains(decision) else { throw AgentManagedTaskError.invalidResponse("decision_not_offered") }
            } else {
                guard let value = decision.string, approvalDecisions.contains(value) else {
                    throw AgentManagedTaskError.invalidResponse("unknown_decision")
                }
            }
        case .userInput:
            guard let answers = response["answers"]?.object else { throw AgentManagedTaskError.invalidResponse("missing_answers") }
            let questions = Set((request.params["questions"]?.array ?? []).compactMap { $0["id"]?.string })
            for (question, answer) in answers {
                guard questions.contains(question), let values = answer["answers"]?.array,
                      values.allSatisfy({ $0.string != nil }) else {
                    throw AgentManagedTaskError.invalidResponse("answer_not_requested")
                }
            }
        case .elicitation:
            guard let action = response["action"]?.string, ["accept", "decline", "cancel"].contains(action) else {
                throw AgentManagedTaskError.invalidResponse("unknown_action")
            }
        case .permissionApproval:
            guard response["permissions"] != nil else { throw AgentManagedTaskError.invalidResponse("missing_permissions") }
        case .toolApproval, .unknown:
            throw AgentManagedTaskError.unsupported("codex_request_" + request.interaction.method)
        }
    }

    // MARK: Cancellation

    /// Interrupts only the accepted turn and waits for Codex to report its outcome.
    func cancel(id: UUID) async throws {
        guard let turn = turns[id] else {
            throw uncertain.contains(id) ? AgentManagedTaskError.cancellationUnconfirmed : AgentManagedTaskError.noActiveTurn
        }
        let operation = turn.operationID
        turns[id]?.cancelRequested = true
        if turns[id]?.admitting == true {
            await withCheckedContinuation { admissionWaiters[id, default: []].append($0) }
        }
        if let outcome = outcomes.outcome(id: id, operation: operation) {
            try AgentTurnOutcomeWaiters.confirmCancellation(outcome)
            return
        }
        guard let live = turns[id], live.operationID == operation, let session = live.session,
              let turnID = live.turnID, live.generation == connectionID, let connection else {
            throw AgentManagedTaskError.cancellationUnconfirmed
        }
        do {
            // An acknowledgment only means the request was received.
            _ = try await connection.request("turn/interrupt", .object([
                "threadId": .string(session), "turnId": .string(turnID),
            ]))
        } catch {
            if let outcome = outcomes.outcome(id: id, operation: operation) {
                try AgentTurnOutcomeWaiters.confirmCancellation(outcome)
                return
            }
            throw error
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

    func hasActiveTurn(id: UUID) -> Bool { turns[id] != nil }

    func providerTurn(id: UUID) -> AgentManagedTurnIdentity? { identities[id] }

    // MARK: Connection

    private func server() async throws -> any AgentCodexTransport {
        if let startup { return try await startup.value }
        let connection = connectionFactory(socketPath)
        let token = UUID()
        connectionID = token
        self.connection = connection
        reader = Task { [weak self] in
            do { for try await value in connection.messages { await self?.receive(value, token: token) } }
            catch { await self?.lostConnection(String(describing: error), token: token) }
        }
        let task = Task {
            try await connection.connect()
            _ = try await connection.request("initialize", .object([
                "clientInfo": .object(["name": .string("cmux_managed_tasks"), "version": .string("0.1")]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
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

    private func lostConnection(_ reason: String, token: UUID) {
        guard token == connectionID else { return }
        connectionID = UUID()
        startup = nil; connection = nil
        unsubscribing.removeAll()
        let observed = observedSessions
        observedSessions.removeAll()
        for session in observed { observationVersions[session, default: 0] += 1; publishActivity(session, status: nil) }
        scheduleObservationRecovery()
        // Answers to the old connection's requests can never be delivered.
        pending.removeAll()
        for id in Array(turns.keys) { end(id, outcome: .disconnected(reason)) }
    }
}
