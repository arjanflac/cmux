import CryptoKit
import Foundation

/// Minimal acknowledgement evidence; provider results stay in their independent turn repository.
struct AgentTaskInboxTombstone: Codable {
    let event: AgentTaskInboxEvent
    let resultDigest: String

    init(_ event: AgentTaskInboxEvent) throws {
        self.event = AgentTaskInboxEvent(metadata: event, result: nil, resultCompacted: true)
        resultDigest = try Self.digest(event.result)
    }

    func matches(_ result: AgentTaskInboxResult?) throws -> Bool { try resultDigest == Self.digest(result) }

    func replay(_ result: AgentTaskInboxResult?) -> AgentTaskInboxEvent {
        AgentTaskInboxEvent(metadata: event, result: result, resultCompacted: nil)
    }

    private static func digest(_ result: AgentTaskInboxResult?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(result)).map { String(format: "%02x", $0) }.joined()
    }
}
