import Foundation
@testable import CmuxChief

/// Deterministic provider and authorization gates; tests never sleep or submit real model work.
actor AgentTaskScheduleTestProbe {
    enum Failure: Error { case denied, lostResponse }
    var operations: [UUID] = []
    var deny = false
    var loseResponse = false
    var gateDispatch = false
    var gateAuthorization = false
    private var dispatchGate: CheckedContinuation<Void, Never>?
    private var authorizationGate: CheckedContinuation<Void, Never>?
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationEntered = false

    func configure(deny: Bool = false, loseResponse: Bool = false, gateDispatch: Bool = false,
                   gateAuthorization: Bool = false) {
        self.deny = deny
        self.loseResponse = loseResponse
        self.gateDispatch = gateDispatch
        self.gateAuthorization = gateAuthorization
        authorizationEntered = false
    }

    func authorize(_ schedule: AgentTaskSchedule) async throws {
        if gateAuthorization {
            authorizationEntered = true
            authorizationWaiters.forEach { $0.resume() }
            authorizationWaiters.removeAll()
            await withCheckedContinuation { authorizationGate = $0 }
        }
        if deny { throw Failure.denied }
    }

    func dispatch(_ target: AgentTaskScheduleTarget, prompt: String, operationID: UUID) async throws -> AgentTaskScheduleAcceptance {
        operations.append(operationID)
        dispatchWaiters.forEach { $0.resume() }
        dispatchWaiters.removeAll()
        if gateDispatch { await withCheckedContinuation { dispatchGate = $0 } }
        if loseResponse { throw Failure.lostResponse }
        let taskID: UUID
        switch target {
        case .existingTask(let id): taskID = id
        case .newTask: taskID = UUID()
        }
        return AgentTaskScheduleAcceptance(taskID: taskID, operationID: operationID, providerReference: "provider:\(operationID)")
    }

    func waitForDispatch() async {
        if !operations.isEmpty { return }
        await withCheckedContinuation { dispatchWaiters.append($0) }
    }

    func waitForAuthorization() async {
        if authorizationEntered { return }
        await withCheckedContinuation { authorizationWaiters.append($0) }
    }

    func releaseDispatch() { gateDispatch = false; dispatchGate?.resume(); dispatchGate = nil }
    func releaseAuthorization() { gateAuthorization = false; authorizationGate?.resume(); authorizationGate = nil }
}
