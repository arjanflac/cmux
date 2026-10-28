import Foundation
import CmuxHomeCore
import Testing
@testable import CmuxChief

@Suite("Managed provider protocol")
struct AgentManagedTaskBackendTests {
    private func request(_ permission: AgentTaskRequest.PermissionMode = .providerDefault) -> AgentTaskRequest {
        AgentTaskRequest(provider: .codex, prompt: "Reply once", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), model: "gpt-6-luna", effort: "low",
                         presentation: .background, permissionMode: permission)
    }

    private func record(_ id: UUID, provider: AgentTaskRequest.Provider = .codex, session: String) -> AgentTaskRecord {
        var input = request()
        input.provider = provider
        var record = AgentTaskRecord(id: id, request: input, now: Date())
        record.sessionID = session
        record.phase = .completed
        return record
    }

    private func collect(_ stream: AsyncThrowingStream<AgentTaskEvent, any Error>) async -> [AgentTaskEvent] {
        var events: [AgentTaskEvent] = []
        do { for try await event in stream { events.append(event) } }
        catch { events.append(.disconnected("thrown: \(error)")) }
        return events
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func coordinatorToolsPreserveIsolationAndAnswerOneExactProviderCall(_ failed: Bool) async throws {
        let router = AgentTaskToolRouter(), transport = TaskProtocolFixture(turns: [.hold])
        let id = UUID()
        await router.install(enabled: { true }, handler: { call in
            #expect(call.taskID == id)
            #expect(call.sessionID == "fixture-session")
            #expect(call.providerTurnID == "fixture-turn-1")
            #expect(call.callID == "tool-call-1")
            let arguments = try ChiefJSON(parsing: call.arguments)
            #expect(arguments.object != nil)
            return Data("{\"_cmux_should_respond\":true,\"_cmux_tool_error\":\(failed),\"ok\":true}".utf8)
        })
        let backend = AgentManagedTaskBackend(connection: transport, toolRouter: router)
        var iterator = try await backend.start(id: id, request: request()).makeAsyncIterator()
        #expect(try await iterator.next() == .session("fixture-session"))
        #expect(try await iterator.next() == .running)
        let params = try #require(await transport.params("thread/start").first)
        #expect(params["dynamicTools"]?.array?.first?["name"] == "cmux_tasks")
        #expect(params["config"]?["shell_environment_policy.exclude"] == ["CMUX_*", "IN_CMUX", "PRIVATE_EXISTING"])
        await transport.coordinatorTool(arguments: failed ? .array([]) : ["action": "inbox"])
        await transport.waitForResponses(1)
        let response = try #require(await transport.responseResults.first)
        #expect(response["success"] == .bool(!failed))
        let text = try #require(response["contentItems"]?.array?.first?["text"]?.string)
        #expect(!text.contains("_cmux_should_respond"))
        #expect(!text.contains("_cmux_tool_error"))
        #expect(await transport.responseIDs == [42])
        await transport.coordinatorTool() // Native duplicate of the same call is not dispatched twice.
        await transport.finishTurn("fixture-turn-1", status: "completed")
        while try await iterator.next() != nil {}
        #expect(await transport.responseIDs == [42])
    }

    @Test func disabledCoordinatorDoesNotAdvertiseToolsOrOverrideThreadConfiguration() async throws {
        let router = AgentTaskToolRouter(), transport = TaskProtocolFixture()
        await router.install(enabled: { false }, handler: { _ in Issue.record("Disabled router was called"); return Data() })
        let backend = AgentManagedTaskBackend(connection: transport, toolRouter: router)
        _ = await collect(try await backend.start(id: UUID(), request: request()))
        let params = try #require(await transport.params("thread/start").first)
        #expect(params["dynamicTools"] == nil)
        #expect(params["config"] == nil)
        #expect(await transport.methods.contains("config/read") == false)
    }

    // MARK: Observation

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

    // MARK: Codex submission

    @Test func completionBeforeTurnAcknowledgmentPreservesIdentityAndResult() async throws {
        let transport = TaskProtocolFixture()
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        let events = await collect(try await backend.start(id: id, request: request()))
        #expect(events == [.session("fixture-session"), .running, .completed("Confirmed result")])
        #expect(await transport.methods.filter { $0 == "turn/start" }.count == 1)
        #expect(await transport.params("turn/start").first?["clientUserMessageId"] == .string(id.uuidString.lowercased()))
    }

    @Test func twoTurnsContinueTheExactThreadWithoutOverridingIt() async throws {
        let transport = TaskProtocolFixture(turns: [.complete("First answer"), .complete("Second answer")])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        #expect(await collect(try await backend.start(id: id, request: request())).last == .completed("First answer"))
        let operation = UUID()
        let second = await collect(try await backend.continueTask(
            id: id, record: record(id, session: "fixture-session"),
            request: AgentTaskTurnRequest(operationID: operation, prompt: "Continue")))
        #expect(second == [.session("fixture-session"), .running, .completed("Second answer")])
        let methods = await transport.methods
        // Final detach is asynchronous; its arrival must not change whether the
        // preceding continuation preserved configuration and awaited prior detach.
        #expect(methods.filter { $0 != "thread/unsubscribe" } == ["initialize", "thread/start", "turn/start",
                                            "thread/read", "thread/resume", "turn/start"])
        let detached = try #require(methods.firstIndex(of: "thread/unsubscribe"))
        let resumed = try #require(methods.firstIndex(of: "thread/resume"))
        #expect(detached < resumed)
        #expect(await transport.params("thread/resume") == [["threadId": "fixture-session", "excludeTurns": true]])
        let followUp = try #require(await transport.params("turn/start").last?.object)
        #expect(Set(followUp.keys) == ["threadId", "input", "clientUserMessageId"])
        #expect(followUp["threadId"] == "fixture-session")
        #expect(followUp["clientUserMessageId"] == .string(operation.uuidString.lowercased()))
        #expect(await backend.providerTurn(id: id) == AgentManagedTurnIdentity(
            operationID: operation, sessionID: "fixture-session", providerTurnID: "fixture-turn-2", joinedExistingTurn: false))
    }

    @Test func anotherClientsTurnIsNeverAdoptedBeforeAcknowledgment() async throws {
        let transport = TaskProtocolFixture(turns: [.complete("First"), .foreignThenComplete("Own answer")])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        _ = await collect(try await backend.start(id: id, request: request()))
        let events = await collect(try await backend.continueTask(
            id: id, record: record(id, session: "fixture-session"), request: AgentTaskTurnRequest(prompt: "Mine")))
        #expect(events == [.session("fixture-session"), .running, .completed("Own answer")])
        #expect(!events.contains(.completed("Foreign answer")))
    }

    @Test func observedBusyThreadIsRejectedBeforeAnythingIsSent() async throws {
        let transport = TaskProtocolFixture(threadStatus: "active")
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        await #expect(throws: AgentManagedTaskError.busy) {
            _ = try await backend.continueTask(id: id, record: record(id, session: "fixture-session"),
                                               request: AgentTaskTurnRequest(prompt: "Next"))
        }
        let methods = await transport.methods
        #expect(!methods.contains("thread/resume"))
        #expect(!methods.contains("turn/start"))
        await #expect(throws: AgentManagedTaskError.noActiveTurn) { try await backend.cancel(id: id) }
    }

    @Test func lostAcceptanceIsNeverRetriedOrReportedAsSuccessfulCancellation() async throws {
        let transport = TaskProtocolFixture(turns: [.lostAcceptance])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        let events = await collect(try await backend.start(id: id, request: request()))
        #expect(events.first == .session("fixture-session"))
        #expect(events.count == 2)
        #expect(events.contains { if case .disconnected = $0 { return true }; return false })
        await #expect(throws: AgentManagedTaskError.cancellationUnconfirmed) { try await backend.cancel(id: id) }
        #expect(await transport.methods.filter { $0 == "turn/start" }.count == 1)
    }

    @Test func lostFollowUpAcceptanceIsUncertainAndNotReplayed() async throws {
        let transport = TaskProtocolFixture(turns: [.complete("First"), .lostAcceptance])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        _ = await collect(try await backend.start(id: id, request: request()))
        let events = await collect(try await backend.continueTask(
            id: id, record: record(id, session: "fixture-session"), request: AgentTaskTurnRequest(prompt: "Again")))
        #expect(events.count == 2)
        #expect(events.first == .session("fixture-session"))
        #expect(events.contains { if case .disconnected = $0 { return true }; return false })
        #expect(await transport.methods.filter { $0 == "turn/start" }.count == 2)
    }

    @Test func providerDefaultsOmitOverridesAndOnlyExplicitUnrestrictedBypasses() async throws {
        let transport = TaskProtocolFixture(turns: [.complete("A"), .complete("B")])
        let backend = AgentManagedTaskBackend(connection: transport)
        _ = await collect(try await backend.start(id: UUID(), request: request()))
        _ = await collect(try await backend.start(id: UUID(), request: request(.unrestricted)))
        let threads = await transport.params("thread/start")
        let turns = await transport.params("turn/start")
        #expect(threads[0]["approvalPolicy"] == nil && threads[0]["sandbox"] == nil)
        #expect(turns[0]["approvalPolicy"] == nil && turns[0]["sandboxPolicy"] == nil)
        #expect(threads[1]["approvalPolicy"] == "never" && threads[1]["sandbox"] == "danger-full-access")
        #expect(turns[1]["approvalPolicy"] == "never" && turns[1]["sandboxPolicy"] == ["type": "dangerFullAccess"])
    }

    @Test func earlyEventOverflowEndsUncertainInsteadOfDroppingSilently() async throws {
        let transport = TaskProtocolFixture(turns: [.flood(AgentCodexTaskDriver.earlyEventLimit + 10)])
        let backend = AgentManagedTaskBackend(connection: transport)
        let markerSession = "01a176fc-d044-7e62-92bb-de6c5c50c0d1"
        var activity = await backend.sessionActivityChanges().makeAsyncIterator()
        await backend.observeSession(markerSession)
        _ = await activity.next()
        let execution = Task { await collect(try await backend.start(id: UUID(), request: request())) }
        // This status marker follows the flood on the same stream, so observing
        // it proves the driver consumed every early frame before the ACK.
        #expect(await activity.next() == .init(sessionID: markerSession, phase: .working))
        await transport.releaseFloodAcknowledgement()
        let events = try await execution.value
        #expect(events == [.session("fixture-session"), .running, .disconnected("event_buffer_overflow")])
    }

    @Test func aSlowConsumerGetsAnOverflowErrorNotAStalePhase() async throws {
        let made = AgentTaskEventSink.make()
        var sink = made.1
        for index in 0..<(AgentTaskEventSink.capacity + 20) { sink.yield(.needsInput("attention-\(index)")) }
        var delivered = 0
        do {
            for try await _ in made.0 { delivered += 1 }
            Issue.record("A full buffer must end the stream with an error")
        } catch {
            #expect(error as? AgentManagedTaskError == .eventOverflow)
        }
        #expect(delivered == AgentTaskEventSink.capacity)
    }

    // MARK: Codex interactions

    @Test func numericApprovalStaysPendingUntilOneValidNativeAnswer() async throws {
        let transport = TaskProtocolFixture(turns: [.approval(.number(7))])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        var events = try await backend.start(id: id, request: request()).makeAsyncIterator()
        #expect(try await events.next() == .session("fixture-session"))
        #expect(try await events.next() == .running)
        #expect(try await events.next() == .needsInput("approval_required"))
        let pending = await backend.interactions(id: id)
        #expect(pending.map(\.requestID) == ["7"])
        #expect(pending.first?.kind == .commandApproval)
        #expect(pending.first?.answer == .nativeResponse)
        #expect(await transport.responseIDs.isEmpty)
        await #expect(throws: AgentManagedTaskError.invalidResponse("unknown_decision")) {
            try await backend.respond(id: id, requestID: "7", response: Data(#"{"decision":"approveEverything"}"#.utf8))
        }
        try await backend.respond(id: id, requestID: "7", response: Data(#"{"decision":"accept"}"#.utf8))
        #expect(await transport.responseIDs == [.number(7)])
        #expect(await transport.responseResults == [["decision": "accept"]])
        await #expect(throws: AgentManagedTaskError.staleInteraction) {
            try await backend.respond(id: id, requestID: "7", response: Data(#"{"decision":"decline"}"#.utf8))
        }
        #expect(try await events.next() == .running)
        await transport.finishTurn("fixture-turn-1", status: "completed")
        #expect(try await events.next() == .completed(""))
    }

    @Test func answersFromAnEarlierConnectionAreStale() async throws {
        let transport = TaskProtocolFixture(turns: [.approval(.string("request-1"))])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        var events = try await backend.start(id: id, request: request()).makeAsyncIterator()
        #expect(try await events.next() == .session("fixture-session"))
        #expect(try await events.next() == .running)
        #expect(try await events.next() == .needsInput("approval_required"))
        await transport.loseConnection()
        if case .disconnected? = try await events.next() {} else { Issue.record("Expected uncertainty after the connection was lost") }
        await #expect(throws: AgentManagedTaskError.staleInteraction) {
            try await backend.respond(id: id, requestID: "request-1", response: Data(#"{"decision":"accept"}"#.utf8))
        }
        #expect(await transport.responseIDs.isEmpty)
    }

    // MARK: Codex cancellation

    @Test(.timeLimit(.minutes(1))) func interruptAcknowledgmentIsNotCancellation() async throws {
        let transport = TaskProtocolFixture(turns: [.hold], interruptConfirms: false)
        let backend = AgentManagedTaskBackend(connection: transport, cancelDeadline: .milliseconds(200))
        let id = UUID()
        var events = try await backend.start(id: id, request: request()).makeAsyncIterator()
        #expect(try await events.next() == .session("fixture-session"))
        #expect(try await events.next() == .running)
        await #expect(throws: AgentManagedTaskError.cancellationUnconfirmed) { try await backend.cancel(id: id) }
        #expect(await transport.params("turn/interrupt") == [["threadId": "fixture-session", "turnId": "fixture-turn-1"]])
        await transport.loseConnection()
        var rest: [AgentTaskEvent] = []
        while let event = try await events.next() { rest.append(event) }
        #expect(!rest.contains(.cancelled))
    }

    @Test(.timeLimit(.minutes(1))) func cancellationReturnsOnlyAfterTheProviderReportsInterruption() async throws {
        let transport = TaskProtocolFixture(turns: [.hold])
        let backend = AgentManagedTaskBackend(connection: transport)
        let id = UUID()
        let stream = try await backend.start(id: id, request: request())
        try await backend.cancel(id: id)
        #expect(await collect(stream) == [.session("fixture-session"), .running, .cancelled])
    }

    // MARK: Claude Code

    private func claudeRequest(_ permission: AgentTaskRequest.PermissionMode = .providerDefault) -> AgentTaskRequest {
        AgentTaskRequest(provider: .claude, prompt: "Review the diff", workspaceID: UUID(),
                         workingDirectory: URL(fileURLWithPath: "/tmp"), presentation: .background,
                         permissionMode: permission)
    }

    private func claudeBackend(confirmsInterrupt: Bool = true, idleLimit: Int = 1)
        -> (AgentManagedTaskBackend, AsyncStream<MadeClaudeDriver>.Iterator) {
        let (made, sink) = AsyncStream.makeStream(of: MadeClaudeDriver.self)
        let backend = AgentManagedTaskBackend(connection: TaskProtocolFixture(), claudeFactory: { configuration in
            let fixture = ManagedClaudeFixture(confirmsInterrupt: confirmsInterrupt)
            sink.yield(MadeClaudeDriver(fixture: fixture, configuration: configuration))
            return fixture
        }, cancelDeadline: .milliseconds(200), idleClaudeLimit: idleLimit)
        return (backend, made.makeAsyncIterator())
    }

    @Test(.timeLimit(.minutes(1))) func claudeApprovalStaysPendingAndIsAnsweredOnlyByTheUser() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        let id = UUID()
        var events = try await backend.start(id: id, request: claudeRequest()).makeAsyncIterator()
        let made = try #require(await drivers.next())
        #expect(made.configuration.managedConversation)
        let arguments = ClaudeCodeBrain.arguments(made.configuration, session: .new("planned"), systemPrompt: "")
        #expect(!arguments.contains("bypassPermissions"))
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("--model"))
        let driver = made.fixture
        await driver.waitForRuns(1)
        #expect(await driver.promptIDs == [id])
        await driver.send(.session("claude-session"))
        await driver.send(.approvalRequested(id: "permission-1", prompt: "Run `make`?", options: ClaudeCodeBrain.managedApprovalOptions))
        #expect(try await events.next() == .session("claude-session"))
        #expect(try await events.next() == .running)
        #expect(try await events.next() == .needsInput("approval_required"))
        let pending = await backend.interactions(id: id)
        #expect(pending.map(\.requestID) == ["permission-1"])
        #expect(pending.first?.answer == .allowOrDeny)
        #expect(await driver.answers.isEmpty)
        await #expect(throws: AgentManagedTaskError.invalidResponse("behavior_must_be_allow_or_deny")) {
            try await backend.respond(id: id, requestID: "permission-1", response: Data(#"{"behavior":"always"}"#.utf8))
        }
        try await backend.respond(id: id, requestID: "permission-1", response: Data(#"{"behavior":"allow"}"#.utf8))
        #expect(await driver.answers == ["permission-1:true"])
        await #expect(throws: AgentManagedTaskError.staleInteraction) {
            try await backend.respond(id: id, requestID: "permission-1", response: Data(#"{"behavior":"deny"}"#.utf8))
        }
        #expect(try await events.next() == .running)
        await driver.send(.approvalRequested(id: "question-1", prompt: "Allow Ask?", options: ClaudeCodeBrain.managedDeclineOnlyOptions))
        #expect(try await events.next() == .needsInput("question_answer_unsupported"))
        await #expect(throws: AgentManagedTaskError.invalidResponse("behavior_must_be_allow_or_deny")) {
            try await backend.respond(id: id, requestID: "question-1", response: Data(#"{"behavior":"allow"}"#.utf8))
        }
        try await backend.respond(id: id, requestID: "question-1", response: Data(#"{"behavior":"deny"}"#.utf8))
        #expect(try await events.next() == .running)
        await driver.send(.textDelta("Done"))
        await driver.send(.finished)
        #expect(try await events.next() == .completed("Done"))
    }

    @Test(.timeLimit(.minutes(1))) func onlyAnExplicitUnrestrictedClaudeTaskBypassesPermissions() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        _ = try await backend.start(id: UUID(), request: claudeRequest(.unrestricted))
        let made = try #require(await drivers.next())
        let arguments = ClaudeCodeBrain.arguments(made.configuration, session: .new("planned"), systemPrompt: "")
        #expect(arguments.contains("bypassPermissions"))
        #expect(made.configuration.managedConversation)
    }

    @Test(.timeLimit(.minutes(1))) func claudeFollowUpReusesTheLiveSessionWithItsOperationIdentity() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        let id = UUID()
        let first = try await backend.start(id: id, request: claudeRequest())
        let driver = try #require(await drivers.next()).fixture
        await driver.waitForRuns(1)
        await driver.send(.session("claude-session"))
        await driver.send(.textDelta("One"))
        await driver.send(.finished)
        #expect(await collect(first) == [.session("claude-session"), .running, .completed("One")])
        let operation = UUID()
        let second = try await backend.continueTask(id: id, record: record(id, provider: .claude, session: "claude-session"),
                                                    request: AgentTaskTurnRequest(operationID: operation, prompt: "Two?"))
        await driver.waitForRuns(2)
        #expect(await driver.prompts == ["Review the diff", "Two?"])
        #expect(await driver.resumeSessions == [nil, "claude-session"])
        #expect(await driver.promptIDs == [id, operation])
        await driver.send(.session("claude-session"))
        await driver.send(.textDelta("Two"))
        await driver.send(.finished)
        #expect(await collect(second) == [.session("claude-session"), .running, .completed("Two")])
    }

    @Test(.timeLimit(.minutes(1))) func coldClaudeFollowUpResumesExactlyAndRejectsAReplacementSession() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        let id = UUID()
        let operation = UUID()
        let stream = try await backend.continueTask(id: id, record: record(id, provider: .claude, session: "claude-session"),
                                                    request: AgentTaskTurnRequest(operationID: operation, prompt: "Next"))
        let made = try #require(await drivers.next())
        #expect(made.configuration.managedConversation)
        #expect(!ClaudeCodeBrain.arguments(made.configuration, session: .resume("claude-session"), systemPrompt: "")
            .contains("bypassPermissions"))
        await made.fixture.waitForRuns(1)
        #expect(await made.fixture.resumeSessions == ["claude-session"])
        #expect(await made.fixture.promptIDs == [operation])
        await made.fixture.send(.session("replacement-session"))
        #expect(await collect(stream) == [.disconnected("claude_session_changed")])
        #expect(await made.fixture.shutdowns == 0)
    }

    @Test(.timeLimit(.minutes(1))) func uncertainClaudeWorkIsQuarantinedNotKilledReusedOrEvicted() async throws {
        let (backend, factory) = claudeBackend(idleLimit: 1)
        var drivers = factory
        let uncertainID = UUID()
        let unknown = try await backend.start(id: uncertainID, request: claudeRequest())
        let quarantined = try #require(await drivers.next()).fixture
        await quarantined.waitForRuns(1)
        await quarantined.send(.session("uncertain-session"))
        await quarantined.end(throwing: ClaudeManagedTurnError.unconfirmed("lost completion channel"))
        #expect(await collect(unknown) == [.session("uncertain-session"), .running, .disconnected("lost completion channel")])
        #expect(await quarantined.shutdowns == 0)
        #expect(await backend.hasActiveTurn(id: uncertainID))
        await #expect(throws: AgentManagedTaskError.cancellationUnconfirmed) { try await backend.park(id: uncertainID) }
        // Known-idle eviction must not mistake the uncertain retained process for idle.
        let firstID = UUID(), secondID = UUID()
        let first = try await backend.start(id: firstID, request: claudeRequest())
        let firstDriver = try #require(await drivers.next()).fixture
        await firstDriver.waitForRuns(1); await firstDriver.send(.session("known-first")); await firstDriver.send(.finished)
        _ = await collect(first)
        let second = try await backend.start(id: secondID, request: claudeRequest())
        let secondDriver = try #require(await drivers.next()).fixture
        await secondDriver.waitForRuns(1); await secondDriver.send(.session("known-second")); await secondDriver.send(.finished)
        _ = await collect(second)
        await firstDriver.waitForShutdown()
        #expect(await firstDriver.shutdowns == 1)
        #expect(await secondDriver.shutdowns == 0)
        #expect(await quarantined.shutdowns == 0)
        #expect(await quarantined.prompts == ["Review the diff"])
        await #expect(throws: AgentManagedTaskError.cancellationUnconfirmed) {
            try await backend.continueTask(id: uncertainID, record: record(uncertainID, provider: .claude, session: "uncertain-session"),
                                           request: AgentTaskTurnRequest(prompt: "Do not replay"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func claudeCancellationNeedsTheNativeInterruptedOutcome() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        let id = UUID()
        let stream = try await backend.start(id: id, request: claudeRequest())
        let driver = try #require(await drivers.next()).fixture
        await driver.waitForRuns(1)
        await driver.send(.session("claude-session"))
        try await backend.cancel(id: id)
        #expect(await driver.interrupts == 1)
        #expect(await collect(stream) == [.session("claude-session"), .running, .cancelled])
    }

    @Test(.timeLimit(.minutes(1))) func claudeInterruptWithoutAnOutcomeIsUnconfirmed() async throws {
        let (backend, factory) = claudeBackend(confirmsInterrupt: false)
        var drivers = factory
        let id = UUID()
        let stream = try await backend.start(id: id, request: claudeRequest())
        let driver = try #require(await drivers.next()).fixture
        await driver.waitForRuns(1)
        await driver.send(.session("claude-session"))
        await #expect(throws: AgentManagedTaskError.cancellationUnconfirmed) { try await backend.cancel(id: id) }
        // Claude Code's later report is the outcome; it is never assumed.
        await driver.end(throwing: ClaudeManagedTurnError.interrupted)
        #expect(await collect(stream) == [.session("claude-session"), .running, .cancelled])
    }

    @Test(.timeLimit(.minutes(1))) func parkReleasesOnlyAnIdleClaudeProcess() async throws {
        let (backend, factory) = claudeBackend()
        var drivers = factory
        let id = UUID()
        let stream = try await backend.start(id: id, request: claudeRequest())
        let driver = try #require(await drivers.next()).fixture
        await driver.waitForRuns(1)
        await #expect(throws: AgentManagedTaskError.busy) { try await backend.park(id: id) }
        #expect(await backend.hasActiveTurn(id: id))
        await driver.send(.session("claude-session"))
        await driver.send(.finished)
        _ = await collect(stream)
        #expect(await backend.hasActiveTurn(id: id) == false)
        try await backend.park(id: id)
        #expect(await driver.shutdowns == 1)
        _ = try await backend.continueTask(id: id, record: record(id, provider: .claude, session: "claude-session"),
                                           request: AgentTaskTurnRequest(prompt: "After handoff"))
        let resumed = try #require(await drivers.next()).fixture
        await resumed.waitForRuns(1)
        #expect(await resumed.resumeSessions == ["claude-session"])
    }

    @Test func openCodeTerminalPresentationIsRejectedNotFaked() async throws {
        let backend = AgentManagedTaskBackend(connection: TaskProtocolFixture())
        var input = request()
        input.provider = .opencode
        input.presentation = .terminal
        await #expect(throws: AgentManagedTaskError.unsupported("opencode_terminal_presentation")) {
            _ = try await backend.start(id: UUID(), request: input)
        }
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

/// A fixture driver and the configuration the backend built for it.
private struct MadeClaudeDriver: Sendable {
    let fixture: ManagedClaudeFixture
    let configuration: ClaudeCodeBrain.Configuration
}

/// A managed Claude brain whose events the test supplies.
private actor ManagedClaudeFixture: AgentClaudeDriver {
    private let confirmsInterrupt: Bool
    private var continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation?
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var prompts: [String] = []
    private(set) var resumeSessions: [String?] = []
    private(set) var promptIDs: [UUID?] = []
    private(set) var answers: [String] = []
    private(set) var interrupts = 0
    private(set) var shutdowns = 0
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    func waitForShutdown() async {
        if shutdowns > 0 { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    init(confirmsInterrupt: Bool) { self.confirmsInterrupt = confirmsInterrupt }

    nonisolated func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        Task { await self.accept(request, continuation: continuation) }
        return stream
    }

    private func accept(_ request: ChiefTurnRequest, continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation) {
        prompts.append(request.userText)
        resumeSessions.append(request.resumeSession)
        promptIDs.append(request.promptID)
        self.continuation = continuation
        for waiter in runWaiters { waiter.resume() }
        runWaiters.removeAll()
    }

    func waitForRuns(_ count: Int) async {
        while prompts.count < count { await withCheckedContinuation { runWaiters.append($0) } }
    }

    func send(_ event: ChiefTurnEvent) { continuation?.yield(event) }

    func end(throwing error: (any Error)? = nil) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
    }

    func answerPermission(_ id: String, allow: Bool, conversation: ConversationID) throws {
        guard continuation != nil else { throw ClaudeManagedTurnError.staleRequest }
        answers.append("\(id):\(allow)")
    }

    func interrupt(conversation: ConversationID) {
        interrupts += 1
        if confirmsInterrupt { end(throwing: ClaudeManagedTurnError.interrupted) }
    }

    func shutdown() {
        shutdowns += 1
        for waiter in shutdownWaiters { waiter.resume() }; shutdownWaiters.removeAll()
        end()
    }
}

/// The shared daemon's app-server protocol, with turn-scoped notifications as Codex sends them.
private actor TaskProtocolFixture: AgentCodexTransport {
    enum Turn: Sendable {
        /// Starts, answers and completes before acknowledging `turn/start`.
        case complete(String)
        /// Another client's turn runs and completes first, then this one.
        case foreignThenComplete(String)
        /// The acceptance response is lost.
        case lostAcceptance
        /// Starts and asks for command approval with this request ID.
        case approval(ChiefJSON)
        /// Starts and keeps running.
        case hold
        /// Sends this many deltas before acknowledging, then completes.
        case flood(Int)
    }

    nonisolated let messages: AsyncThrowingStream<ChiefJSON, any Error>
    private let sink: AsyncThrowingStream<ChiefJSON, any Error>.Continuation
    private let holdRead: Bool
    private let threadStatus: String
    private let interruptConfirms: Bool
    private var plan: [Turn]
    private var connectFailures: Int
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRead: CheckedContinuation<ChiefJSON, any Error>?
    private var floodAcknowledgement: CheckedContinuation<Void, Never>?
    func releaseFloodAcknowledgement() { floodAcknowledgement?.resume(); floodAcknowledgement = nil }
    private var turnCount = 0
    private var connected = false
    private var calls: [(method: String, params: ChiefJSON)] = []
    private(set) var connectCount = 0
    private(set) var responseIDs: [ChiefJSON] = []
    private(set) var responseResults: [ChiefJSON] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(turns: [Turn] = [.complete("Confirmed result")], threadStatus: String = "idle", interruptConfirms: Bool = true,
         holdRead: Bool = false, connectFailures: Int = 0) {
        let pair = AsyncThrowingStream.makeStream(of: ChiefJSON.self)
        messages = pair.stream; sink = pair.continuation
        plan = turns
        self.threadStatus = threadStatus
        self.interruptConfirms = interruptConfirms
        self.holdRead = holdRead; self.connectFailures = connectFailures
    }

    var methods: [String] { calls.map { $0.method } }
    func params(_ method: String) -> [ChiefJSON] { calls.filter { $0.method == method }.map(\.params) }

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
    func respond(id: ChiefJSON, result: ChiefJSON) {
        responseIDs.append(id)
        responseResults.append(result)
        for waiter in responseWaiters { waiter.resume() }; responseWaiters.removeAll()
    }
    func waitForResponses(_ count: Int) async {
        while responseResults.count < count { await withCheckedContinuation { responseWaiters.append($0) } }
    }
    func coordinatorTool(arguments: ChiefJSON = ["action": "inbox"]) {
        emit("item/tool/call", ["threadId": "fixture-session", "turnId": "fixture-turn-1",
            "namespace": "cmux_tasks", "tool": "task", "callId": "tool-call-1", "arguments": arguments], id: 42)
    }
    func status(session: String, type: String, flags: [String] = []) {
        emit("thread/status/changed", ["threadId": .string(session),
                                       "status": .object(["type": .string(type), "activeFlags": .array(flags.map(ChiefJSON.string))])])
    }
    func loseConnection() { sink.finish(throwing: URLError(.networkConnectionLost)) }

    func finishTurn(_ turn: String, status: String, session: String = "fixture-session") {
        emit("turn/completed", ["threadId": .string(session), "turn": .object(["id": .string(turn), "status": .string(status)])])
    }

    private func emit(_ method: String, _ params: [String: ChiefJSON], id: ChiefJSON? = nil) {
        var message: [String: ChiefJSON] = ["method": .string(method), "params": .object(params)]
        if let id { message["id"] = id }
        sink.yield(.object(message))
    }

    private func started(_ session: String, _ turn: String) {
        emit("turn/started", ["threadId": .string(session), "turn": .object(["id": .string(turn), "status": "inProgress"])])
    }

    private func answer(_ session: String, _ turn: String, _ text: String) {
        emit("item/completed", ["threadId": .string(session), "turnId": .string(turn), "item": .object([
            "type": "agentMessage", "phase": "final_answer", "text": .string(text)])])
    }

    func request(_ method: String, _ params: ChiefJSON) async throws -> ChiefJSON {
        calls.append((method, params))
        let session = params["threadId"]?.string ?? "fixture-session"
        switch method {
        case "config/read":
            return ["config": ["shell_environment_policy": ["exclude": ["PRIVATE_EXISTING"]]]]
        case "thread/read":
            if holdRead {
                return try await withCheckedThrowingContinuation { pendingRead = $0
                    for waiter in readWaiters { waiter.resume() }; readWaiters.removeAll()
                }
            }
            return .object(["thread": .object(["id": .string(session), "status": .object(["type": .string(threadStatus)])])])
        case "thread/start":
            return .object(["thread": .object(["id": "fixture-session"])])
        case "thread/resume":
            return .object(["thread": .object(["id": .string(session), "status": .object(["type": "idle"])])])
        case "turn/start":
            turnCount += 1
            let turn = "fixture-turn-\(turnCount)"
            let next = plan.isEmpty ? Turn.complete("Confirmed result") : plan.removeFirst()
            switch next {
            case .lostAcceptance:
                throw URLError(.networkConnectionLost)
            case .complete(let text):
                started(session, turn); answer(session, turn, text); finishTurn(turn, status: "completed", session: session)
            case .foreignThenComplete(let text):
                started(session, "phone-turn"); answer(session, "phone-turn", "Foreign answer")
                finishTurn("phone-turn", status: "completed", session: session)
                started(session, turn); answer(session, turn, text); finishTurn(turn, status: "completed", session: session)
            case .approval(let requestID):
                started(session, turn)
                emit("item/commandExecution/requestApproval", [
                    "threadId": .string(session), "turnId": .string(turn), "itemId": "item-1",
                    "command": "rm -rf build", "reason": "Clean the build directory"], id: requestID)
            case .hold:
                started(session, turn)
            case .flood(let count):
                started(session, turn)
                for _ in 0..<count {
                    emit("item/agentMessage/delta", ["threadId": .string(session), "turnId": .string(turn), "delta": "x"])
                }
                await withCheckedContinuation { continuation in
                    floodAcknowledgement = continuation
                    status(session: "01a176fc-d044-7e62-92bb-de6c5c50c0d1", type: "active")
                }
                answer(session, turn, "Flooded"); finishTurn(turn, status: "completed", session: session)
            }
            return .object(["turn": .object(["id": .string(turn), "status": "inProgress"])])
        case "turn/interrupt":
            if interruptConfirms, let turn = params["turnId"]?.string { finishTurn(turn, status: "interrupted", session: session) }
            return .object([:])
        default:
            return .object([:])
        }
    }
}
