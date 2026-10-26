import CmuxChief
import Foundation

extension NativeAgentOrchestration {
    /// Repairs every durable turn, including one superseded by a newer task projection before a crash.
    func reconcileTurnReceipt(_ turn: AgentTaskTurnRecord) async throws {
        guard turn.phase.isSettled, var record = try await runtime.coordinator.record(turn.taskID),
              let phase = AgentTaskRecord.Phase(rawValue: turn.phase.rawValue) else { return }
        record.latestOperationID = turn.operationID
        record.phase = phase
        record.sessionID = turn.sessionID ?? record.sessionID
        record.result = turn.result
        record.detail = turn.detail
        record.updatedAt = turn.updatedAt
        try await recordChanged(record)
    }

    /// A durable provider receipt may create a passive inbox event, never another model turn.
    func recordChanged(_ record: AgentTaskRecord) async throws {
        if let operation = record.latestOperationID,
           record.phase.isFinished || record.phase == .needsInput || record.phase == .disconnected {
            if let parent = record.parentTaskID {
                let result = record.result.map { AgentTaskInboxResult.body(String($0.prefix(16_000))) }
                _ = try await journal.appendInbox(ownerTaskID: parent, taskID: record.id,
                    operationID: operation, phase: record.phase, result: result)
            }
            // Repair the receipt/inbox crash window by exact operation identity, not latest task state.
            try await reconcileScheduledReceipt(record, operationID: operation)
        }
        if !panels.isEmpty { try await refreshPanels() }
    }

    func reconcileScheduledReceipt(_ record: AgentTaskRecord, operationID: UUID) async throws {
        guard record.phase.isFinished else { return }
        guard let context = try await journal.scheduledReceipt(operationID) else { return }
        let occurrence = context.occurrence, owner = context.ownerTaskID
        guard let session = record.sessionID, record.phase == .completed || occurrence.acceptance != nil else { return }
        if occurrence.acceptance == nil {
            let native = await runtime.backend.providerTurn(id: record.id)
            let reference = native.flatMap { $0.operationID == operationID ? $0.providerTurnID : nil }
                ?? "session-ack:" + session + ":" + operationID.uuidString
            _ = try await journal.confirmAcceptance(.init(taskID: record.id, operationID: operationID,
                providerReference: reference), ownerTaskID: owner)
        }
        _ = try await journal.completeOccurrence(operationID: operationID, ownerTaskID: owner, phase: record.phase)
        await armTimer()
    }

    func interactionData(_ id: UUID) async throws -> Data {
        let pending = await runtime.backend.interactions(id: id)
        let rows: [[String: Any]] = pending.map { item in
            ["task_id": item.taskID.uuidString, "request_id": item.requestID,
             "kind": item.kind.rawValue, "method": item.method, "summary": item.summary,
             "options": item.options, "answer": item.answer.rawValue,
             "request": (try? JSONSerialization.jsonObject(with: item.request)) ?? NSNull()]
        }
        return try data(["interactions": rows])
    }

    func respondData(_ args: [String: Any], scope: AgentTaskScope?) async throws -> Data {
        let id = try target(args, scope: scope)
        try await authorizeTarget(scope, id: id, operation: .send)
        guard let request = args["interaction_id"] as? String,
              let response = args["response"] as? [String: Any] else { throw CocoaError(.validationMissingMandatoryProperty) }
        // A child cannot approve its own tools or escalate permissions through delegation.
        guard scope == nil else { throw CocoaError(.fileReadNoPermission) }
        try await runtime.backend.respond(id: id, requestID: request, response: data(response))
        return try data(["task_id": id.uuidString, "request_id": request, "response_sent": true])
    }
}
