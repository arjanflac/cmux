import Foundation
import Testing
@testable import CmuxChief

@Suite("Native Codex transport")
struct AgentCodexTransportTests {
    @Test func fragmentedTextAllowsInterleavedPingAndPartialReads() throws {
        var frames = AgentWebSocketFrames()
        #expect(try frames.receive(Data([0x01])) == [])
        #expect(try frames.receive(Data([0x02, 65, 66, 0x89, 1, 120])) == [.ping(Data([120]))])
        #expect(try frames.receive(Data([0x80, 2, 67, 68])) == [.text(Data("ABCD".utf8))])
    }

    @Test func rejectsMaskedServerFramesAndOversizedControlFrames() {
        var frames = AgentWebSocketFrames()
        #expect(throws: (any Error).self) { try frames.receive(Data([0x81, 0x81, 1, 2, 3, 4, 65])) }
        #expect(throws: (any Error).self) { try frames.receive(Data([0x89, 126, 0, 126])) }
    }

    @Test func rejectsUnboundedDeclaredLengthWithoutAllocatingIt() {
        var frames = AgentWebSocketFrames()
        #expect(throws: (any Error).self) { try frames.receive(Data([0x81, 127] + Array(repeating: 255, count: 8))) }
    }

    @Test(arguments: [0, 1, 125, 126, 65_535, 65_536])
    func clientFramesMaskAndPreserveEveryPayloadByte(_ size: Int) throws {
        let payload = Data(repeating: 97, count: size)
        let frame = try AgentWebSocketFrames.clientFrame(payload)
        #expect(frame[0] == 0x81)
        #expect(frame[1] & 0x80 != 0)
        let header = size < 126 ? 2 : (size <= 65_535 ? 4 : 10)
        let mask = Array(frame[header..<(header + 4)])
        let decoded = Data(frame.dropFirst(header + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
        #expect(decoded == payload)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_CODEX_SOCKET"] != nil))
    func connectsToExistingDaemonWithoutStartingOrResumingAThread() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CMUX_TEST_CODEX_SOCKET"])
        let client = AgentCodexConnection(path: path)
        _ = try await client.request("initialize", .object([
            "clientInfo": .object(["name": .string("cmux_native_transport_test"), "version": .string("0.1")]),
            "capabilities": .object([:]),
        ]))
        try await client.notify("initialized")
        let response = try await client.request("thread/loaded/list")
        #expect(response["data"]?.array != nil)
        await client.close()
    }
}
