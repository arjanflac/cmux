import CmuxChief
import Foundation

extension NativeAgentOrchestration {
    /// All model-affecting entrypoints share one durable admission path.
    func execute(_ envelope: [String: Any], scope: AgentTaskScope?) async throws -> Data {
        if scope != nil, !enabled { throw CocoaError(.featureUnsupported) }
        guard let rawArguments = envelope["arguments"] as? [String: Any] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var arguments = normalize(rawArguments)
        guard let action = arguments["action"] as? String else { throw CocoaError(.validationMissingMandatoryProperty) }
        // Storage admission failures cannot hide existing results or prevent a cancellation.
        if ["start", "send", "respond", "schedule.create", "schedule.resume"].contains(action) { try ensureHealthy() }
        if let scope {
            if let claimed = arguments["owner_task_id"] as? String, UUID(uuidString: claimed) != scope.ownerTaskID {
                throw CocoaError(.fileReadNoPermission)
            }
            arguments["owner_task_id"] = scope.ownerTaskID.uuidString
        }
        let mutations: Set<String> = ["start", "send", "cancel", "respond", "ack", "schedule.create", "schedule.pause", "schedule.resume", "schedule.cancel"]
        guard mutations.contains(action) else { return try await perform(arguments, scope: scope, operationID: nil) }
        guard let raw = arguments["request_id"] as? String ?? envelope["request_id"] as? String, !raw.isEmpty, raw.utf8.count <= 256 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let operation = identity((scope?.ownerTaskID.uuidString ?? "operator") + ":" + raw)
        let canonical = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        guard canonical.count <= 262_144 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let previous = try await ledger.begin(operation, arguments: canonical)
        if let running = commandTasks[operation] { return try await running.value }
        if let previous {
            if let response = previous.response { return response }
            return try data(["request_id": raw, "operation_id": operation.uuidString,
                             "phase": "disconnected", "detail": "acceptance_unknown_no_replay"])
        }
        let input = canonical
        let job = Task { @MainActor in
            guard let args = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let response = try await self.perform(args, scope: scope, operationID: operation)
            try await self.ledger.complete(operation, response: response)
            return response
        }
        commandTasks[operation] = job
        defer { commandTasks.removeValue(forKey: operation) }
        return try await job.value
    }

    func perform(_ args: [String: Any], scope: AgentTaskScope?, operationID: UUID?) async throws -> Data {
        guard let action = args["action"] as? String else { throw CocoaError(.validationMissingMandatoryProperty) }
        switch action {
        case "start":
            guard let operationID else { throw CocoaError(.validationMissingMandatoryProperty) }
            let request = try await newRequest(args, scope: scope)
            guard request.provider == .codex || request.presentation == .background else { throw CocoaError(.featureUnsupported) }
            if let scope { _ = try await authority.allowChild(owner: scope, newChildID: operationID) }
            else if let parent = request.parentTaskID {
                let generation = "task:" + parent.uuidString + ":" + authority.epoch.uuidString
                let owner = try await issueScope(ownerID: parent, generation: generation)
                _ = try await authority.allowChild(owner: owner.scope, newChildID: operationID)
            }
            let receipt = try await runtime.coordinator.start(request, id: operationID)
            return try data(object(receipt))
        case "send":
            guard let operationID, let prompt = args["prompt"] as? String else { throw CocoaError(.validationMissingMandatoryProperty) }
            let id = try target(args, scope: scope)
            try await authorizeTarget(scope, id: id, operation: .send)
            try requireExclusiveWorker(id)
            let receipt = try await runtime.coordinator.send(id, prompt: prompt, operationID: operationID)
            return try turnData(receipt)
        case "read", "interactions", "cancel", "turns":
            let id = try target(args, scope: scope)
            try await authorizeTarget(scope, id: id, operation: action == "cancel" ? .cancel : .read)
            if action == "cancel" { try await runtime.coordinator.cancel(id) }
            if action == "turns" {
                let turns = try await runtime.coordinator.turns(taskID: id)
                return try data(["turns": try turns.suffix(30).map { turn -> [String: Any] in
                    var row = try object(turn); row.removeValue(forKey: "prompt"); row.removeValue(forKey: "result")
                    if let detail = row["detail"] as? String { row["detail"] = String(detail.prefix(256)) }
                    return row
                }, "has_more": turns.count > 30])
            }
            if action == "interactions" { return try await interactionData(id) }
            guard let record = try await runtime.coordinator.record(id) else { throw CocoaError(.fileNoSuchFile) }
            return try data(object(record))
        case "result", "wait":
            let latest = if let id = (args["task_id"] as? String).flatMap(UUID.init(uuidString:)) {
                try await runtime.coordinator.record(id)?.latestOperationID
            } else { nil as UUID? }
            guard let operation = (args["operation_id"] as? String).flatMap(UUID.init(uuidString:)) ?? latest,
                  let existing = try await runtime.coordinator.turn(operation) else { throw CocoaError(.fileNoSuchFile) }
            try await authorizeTarget(scope, id: existing.taskID, operation: .read)
            let receipt = action == "wait" ? try await runtime.coordinator.waitTurn(operation) : existing
            return try turnData(receipt)
        case "inbox":
            let owner = try owner(args, scope: scope)
            try await authorizeTarget(scope, id: owner, operation: .read)
            let rows = try await journal.inbox(ownerTaskID: owner, afterSequence: args["after_sequence"] as? Int64 ?? 0, limit: 50)
            return try data(["events": try rows.map { event -> [String: Any] in
                var row = try object(event); row.removeValue(forKey: "result"); row["has_result"] = event.result != nil; return row
            }])
        case "ack":
            let owner = try owner(args, scope: scope)
            try await authorizeTarget(scope, id: owner, operation: .read)
            guard let event = (args["event_id"] as? String).flatMap(UUID.init(uuidString:)) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let receipt = try await journal.acknowledge(ownerTaskID: owner, eventID: event)
            _ = try await runtime.coordinator.retireAcknowledgedWorker(receipt)
            try await refreshPanels()
            return try data(object(receipt))
        case "respond": return try await respondData(args, scope: scope)
        default:
            if action.hasPrefix("schedule.") { return try await scheduleCommand(args, scope: scope, operationID: operationID) }
            throw CocoaError(.featureUnsupported)
        }
    }

    /// Adapters may use a namespaced action/body shape; the domain sees one canonical object.
    func normalize(_ input: [String: Any]) -> [String: Any] {
        var result = input["body"] as? [String: Any] ?? input
        result.removeValue(forKey: "body")
        let action = input["action"] as? String ?? result["action"] as? String ?? ""
        if action == "schedule" {
            result["action"] = "schedule." + (result["command"] as? String ?? result["schedule_action"] as? String ?? "create")
            result.removeValue(forKey: "command"); result.removeValue(forKey: "schedule_action")
        } else { result["action"] = action }
        return result
    }

    func target(_ args: [String: Any], scope: AgentTaskScope?) throws -> UUID {
        if let raw = args["task_id"] as? String, let id = UUID(uuidString: raw) { return id }
        if let scope { return scope.ownerTaskID }
        throw CocoaError(.validationMissingMandatoryProperty)
    }

    func owner(_ args: [String: Any], scope: AgentTaskScope?) throws -> UUID {
        if let scope { return scope.ownerTaskID }
        if let raw = args["owner_task_id"] as? String ?? args["task_id"] as? String, let id = UUID(uuidString: raw) { return id }
        throw CocoaError(.validationMissingMandatoryProperty)
    }

    func authorizeTarget(_ scope: AgentTaskScope?, id: UUID, operation: AgentTaskScopeOperation) async throws {
        guard let scope else { return } // Explicit local operator commands, never implicit environment enrollment.
        _ = try await authority.authorizeTrustedOwner(ownerTaskID: scope.ownerTaskID,
            callerSessionID: scope.providerSessionID, bindingGeneration: scope.bindingGeneration,
            operation: operation, targetTaskID: id)
    }

    func newRequest(_ args: [String: Any], scope: AgentTaskScope?, parentOverride: UUID? = nil) async throws -> AgentTaskRequest {
        guard let provider = (args["provider"] as? String).flatMap(AgentTaskRequest.Provider.init(rawValue:)),
              let prompt = args["prompt"] as? String else { throw CocoaError(.validationMissingMandatoryProperty) }
        let parent = parentOverride ?? scope?.ownerTaskID ?? (args["parent_task_id"] as? String).flatMap(UUID.init(uuidString:))
        let inherited = if let parent { try await runtime.coordinator.record(parent) } else { nil as AgentTaskRecord? }
        let workspaceID = (args["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
            ?? inherited.flatMap { runtime.workspaceID(for: $0) }
        guard let workspaceID, let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceID), !workspace.isRemoteWorkspace,
              let cwd = args["cwd"] as? String ?? inherited?.workingDirectory.path, cwd.hasPrefix("/") else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        if let scope, workspace.stableId != scope.workspaceStableID { throw CocoaError(.fileReadNoPermission) }
        let mode = (args["permission_mode"] as? String).flatMap(AgentTaskRequest.PermissionMode.init(rawValue:)) ?? .providerDefault
        if scope != nil, mode == .unrestricted { throw CocoaError(.fileReadNoPermission) }
        let lifecycle: AgentTaskRequest.Lifecycle
        if let raw = args["lifecycle"] as? String {
            guard let parsed = AgentTaskRequest.Lifecycle(rawValue: raw) else { throw CocoaError(.validationMissingMandatoryProperty) }
            lifecycle = parsed
        } else { lifecycle = parent != nil && (args["background"] as? Bool) != false ? .oneShot : .persistent }
        if lifecycle == .oneShot, parent == nil { throw CocoaError(.validationMissingMandatoryProperty) }
        return AgentTaskRequest(provider: provider, prompt: prompt, workspaceID: workspaceID,
            workingDirectory: URL(fileURLWithPath: cwd), model: args["model"] as? String, effort: args["effort"] as? String,
            presentation: (args["background"] as? Bool) == false ? .terminal : .background,
            parentTaskID: parent, workspaceStableID: workspace.stableId, permissionMode: mode, lifecycle: lifecycle)
    }

    /// An interactive Claude/OpenCode view is an exclusive-writer handoff, not a second process to steer.
    func requireExclusiveWorker(_ id: UUID) throws {
        guard let record = runtime.coordinator.records[id], record.provider != .codex,
              let surface = record.surfaceID, let workspace = runtime.workspaceID(for: record) else { return }
        if AppDelegate.shared?.workspaceFor(tabId: workspace)?.terminalPanel(for: surface) != nil {
            throw CocoaError(.userCancelled)
        }
    }

    func turnData(_ turn: AgentTaskTurnRecord) throws -> Data {
        var row = try object(turn)
        row.removeValue(forKey: "prompt")
        return try data(row)
    }
}
