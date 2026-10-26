import Foundation

extension NativeAgentOrchestration {
    /// Local operator commands are explicit; model bridge calls require a live scope instead.
    func control(method: String, parameters: Data) async throws -> Data {
        try await restore()
        guard var params = try JSONSerialization.jsonObject(with: parameters) as? [String: Any] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        if method == "agent.task.panel" { return try await panel(params) }
        if method == "agent.task.bridge" { return try await bridge(params) }
        let name = String(method.dropFirst("agent.task.".count))
        if name == "schedule" { params["action"] = "schedule." + (params.removeValue(forKey: "schedule_action") as? String ?? "list") }
        else { params["action"] = name == "wait-turn" ? "wait" : name }
        let requestID = params["request_id"] as? String
        return try await execute(["arguments": params, "request_id": requestID ?? ""], scope: nil)
    }
}
