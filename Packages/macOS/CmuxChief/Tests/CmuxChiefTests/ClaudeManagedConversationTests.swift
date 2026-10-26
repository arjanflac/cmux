@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Strict managed Claude Code conversations against a stream-json fixture process.
@Suite(.timeLimit(.minutes(1))) struct ClaudeManagedConversationTests {
    private let conversation = ConversationID("managed-task")

    /// Acknowledges `initialize` after checking that no prompt arrived first,
    /// echoes the prompt, logs every later control line, and reports an
    /// interruption when asked to interrupt.
    private static let cooperative = #"""
    IFS= read -r init
    rid=$(printf '%s' "$init" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    ack() { printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$rid"; }
    if IFS= read -r -t 1 prompt; then echo "EARLY" >> "$FIXTURE_LOG"; ack; else ack; IFS= read -r prompt; fi
    uuid=$(printf '%s' "$prompt" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
    echo "prompt $uuid" >> "$FIXTURE_LOG"
    printf '{"type":"user","uuid":"%s","isReplay":true,"message":{"role":"user","content":[]}}\n' "$uuid"
    while IFS= read -r line; do
      echo "control $line" >> "$FIXTURE_LOG"
      case "$line" in
        *'"interrupt"'*) printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"num_turns":1,"duration_api_ms":5}\n' ;;
      esac
    done
    """#

    private func fixture(_ body: String) throws -> (executable: URL, log: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-managed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("claude")
        let script = "#!/bin/bash\nprintf 'launch %s\\n' \"$*\" >> \"$FIXTURE_LOG\"\n" + body + "\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, directory.appendingPathComponent("log"))
    }

    private func brain(_ executable: URL) -> ClaudeCodeBrain {
        ClaudeCodeBrain(configuration: .init(model: "", executableOverride: executable, extraArguments: [],
                                             managedConversation: true))
    }

    private func request(log: URL, resume: String? = nil, promptID: UUID? = nil) -> ChiefTurnRequest {
        ChiefTurnRequest(conversation: conversation, resumeSession: resume, userText: "Do the task", attachmentPaths: [],
                         replyContext: nil, systemPrompt: "", workingDirectory: FileManager.default.temporaryDirectory,
                         environment: ["FIXTURE_LOG": log.path], promptID: promptID)
    }

    private func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func drain(_ stream: AsyncThrowingStream<ChiefTurnEvent, any Error>) async -> ([ChiefTurnEvent], ClaudeManagedTurnError?) {
        var events: [ChiefTurnEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error as? ClaudeManagedTurnError)
        }
    }

    @Test func promptWaitsForInitializeAndInterruptionIsNeverAFinish() async throws {
        let (executable, log) = try fixture(Self.cooperative)
        let brain = brain(executable)
        let operation = UUID()
        var turn = brain.run(request(log: log, promptID: operation)).makeAsyncIterator()
        guard case .session(let session)? = try await turn.next() else {
            Issue.record("The echoed prompt must confirm the session")
            return
        }
        await brain.interrupt(conversation: conversation)
        do {
            while let event = try await turn.next() { #expect(event != .finished) }
            Issue.record("An interrupted turn must not end normally")
        } catch {
            #expect(error as? ClaudeManagedTurnError == .interrupted)
        }
        await brain.shutdown()
        let logged = lines(log)
        #expect(!logged.contains("EARLY"))
        #expect(logged.contains("prompt " + operation.uuidString.lowercased()))
        let launches = logged.filter { $0.hasPrefix("launch ") }
        #expect(launches.count == 1)
        #expect(launches.first?.contains("--session-id " + session) == true)
        #expect(launches.first?.contains("--model") == false)
        #expect(logged.filter { $0.hasPrefix("control ") && $0.contains(#""interrupt""#) }.count == 1)
    }

    @Test func overlappingTurnIsRejectedWithoutInterruptingTheRunningOne() async throws {
        let (executable, log) = try fixture(Self.cooperative)
        let brain = brain(executable)
        var first = brain.run(request(log: log)).makeAsyncIterator()
        guard case .session? = try await first.next() else {
            Issue.record("The first turn must be accepted")
            return
        }
        let (events, error) = await drain(brain.run(request(log: log)))
        #expect(events.isEmpty)
        #expect(error == .busy)
        #expect(await brain.hasActiveTurn(conversation: conversation))
        await brain.interrupt(conversation: conversation)
        do { while try await first.next() != nil {} } catch { #expect(error as? ClaudeManagedTurnError == .interrupted) }
        await brain.shutdown()
        // Only the explicit Stop interrupted; the rejected turn sent nothing.
        #expect(lines(log).filter { $0.hasPrefix("control ") }.count == 1)
        #expect(lines(log).filter { $0.hasPrefix("prompt ") }.count == 1)
    }

    @Test func missingResumedSessionFailsWithoutAFreshSessionOrResend() async throws {
        let (executable, log) = try fixture(#"""
        echo "No conversation found with session ID: missing-session" >&2
        exit 1
        """#)
        let brain = brain(executable)
        let (events, error) = await drain(brain.run(request(log: log, resume: "missing-session")))
        await brain.shutdown()
        #expect(events.isEmpty)
        guard case .notSent? = error else {
            Issue.record("Expected a not-sent failure, got \(String(describing: error))")
            return
        }
        let launches = lines(log).filter { $0.hasPrefix("launch ") }
        #expect(launches.count == 1)
        #expect(launches.first?.contains("--resume missing-session") == true)
        #expect(launches.first?.contains("--session-id") == false)
    }

    @Test func rejectedInitializeNeverReceivesThePrompt() async throws {
        let (executable, log) = try fixture(#"""
        IFS= read -r init
        rid=$(printf '%s' "$init" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
        printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"unsupported version"}}\n' "$rid"
        while IFS= read -r line; do echo "line $line" >> "$FIXTURE_LOG"; done
        """#)
        let brain = brain(executable)
        let (events, error) = await drain(brain.run(request(log: log)))
        await brain.shutdown()
        #expect(events.isEmpty)
        #expect(error == .notSent("claude_initialize_failed: unsupported version"))
        #expect(!lines(log).contains { $0.hasPrefix("line ") })
    }

    @Test func exitAfterAcceptanceIsUncertainAndNotRetried() async throws {
        let (executable, log) = try fixture(#"""
        IFS= read -r init
        rid=$(printf '%s' "$init" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$rid"
        IFS= read -r prompt
        uuid=$(printf '%s' "$prompt" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
        printf '{"type":"user","uuid":"%s","isReplay":true,"message":{"role":"user","content":[]}}\n' "$uuid"
        exit 0
        """#)
        let brain = brain(executable)
        let (events, error) = await drain(brain.run(request(log: log)))
        await brain.shutdown()
        #expect(events.count == 1)
        guard case .unconfirmed? = error else {
            Issue.record("Expected uncertainty, got \(String(describing: error))")
            return
        }
        #expect(lines(log).filter { $0.hasPrefix("launch ") }.count == 1)
    }

    // MARK: Pure seams

    @Test func managedEnvironmentDropsInheritedCmuxAuthorityAndInterruptedTurnResume() {
        let inherited = ["PATH": "/usr/bin", "CMUX_SOCKET_PATH": "/tmp/other.sock", "CMUX_SURFACE_ID": "surface",
                         "CMUX_SOCKET_PASSWORD": "secret", "IN_CMUX": "1", "CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1",
                         "HOME": "/Users/test"]
        let explicit = ["CMUX_TASK_ID": "task", "CLAUDE_CODE_RESUME_INTERRUPTED_TURN": "1", "FIXTURE": "yes"]
        #expect(ClaudeCodeBrain.managedEnvironment(inherited: inherited, request: explicit) == [
            "PATH": "/usr/bin", "HOME": "/Users/test", "CMUX_TASK_ID": "task", "FIXTURE": "yes",
            "CMUX_CLAUDE_HOOKS_DISABLED": "1",
        ])
    }

    @Test func managedArgumentsOmitAnUnsetModelAndChiefArgumentsAreUnchanged() {
        let managed = ClaudeCodeBrain.arguments(.init(model: "", extraArguments: [], managedConversation: true),
                                                session: .resume("s"), systemPrompt: "")
        #expect(!managed.contains("--model"))
        let chief = ClaudeCodeBrain.arguments(.init(model: "", extraArguments: []), session: .resume("s"), systemPrompt: "")
        #expect(chief.contains("--model"))
    }

    @Test func strictParserReportsInterruptionEchoControlAndSessionChanges() {
        let interrupted = #"{"type":"result","subtype":"error_during_execution","is_error":false,"result":null,"num_turns":1,"duration_api_ms":10}"#
        var legacy = ClaudeStreamParser(sessionID: "s")
        legacy.beginTurn(echo: "a")
        #expect(legacy.consume(Data(interrupted.utf8)) == [.event(.finished)])
        var strict = ClaudeStreamParser(sessionID: "s", strict: true)
        strict.beginTurn(echo: "a")
        #expect(strict.consume(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{}}}"#.utf8))
            == [.controlResponse(requestID: "init-1", error: nil)])
        #expect(strict.consume(Data(#"{"type":"user","uuid":"a","isReplay":true,"message":{"content":[]}}"#.utf8)) == [.accepted])
        #expect(strict.consume(Data(#"{"type":"system","subtype":"init","session_id":"other"}"#.utf8)) == [.sessionChanged("other")])
        #expect(strict.consume(Data(interrupted.utf8)) == [.interrupted])
        strict.beginTurn(echo: "b")
        strict.noteInterruptRequested()
        let erroredAfterInterrupt = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"aborted","num_turns":1,"duration_api_ms":10}"#
        #expect(strict.consume(Data(erroredAfterInterrupt.utf8)) == [.interrupted])
    }
}
