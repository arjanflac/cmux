@testable import CmuxChief
import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct AgentOpenCodeSessionTests {
    private let session = "ses_0123456789abcdefghABCDEFGH"

    private func part(_ type: String, id: String = "prt_1", message: String = "msg_1",
                      fields: [String: ChiefJSON] = [:], sessionID: String? = nil) -> ChiefJSON {
        var values: [String: ChiefJSON] = [
            "id": .string(id), "sessionID": .string(sessionID ?? session),
            "messageID": .string(message), "type": .string(type),
        ]
        values.merge(fields) { _, new in new }
        return .object(values)
    }

    private func event(_ type: String, part: ChiefJSON? = nil, sessionID: String? = nil,
                       error: ChiefJSON? = nil) -> Data {
        var values: [String: ChiefJSON] = [
            "type": .string(type), "timestamp": 123,
            "sessionID": .string(sessionID ?? session),
        ]
        if let part { values["part"] = part }
        if let error { values["error"] = error }
        return ChiefJSON.object(values).line
    }

    private func text(_ value: String, id: String = "prt_text", message: String = "msg_1") -> Data {
        event("text", part: part("text", id: id, message: message,
                                 fields: ["text": .string(value), "time": ["start": 1, "end": 2]]))
    }

    private func finish(_ reason: String = "stop", message: String = "msg_1") -> Data {
        event("step_finish", part: part("step-finish", id: "prt_finish", message: message, fields: [
            "reason": .string(reason), "cost": 0,
            "tokens": ["input": 1, "output": 2, "reasoning": 0, "cache": ["read": 0, "write": 0]],
        ]))
    }

    private func fixture(_ body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("opencode-stub")
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func output(_ lines: [Data]) -> String {
        "cat <<'CMUX_OPENCODE_FIXTURE'\n" + lines.map { String(decoding: $0, as: UTF8.self) }.joined() +
            "CMUX_OPENCODE_FIXTURE\n"
    }

    private func collect(_ stream: AsyncThrowingStream<AgentTaskEvent, any Error>) async throws -> [AgentTaskEvent] {
        var result: [AgentTaskEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }

    @Test func nativeStopAndMatchingSessionCompleteWithTextSnapshots() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: session)
        #expect(parser.consume(event("step_start", part: part("step-start"))) == [.session(session), .running])
        #expect(parser.consume(text("partial")) == [.running])
        #expect(parser.consume(text("final")) == [.running])
        #expect(parser.consume(text("second", id: "prt_second")) == [.running])
        #expect(parser.consume(finish()) == [.running])
        #expect(parser.finish() == .completed("final\nsecond"))
    }

    @Test(arguments: ["tool-calls", "unknown", "", "error"])
    func nonFinalStepNeverCompletes(_ reason: String) {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = parser.consume(text("some output"))
        _ = parser.consume(finish(reason))
        #expect(parser.finish() == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
    }

    @Test func emptyOrTruncatedTransportIsUncertain() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: session)
        #expect(parser.finish() == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
        _ = parser.consume(text("accepted and partially answered"))
        #expect(parser.finish() == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
        _ = parser.consume(Data(#"{"type":"step_finish""#.utf8))
        #expect(parser.finish() == .disconnected("opencode_invalid_json_event"))
    }

    @Test func unexpectedSessionCannotBindOrComplete() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: "ses_expected")
        #expect(parser.consume(text("wrong session")).isEmpty)
        _ = parser.consume(finish())
        #expect(parser.sessionID == nil)
        #expect(parser.finish() == .disconnected("opencode_session_unconfirmed_or_changed"))
    }

    @Test func newSessionCannotChangeMidStream() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = parser.consume(text("first"))
        _ = parser.consume(event("step_finish", part: part("step-finish", fields: ["reason": "stop"],
                                                         sessionID: "ses_other"), sessionID: "ses_other"))
        #expect(parser.sessionID == session)
        #expect(parser.finish() == .disconnected("opencode_session_unconfirmed_or_changed"))
    }

    @Test func nestedSessionAndMissingEnvelopeCannotConfirmCompletion() {
        var nested = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = nested.consume(event("step_finish", part: part("step-finish", fields: ["reason": "stop"], sessionID: "ses_other")))
        #expect(nested.finish() == .disconnected("opencode_part_session_changed"))
        var missing = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = missing.consume(ChiefJSON.object(["type": "step_finish", "part": part("step-finish", fields: ["reason": "stop"])]).line)
        #expect(missing.finish() == .disconnected("opencode_session_unconfirmed_or_changed"))
    }

    @Test func bareStopAndSubsequentActivityCannotClaimSuccess() {
        var malformed = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = malformed.consume(event("step_finish", part: ["reason": "stop"]))
        #expect(malformed.finish() == .disconnected("opencode_invalid_part"))
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = parser.consume(finish())
        _ = parser.consume(event("step_start", part: part("step-start", message: "msg_next")))
        #expect(parser.finish() == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
    }

    @Test func explicitNativeErrorOverridesEarlierStop() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = parser.consume(finish())
        _ = parser.consume(event("error", error: ["name": "APIError", "data": ["message": "provider unavailable"]]))
        #expect(parser.finish() == .failed("provider unavailable"))
    }

    @Test(arguments: ["length", "content-filter"])
    func unsuccessfulFinishIsFailure(_ reason: String) {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: session)
        _ = parser.consume(finish(reason))
        #expect(parser.finish() == .failed("opencode_finish_\(reason)"))
    }

    @Test func ordinaryToolErrorsRemainActivityButNeverFinishTheTurn() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        #expect(parser.consume(event("tool_use", part: part("tool", fields: [
            "tool": "bash", "state": ["status": "error", "error": "command exited with status 1"],
        ]))) == [.session(session), .running])
        #expect(parser.terminal == nil)
        #expect(parser.finish() == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
    }

    @Test(arguments: ["question", "plan_enter", "plan_exit"])
    func unsupportedInteractiveToolsRequireManualAttachment(_ tool: String) {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = parser.consume(event("tool_use", part: part("tool", fields: [
            "tool": .string(tool), "state": ["status": "error", "error": "denied"],
        ])))
        _ = parser.consume(finish())
        #expect(parser.finish() == .needsInput("opencode_attention_requires_manual_attachment"))
    }

    @Test func nativePermissionRejectionRequiresAttentionRatherThanSuccess() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = parser.consume(event("tool_use", part: part("tool", fields: [
            "tool": "bash", "state": ["status": "error", "error": "The user rejected permission to use this specific tool call."],
        ])))
        #expect(parser.finish() == .needsInput("opencode_attention_requires_manual_attachment"))
        var warning = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = warning.consume(finish())
        #expect(warning.finish(stderr: "permission requested: bash (*); auto-rejecting") ==
                .needsInput("opencode_attention_requires_manual_attachment"))
    }

    @Test func snapshotLimitDoesNotSilentlyTruncateACompletedAnswer() {
        var parser = AgentOpenCodeSession.Parser(expectedSessionID: nil)
        _ = parser.consume(text(String(repeating: "x", count: 1_000_001)))
        _ = parser.consume(finish())
        #expect(parser.finish() == .disconnected("opencode_output_limit"))
    }

    @Test func processReceivesLiteralArgumentsScrubbedEnvironmentAndEOF() async throws {
        let probe = try fixture(#"""
        cat > stdin.txt
        printf '%s\n' "$@" > arguments.txt
        /usr/bin/env > environment.txt
        /bin/pwd -P > directory.txt
        """# + "\n" + output([text("answer"), finish()]))
        defer { try? FileManager.default.removeItem(at: probe.directory) }
        let adapter = AgentOpenCodeSession(executableOverride: probe.executable, inheritedEnvironment: [
            "PATH": "/usr/bin:/bin", "CMUX_TASK_ID": "wrong", "CMUX_SOCKET_PATH": "wrong",
            "CMUX_FUTURE_CONTEXT": "wrong", "CMUX_": "wrong", "KEEP_ME": "yes", "PWD": "/",
        ])
        let prompt = "--auto $(touch injected) `echo unsafe`"
        let id = UUID()
        let first = try await adapter.run(taskID: id, sessionID: nil, prompt: prompt, workingDirectory: probe.directory,
                                          model: "provider/model/name", effort: "high")
        #expect(try await collect(first).last == .completed("answer"))
        let args = try String(contentsOf: probe.directory.appendingPathComponent("arguments.txt"), encoding: .utf8)
        #expect(Array(args.components(separatedBy: "\n").dropLast()) == [
            "run", "--format", "json", "--pure", "--model", "provider/model/name", "--variant", "high", "--", prompt,
        ])
        let env = try String(contentsOf: probe.directory.appendingPathComponent("environment.txt"), encoding: .utf8)
        #expect(!env.components(separatedBy: "\n").contains(where: { $0.hasPrefix("CMUX_") }))
        #expect(env.contains("KEEP_ME=yes"))
        #expect(try Data(contentsOf: probe.directory.appendingPathComponent("stdin.txt")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: probe.directory.appendingPathComponent("injected").path))
        let cwd = try String(contentsOf: probe.directory.appendingPathComponent("directory.txt"), encoding: .utf8)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines))
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: probe.directory.path)
        #expect(actualDirectory[.systemNumber] as? NSNumber == expectedDirectory[.systemNumber] as? NSNumber)
        #expect(actualDirectory[.systemFileNumber] as? NSNumber == expectedDirectory[.systemFileNumber] as? NSNumber)
        let next = try await adapter.run(taskID: id, sessionID: session, prompt: "followup", workingDirectory: probe.directory,
                                         model: nil, effort: nil)
        #expect(try await collect(next).first == .session(session))
        let resumed = try String(contentsOf: probe.directory.appendingPathComponent("arguments.txt"), encoding: .utf8)
        #expect(Array(resumed.components(separatedBy: "\n").dropLast()) == [
            "run", "--format", "json", "--pure", "--session", session, "--", "followup",
        ])
    }

    @Test(arguments: ["exit 0", "exit 7", "kill -TERM $$"])
    func processExitWithoutNativeFinishIsUncertainAndNeverReplayed(_ exit: String) async throws {
        let probe = try fixture("printf 'launched\\n' >> launches.txt\n" + output([text("accepted")]) + exit)
        defer { try? FileManager.default.removeItem(at: probe.directory) }
        let adapter = AgentOpenCodeSession(executableOverride: probe.executable)
        let stream = try await adapter.run(taskID: UUID(), sessionID: session, prompt: "hi", workingDirectory: probe.directory,
                                          model: nil, effort: nil)
        #expect(try await collect(stream).last == .disconnected("opencode_ended_without_native_finish_delivery_uncertain"))
        #expect(try String(contentsOf: probe.directory.appendingPathComponent("launches.txt"), encoding: .utf8) == "launched\n")
    }

    @Test func overlapIsRejectedAndCancellationLeavesOtherOwnedGroupRunning() async throws {
        let first = try fixture(output([event("step_start", part: part("step-start"))]) +
                                "if [ -p gate ]; then\nIFS= read -r resume < gate\n" +
                                output([text("other survived"), finish()]) + "else\n/bin/sleep 600 &\nwait\nfi")
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let second = try fixture("")
        defer { try? FileManager.default.removeItem(at: second.directory) }
        let gate = second.directory.appendingPathComponent("gate").path
        try #require(mkfifo(gate, 0o600) == 0)
        let descriptor = open(gate, O_RDWR | O_NONBLOCK)
        try #require(descriptor >= 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        let adapter = AgentOpenCodeSession(executableOverride: first.executable)
        let id = UUID(), otherID = UUID()
        defer {
            Task {
                try? await adapter.cancel(taskID: id)
                try? await adapter.cancel(taskID: otherID)
            }
        }
        let stream = try await adapter.run(taskID: id, sessionID: nil, prompt: "one", workingDirectory: first.directory,
                                          model: nil, effort: nil)
        let other = try await adapter.run(taskID: otherID, sessionID: nil, prompt: "two", workingDirectory: second.directory,
                                          model: nil, effort: nil)
        var mine = stream.makeAsyncIterator(), theirs = other.makeAsyncIterator()
        #expect(try await mine.next() == .session(session))
        #expect(try await mine.next() == .running)
        #expect(try await theirs.next() == .session(session))
        #expect(try await theirs.next() == .running)
        await #expect(throws: AgentOpenCodeSession.Failure.alreadyRunning) {
            _ = try await adapter.run(taskID: id, sessionID: nil, prompt: "duplicate", workingDirectory: first.directory,
                                      model: nil, effort: nil)
        }
        try await adapter.cancel(taskID: UUID()) // Not owned here; must do nothing.
        try await adapter.cancel(taskID: id)
        #expect(try await mine.next() == .cancelled)
        #expect(try await mine.next() == nil)
        let sent = Data("go\n".utf8).withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        #expect(sent == 3)
        var remaining: [AgentTaskEvent] = []
        while let event = try await theirs.next() { remaining.append(event) }
        #expect(remaining.last == .completed("other survived"))
        try await adapter.cancel(taskID: id) // Repeated cancellation is harmless.
    }

    @Test func invalidResumeIDIsRejectedBeforeAnyProcessLaunch() async throws {
        let probe = try fixture("touch launched")
        defer { try? FileManager.default.removeItem(at: probe.directory) }
        let adapter = AgentOpenCodeSession(executableOverride: probe.executable)
        await #expect(throws: AgentOpenCodeSession.Failure.invalidSessionID) {
            _ = try await adapter.run(taskID: UUID(), sessionID: "--continue", prompt: "hi", workingDirectory: probe.directory,
                                      model: nil, effort: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: probe.directory.appendingPathComponent("launched").path))
    }

    @Test func invalidOptionsCannotBecomeCLIFlags() async throws {
        let probe = try fixture("touch launched")
        defer { try? FileManager.default.removeItem(at: probe.directory) }
        let adapter = AgentOpenCodeSession(executableOverride: probe.executable)
        await #expect(throws: AgentOpenCodeSession.Failure.invalidModel) {
            _ = try await adapter.run(taskID: UUID(), sessionID: nil, prompt: "hi", workingDirectory: probe.directory,
                                      model: "--auto/provider", effort: nil)
        }
        await #expect(throws: AgentOpenCodeSession.Failure.invalidEffort) {
            _ = try await adapter.run(taskID: UUID(), sessionID: nil, prompt: "hi", workingDirectory: probe.directory,
                                      model: nil, effort: "--auto")
        }
        await #expect(throws: AgentOpenCodeSession.Failure.invalidPrompt) {
            _ = try await adapter.run(taskID: UUID(), sessionID: nil, prompt: " \n", workingDirectory: probe.directory,
                                      model: nil, effort: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: probe.directory.appendingPathComponent("launched").path))
    }
}
