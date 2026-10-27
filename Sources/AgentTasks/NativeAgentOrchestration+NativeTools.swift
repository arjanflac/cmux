import CmuxChief
import Foundation

extension NativeAgentOrchestration {
    /// Only the native driver may call this with authenticated provider thread, turn and call IDs.
    func nativeTool(_ call: AgentTaskToolCall) async throws -> Data {
        try await restore()
        guard call.arguments.count <= 262_144,
              let existing = try await runtime.coordinator.record(call.taskID),
              existing.provider == .codex, existing.sessionID == nil || existing.sessionID == call.sessionID else {
            throw CocoaError(.fileReadNoPermission)
        }
        if existing.sessionID == nil {
            // A tool can race the actor consuming the already-confirmed session event.
            try await runtime.coordinator.receive(.session(call.sessionID), id: call.taskID)
        }
        let generation = "task:" + call.taskID.uuidString + ":" + authority.epoch.uuidString
        let capability = try await issueScope(ownerID: call.taskID, generation: generation)
        guard let raw = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let args = normalize(raw)
        let scope = try await authority.authorizeTrustedOwner(ownerTaskID: call.taskID,
            callerSessionID: call.sessionID, bindingGeneration: capability.scope.bindingGeneration,
            operation: .read)
        let key = call.sessionID + ":" + call.providerTurnID + ":" + call.callID
        let responds = claimResponse(key, caller: "native:" + call.connectionGeneration.uuidString)
        return try await toolReply(["request_id": call.callID, "arguments": raw], arguments: args, scope: scope, responds: responds)
    }

    /// Once the broker owns the reply, validation or dispatch errors must retain that ownership.
    /// A second attached client neither executes nor resolves the same provider request.
    func toolReply(_ envelope: [String: Any], arguments: [String: Any], scope: AgentTaskScope, responds: Bool) async throws -> Data {
        guard responds else { return try data(["_cmux_should_respond": false]) }
        var value: [String: Any]
        do {
            guard enabled else { throw CocoaError(.featureUnsupported) }
            let action = arguments["action"] as? String ?? ""
            let current = try await authority.authorizeTrustedOwner(ownerTaskID: scope.ownerTaskID,
                callerSessionID: scope.providerSessionID, bindingGeneration: scope.bindingGeneration,
                operation: operation(for: action), targetTaskID: targetID(arguments),
                parentTaskID: (arguments["parent_task_id"] as? String).flatMap(UUID.init(uuidString:)))
            let response = try await execute(envelope, scope: current)
            value = try JSONSerialization.jsonObject(with: response) as? [String: Any] ?? [:]
        } catch {
            value = ["phase": "unconfirmed", "error": String(String(describing: error).prefix(4096)),
                     "detail": enabled ? "inspect_operation_before_retry" : "orchestration_disabled",
                     "_cmux_tool_error": true]
        }
        value["_cmux_should_respond"] = true
        return try data(value)
    }
}
