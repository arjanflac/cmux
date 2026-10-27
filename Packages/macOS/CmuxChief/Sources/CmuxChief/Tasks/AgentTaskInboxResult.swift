import Foundation

/// A bounded private result body or an opaque reference; neither submits model input.
public enum AgentTaskInboxResult: Codable, Equatable, Sendable {
    /// UTF-8 result text, at most 65,536 bytes.
    case body(String)
    /// App-resolved result reference, at most 4,096 UTF-8 bytes; never fetched by the inbox.
    case reference(String)

    func validate() throws {
        switch self {
        case .body(let value):
            guard value.utf8.count <= 65_536 else { throw AgentTaskJournalError.invalidRequest }
        case .reference(let value):
            guard !value.isEmpty, value.utf8.count <= 4_096 else { throw AgentTaskJournalError.invalidRequest }
        }
    }
}
