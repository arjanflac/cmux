import Foundation

/// A stable UUID-ordered page containing only currently authorized worker metadata.
public struct AgentTaskWorkerDirectoryPage: Codable, Equatable, Sendable {
    /// Small descendant projections, never the owner, peers or arbitrary workspace sessions.
    public let workers: [AgentTaskWorkerSummary]
    /// Last visible UUID when another visible page exists; null otherwise.
    public let nextCursor: UUID?
    /// Whether another authorized, visible worker follows this page.
    public let hasMore: Bool

    init(workers: [AgentTaskWorkerSummary], nextCursor: UUID?, hasMore: Bool) {
        self.workers = workers; self.nextCursor = nextCursor; self.hasMore = hasMore
    }

    /// Encodes a bounded response with an explicit null cursor on the final page.
    /// - Parameter encoder: The directory response encoder.
    /// - Throws: Encoding errors.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(workers, forKey: .workers)
        try values.encode(nextCursor, forKey: .nextCursor)
        try values.encode(hasMore, forKey: .hasMore)
    }

    private enum CodingKeys: String, CodingKey { case workers, nextCursor = "next_cursor", hasMore = "has_more" }
}
