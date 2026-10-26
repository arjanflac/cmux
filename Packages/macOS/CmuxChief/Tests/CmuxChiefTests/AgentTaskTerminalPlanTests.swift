import Foundation
import Testing
@testable import CmuxChief

@Suite("Managed task launch boundary")
struct AgentTaskTerminalPlanTests {
    @Test func claudeHooksCarryExactTaskAndSessionWithoutChangingUserConfiguration() throws {
        let request = AgentTaskRequest(provider: .claude, prompt: "Review design", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"), model: "haiku", effort: "low")
        var record = AgentTaskRecord(id: UUID(), request: request, now: Date())
        record.sessionID = UUID().uuidString
        let arguments = try AgentTaskTerminalPlan().arguments(record: record, request: request,
            cmuxExecutable: "/path with spaces/cmux", cmuxSocket: "/tmp/test.sock")
        #expect(arguments.prefix(3) == ["claude", "--session-id", record.sessionID!])
        let settingsIndex = try #require(arguments.firstIndex(of: "--settings"))
        let settings = try JSONSerialization.jsonObject(with: Data(arguments[settingsIndex + 1].utf8)) as? [String: Any]
        let hooks = try #require(settings?["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == ["SessionStart", "Stop", "StopFailure", "SessionEnd"])
        for groups in hooks.values {
            let callbacks = try #require(groups.first?["hooks"] as? [[String: Any]])
            let command = try #require(callbacks.first?["command"] as? String)
            #expect(command.contains(record.id.uuidString))
            #expect(command.contains("'/path with spaces/cmux' '--socket' '/tmp/test.sock'"))
        }
        let contextIndex = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        #expect(arguments[contextIndex + 1].contains(request.workspaceID.uuidString))
        #expect(arguments[contextIndex + 1].contains(record.id.uuidString))
        #expect(!arguments.contains(request.prompt))
    }

    @Test func codexUsesNormalResumeWithoutAProxyOrConfigOverrides() throws {
        let request = AgentTaskRequest(provider: .codex, prompt: "Review", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp"), model: "gpt-6-luna")
        var record = AgentTaskRecord(id: UUID(), request: request, now: Date())
        record.sessionID = "managed-session"
        #expect(try AgentTaskTerminalPlan().arguments(record: record, request: request,
            cmuxExecutable: "cmux", cmuxSocket: "/tmp/test.sock") == ["codex", "resume", "managed-session", "--model", "gpt-6-luna"])
    }

    @Test func aSavedSurfaceIDDoesNotClaimALiveTerminal() {
        let request = AgentTaskRequest(provider: .codex, prompt: "Review", workspaceID: UUID(), workingDirectory: URL(fileURLWithPath: "/tmp"))
        var record = AgentTaskRecord(id: UUID(), request: request, now: Date())
        let plan = AgentTaskTerminalPlan()
        #expect(plan.liveSurfaceStatus(record: record, surfaceIsPresent: false) == "not_created")
        record.surfaceID = UUID()
        record.phase = .running
        #expect(plan.liveSurfaceStatus(record: record, surfaceIsPresent: false) == "surface_missing")
        #expect(plan.liveSurfaceStatus(record: record, surfaceIsPresent: true) == "surface_present")
        #expect(record.phase == .running)
        record.presentation = .background
        #expect(plan.liveSurfaceStatus(record: record, surfaceIsPresent: false) == "headless")
    }

    @Test func shellWordPreservesTaskTextAsData() throws {
        let input = "quotes ' and $HOME and $(false); `false`\nnext line"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + AgentTaskTerminalPlan.shellWord(input)]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output, as: UTF8.self) == input)
    }
}
