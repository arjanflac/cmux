import Foundation

/// Runs explicit OpenCode turns without replaying a prompt after uncertain delivery.
///
/// `run --format json` cannot answer approvals or questions. In OpenCode 1.18.25
/// it rejects permissions and disables questions; observed attention signals end
/// the stream with `needsInput` for manual attachment to the reported session.
/// Text and tool activity map to `running` because AgentTaskEvent has no deltas.
///
/// Protocol: https://github.com/anomalyco/opencode/blob/v1.18.25/packages/opencode/src/cli/cmd/run.ts
actor AgentOpenCodeSession {
    enum Failure: Error, Equatable {
        case alreadyRunning
        case executableNotFound
        case invalidSessionID
        case invalidPrompt
        case invalidModel
        case invalidEffort
    }

    private struct Turn {
        let token: UUID
        let process: ChiefLineProcess
        let sink: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation
        var parser: Parser
        var cancellationRequested = false
    }

    private let executableOverride: URL?
    private let inheritedEnvironment: [String: String]
    private var turns: [UUID: Turn] = [:]

    init(executableOverride: URL? = nil) {
        self.executableOverride = executableOverride
        inheritedEnvironment = ProcessInfo.processInfo.environment
    }

    /// Supplies a complete inherited environment for isolated process fixtures.
    init(executableOverride: URL?, inheritedEnvironment: [String: String]) {
        self.executableOverride = executableOverride
        self.inheritedEnvironment = inheritedEnvironment
    }

    func run(taskID: UUID, sessionID: String?, prompt: String, workingDirectory: URL,
             model: String?, effort: String?) async throws -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        try Task.checkCancellation()
        guard turns[taskID] == nil else { throw Failure.alreadyRunning }
        let arguments = try Self.arguments(sessionID: sessionID, prompt: prompt, model: model, effort: effort)
        // No contextual CMUX values are authorized for this adapter. PWD must not
        // override the child's actual cwd (OpenCode consults it before cwd()).
        let environment = inheritedEnvironment.filter { !$0.key.hasPrefix("CMUX_") && $0.key != "PWD" }
        guard let executable = ChiefExecutableResolver.resolve("opencode", override: executableOverride,
                                                                environment: environment) else {
            throw Failure.executableNotFound
        }
        // OpenCode awaits Bun.stdin.text() even with a positional prompt. The
        // existing JSONL transport keeps stdin open; this fixed exec wrapper
        // supplies EOF without interpolating any prompt/path into shell code.
        // exec preserves the owned pid/process group used by cancellation.
        let child = try ChiefLineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec \"$@\" </dev/null", "cmux-opencode", executable.path] + arguments,
            environment: environment, workingDirectory: workingDirectory
        )
        let (stream, sink) = AsyncThrowingStream.makeStream(of: AgentTaskEvent.self, throwing: (any Error).self)
        let token = UUID()
        turns[taskID] = Turn(token: token, process: child, sink: sink, parser: Parser(expectedSessionID: sessionID))
        sink.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { await self?.abandon(taskID: taskID, token: token) }
            }
        }
        // The pump owns the turn until EOF, including during cancellation. A
        // second run cannot replace the process while its group is stopping.
        Task {
            for await line in child.lines { receive(line, taskID: taskID, token: token) }
            ended(taskID: taskID, token: token)
        }
        return stream
    }

    func cancel(taskID: UUID) async throws {
        guard var turn = turns[taskID] else { return }
        turn.cancellationRequested = true
        turns[taskID] = turn
        turn.process.terminate()
    }

    private func abandon(taskID: UUID, token: UUID) {
        guard var turn = turns[taskID], turn.token == token else { return }
        turn.cancellationRequested = true
        turns[taskID] = turn
        turn.process.terminate()
    }

    private func receive(_ line: Data, taskID: UUID, token: UUID) {
        guard var turn = turns[taskID], turn.token == token, !turn.cancellationRequested else { return }
        let events = turn.parser.consume(line)
        turns[taskID] = turn
        for event in events { turn.sink.yield(event) }
        if turn.parser.terminal != nil { turn.process.terminate() }
    }

    private func ended(taskID: UUID, token: UUID) {
        guard let turn = turns[taskID], turn.token == token else { return }
        turns.removeValue(forKey: taskID)
        // EOF is not an exit-status or acceptance acknowledgement. Native stop
        // evidence is the sole success oracle; a signal/exit alone proves none.
        let event = turn.parser.terminal ?? (turn.cancellationRequested ? .cancelled : turn.parser.finish(stderr: turn.process.stderrText))
        turn.sink.yield(event)
        turn.sink.finish()
        // stdout may close while a child/tool still lives. Stop only our group.
        turn.process.terminate()
    }

    nonisolated private static func arguments(sessionID: String?, prompt: String, model: String?, effort: String?) throws -> [String] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !prompt.contains("\0") else {
            throw Failure.invalidPrompt
        }
        var result = ["run", "--format", "json", "--pure"]
        if let sessionID {
            guard Parser.validSessionID(sessionID) else { throw Failure.invalidSessionID }
            result += ["--session", sessionID]
        }
        if let model {
            let components = model.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2, components.allSatisfy({ !$0.isEmpty }), Self.validOption(model) else {
                throw Failure.invalidModel
            }
            result += ["--model", model]
        }
        if let effort {
            guard Self.validOption(effort) else { throw Failure.invalidEffort }
            result += ["--variant", effort]
        }
        // A prompt beginning with a flag is still a positional message.
        return result + ["--", prompt]
    }

    nonisolated private static func validOption(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.contains("\0") &&
            !value.contains(where: { $0.isWhitespace })
    }

    /// Pure fixture seam for the installed CLI's JSON envelope and part shapes.
    struct Parser: Sendable {
        let expectedSessionID: String?
        private(set) var sessionID: String?
        private(set) var terminal: AgentTaskEvent?
        private var finalMessageID: String?
        private var textParts: [String: String] = [:]
        private var textOrder: [String] = []
        private var textSize = 0
        private static let textLimit = 1_000_000

        init(expectedSessionID: String?) { self.expectedSessionID = expectedSessionID }

        mutating func consume(_ line: Data) -> [AgentTaskEvent] {
            guard terminal == nil else { return [] }
            guard let value = try? ChiefJSON(parsing: line), let type = value["type"]?.string else {
                terminal = .disconnected("opencode_invalid_json_event")
                return []
            }
            guard let incoming = value["sessionID"]?.string, Self.validSessionID(incoming),
                  expectedSessionID == nil || incoming == expectedSessionID,
                  sessionID == nil || incoming == sessionID else {
                terminal = .disconnected("opencode_session_unconfirmed_or_changed")
                return []
            }
            let part = value["part"]
            if let nested = part?["sessionID"]?.string, nested != incoming {
                terminal = .disconnected("opencode_part_session_changed")
                return []
            }
            var events: [AgentTaskEvent] = []
            if sessionID == nil {
                sessionID = incoming
                events.append(.session(incoming))
            }
            switch type {
            case "step_start", "text", "tool_use", "step_finish", "reasoning":
                guard let part, part["sessionID"]?.string == incoming,
                      let messageID = part["messageID"]?.string, !messageID.isEmpty,
                      let partID = part["id"]?.string, !partID.isEmpty else {
                    terminal = .disconnected("opencode_invalid_part")
                    return events
                }
                events.append(.running)
                if let finalMessageID, finalMessageID != messageID { self.finalMessageID = nil }
                switch type {
                case "step_start":
                    guard part["type"]?.string == "step-start" else { return invalidPart(events) }
                    finalMessageID = nil
                case "text":
                    guard part["type"]?.string == "text", let text = part["text"]?.string,
                          part["time"]?["end"]?.number != nil else { return invalidPart(events) }
                    // Parts are snapshots, not deltas; a repeated update replaces.
                    let previous = textParts[partID]?.count ?? 0
                    guard textSize - previous + text.count <= Self.textLimit else {
                        terminal = .disconnected("opencode_output_limit")
                        return events
                    }
                    if textParts[partID] == nil { textOrder.append(partID) }
                    textParts[partID] = text
                    textSize += text.count - previous
                case "tool_use":
                    guard part["type"]?.string == "tool", let tool = part["tool"]?.string,
                          let status = part["state"]?["status"]?.string,
                          ["completed", "error"].contains(status),
                          status != "error" || part["state"]?["error"]?.string != nil else { return invalidPart(events) }
                    finalMessageID = nil
                    let error = part["state"]?["error"]?.string ?? ""
                    if ["question", "plan_enter", "plan_exit"].contains(tool) || Self.requiresAttention(error) {
                        terminal = .needsInput("opencode_attention_requires_manual_attachment")
                    }
                case "step_finish":
                    guard part["type"]?.string == "step-finish", let reason = part["reason"]?.string else {
                        return invalidPart(events)
                    }
                    // A tool-calls finish ends a step, never the turn.
                    finalMessageID = reason == "stop" ? messageID : nil
                    if ["length", "content-filter"].contains(reason) { terminal = .failed("opencode_finish_\(reason)") }
                default:
                    guard part["type"]?.string == "reasoning" else { return invalidPart(events) }
                }
            case "error":
                guard let error = value["error"], error.object != nil else { return invalidPart(events) }
                let name = error["name"]?.string ?? "opencode_error"
                let message = error["data"]?["message"]?.string ?? name
                terminal = Self.requiresAttention(name + " " + message)
                    ? .needsInput("opencode_attention_requires_manual_attachment")
                    : .failed(String(message.prefix(4096)))
            default:
                // The run CLI does not currently emit permission/question events.
                // Unknown schemas cannot establish successful completion.
                terminal = .disconnected("opencode_unsupported_event")
            }
            return events
        }

        func finish(stderr: String = "") -> AgentTaskEvent {
            if let terminal { return terminal }
            if Self.requiresAttention(stderr) { return .needsInput("opencode_attention_requires_manual_attachment") }
            guard sessionID != nil, finalMessageID != nil else {
                return .disconnected("opencode_ended_without_native_finish_delivery_uncertain")
            }
            return .completed(textOrder.compactMap { textParts[$0] }.joined(separator: "\n"))
        }

        private mutating func invalidPart(_ events: [AgentTaskEvent]) -> [AgentTaskEvent] {
            terminal = .disconnected("opencode_invalid_part")
            return events
        }

        static func validSessionID(_ value: String) -> Bool {
            value.hasPrefix("ses_") && value.count > 4 && value.utf8.dropFirst(4).allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
        }

        private static func requiresAttention(_ text: String) -> Bool {
            // Native v1 permission error messages lose their error tag inside
            // tool state. Also recognize the run CLI's stderr-only warning.
            text.contains("PermissionRejectedError") || text.contains("PermissionDeniedError") ||
                text.contains("QuestionRejectedError") ||
                text.contains("The user dismissed this question") ||
                text.contains("The user rejected permission to use this specific tool call") ||
                text.contains("The user has specified a rule which prevents you from using this specific tool call") ||
                (text.contains("permission requested:") && text.contains("auto-rejecting"))
        }
    }
}
