import Foundation

/// One submission's outgoing event stream, bounded without silently losing a transition.
///
/// Repeated progress events are coalesced. When the consumer falls behind
/// and the buffer fills, the stream ends with
/// ``AgentManagedTaskError/eventOverflow`` instead of dropping an event, so
/// the coordinator records uncertainty rather than a stale phase.
struct AgentTaskEventSink {
    /// Events buffered for a slow consumer before the stream fails.
    static let capacity = 256
    private let continuation: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation
    private var last: AgentTaskEvent?
    private(set) var closed = false

    private init(continuation: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// A new stream and the sink that feeds it.
    static func make() -> (AsyncThrowingStream<AgentTaskEvent, any Error>, AgentTaskEventSink) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AgentTaskEvent.self, throwing: (any Error).self,
                                                                    bufferingPolicy: .bufferingOldest(capacity))
        return (stream, AgentTaskEventSink(continuation: continuation))
    }

    /// Delivers `event` unless it repeats the previous progress event.
    mutating func yield(_ event: AgentTaskEvent) {
        guard !closed else { return }
        if event == last, Self.isProgress(event) { return }
        last = event
        switch continuation.yield(event) {
        case .dropped: fail(AgentManagedTaskError.eventOverflow)
        case .terminated: closed = true
        default: break
        }
    }

    /// Ends the stream normally.
    mutating func finish() {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    /// Ends the stream with `error` after already-buffered events.
    mutating func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        continuation.finish(throwing: error)
    }

    private static func isProgress(_ event: AgentTaskEvent) -> Bool {
        switch event {
        case .running, .needsInput: return true
        default: return false
        }
    }
}
