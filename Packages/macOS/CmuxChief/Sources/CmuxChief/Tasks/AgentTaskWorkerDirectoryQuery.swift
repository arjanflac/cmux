import Foundation

/// Bounded metadata pagination; a cursor is a UUID boundary, never an authorization token.
public struct AgentTaskWorkerDirectoryQuery: Codable, Equatable, Sendable {
    /// Exclusive stable UUID boundary from the preceding page.
    public let cursor: UUID?
    /// Maximum visible rows, between one and fifty; defaults to twenty.
    public let limit: Int
    /// Whether authorized locally retired or retiring workers are included for diagnosis.
    public let includeRetired: Bool

    /// Creates a bounded read request.
    /// - Parameters:
    ///   - cursor: Previous page boundary, independent of activity ordering.
    ///   - limit: Visible row cap, default twenty and maximum fifty.
    ///   - includeRetired: False by default; true never expands task authority.
    /// - Throws: ``Failure/invalidParameters`` for a limit outside one through fifty.
    public init(cursor: UUID? = nil, limit: Int = 20, includeRetired: Bool = false) throws {
        guard (1...50).contains(limit) else { throw Failure.invalidParameters }
        self.cursor = cursor; self.limit = limit; self.includeRetired = includeRetired
    }

    /// Decodes strict JSON types and rejects malformed cursors without silently restarting pagination.
    /// - Parameter decoder: The action's JSON body.
    /// - Throws: Decoding errors or ``Failure/invalidParameters``.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decodeIfPresent(String.self, forKey: .cursor)
        let cursor: UUID?
        if let raw {
            guard raw.utf8.count == 36, let id = UUID(uuidString: raw) else { throw Failure.invalidParameters }
            cursor = id
        } else { cursor = nil }
        try self.init(cursor: cursor, limit: values.decodeIfPresent(Int.self, forKey: .limit) ?? 20,
                      includeRetired: values.decodeIfPresent(Bool.self, forKey: .includeRetired) ?? false)
    }

    /// Why a metadata read could not establish a bounded authorized snapshot.
    public enum Failure: Error, Equatable, Sendable {
        /// Cursor, limit or another request value is invalid.
        case invalidParameters
        /// The authenticated owner has no matching durable workspace identity.
        case ownerUnavailable
        /// Authority changed to another owner or workspace during the read.
        case authorizationChanged
    }

    private enum CodingKeys: String, CodingKey { case cursor, limit, includeRetired = "include_retired" }
}
