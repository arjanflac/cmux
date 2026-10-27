import Foundation
@testable import CmuxChief

actor TurnFixtureBackend: AgentTaskBackend {
    struct Submission: Sendable {
        let taskID: UUID
        let record: AgentTaskRecord?
        let prompt: String
    }
    private var submissions: [UUID: Submission] = [:]
    private var submissionWaiters: [UUID: [CheckedContinuation<Submission, Never>]] = [:]
    private var streams: [UUID: AsyncThrowingStream<AgentTaskEvent, any Error>.Continuation] = [:]
    private(set) var cancelled: [UUID] = []
    var submittedCount: Int { submissions.count }

    func start(id: UUID, request: AgentTaskRequest) -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        submit(operationID: id, submission: Submission(taskID: id, record: nil, prompt: request.prompt))
    }

    func continueTask(id: UUID, record: AgentTaskRecord, request: AgentTaskTurnRequest) -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        submit(operationID: request.operationID, submission: Submission(taskID: id, record: record, prompt: request.prompt))
    }

    private func submit(operationID: UUID, submission: Submission) -> AsyncThrowingStream<AgentTaskEvent, any Error> {
        let pair = AsyncThrowingStream.makeStream(of: AgentTaskEvent.self)
        streams[operationID] = pair.continuation
        submissions[operationID] = submission
        for waiter in submissionWaiters.removeValue(forKey: operationID) ?? [] { waiter.resume(returning: submission) }
        return pair.stream
    }

    func submission(_ operationID: UUID) async -> Submission {
        if let submission = submissions[operationID] { return submission }
        return await withCheckedContinuation { submissionWaiters[operationID, default: []].append($0) }
    }

    func emit(_ event: AgentTaskEvent, operationID: UUID) { streams[operationID]?.yield(event) }
    func finish(_ operationID: UUID) { streams.removeValue(forKey: operationID)?.finish() }
    func cancel(id: UUID) { cancelled.append(id) }
}
