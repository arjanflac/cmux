import CmuxChief
import Foundation

extension NativeAgentOrchestration {
    func scheduleCommand(_ args: [String: Any], scope: AgentTaskScope?, operationID: UUID?) async throws -> Data {
        guard let action = args["action"] as? String, let scheduler = schedulerStorage else { throw CocoaError(.featureUnsupported) }
        let ownerID = try owner(args, scope: scope)
        if action == "schedule.create" {
            var protectedTasks: Set<UUID> = [ownerID]
            if args["provider"] == nil {
                protectedTasks.insert((args["target_task_id"] as? String).flatMap(UUID.init(uuidString:)) ?? ownerID)
            }
            return try await runtime.coordinator.withScheduleAdmission(taskIDs: protectedTasks) {
                try await self.authorizeTarget(scope, id: ownerID, operation: .send)
                return try await self.createSchedule(args, scope: scope, operationID: operationID, ownerID: ownerID, scheduler: scheduler)
            }
        }
        try await authorizeTarget(scope, id: ownerID, operation: action == "schedule.list" || action == "schedule.read" ? .read : .send)
        if action == "schedule.list" {
            return try data(["schedules": try await scheduler.list(ownerTaskID: ownerID).map { try scheduleObject($0) },
                             "dispatch_lifetime": "while_cmux_is_open"])
        }
        guard let id = (args["schedule_id"] as? String).flatMap(UUID.init(uuidString:)) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let receipt: AgentTaskSchedule?
        switch action {
        case "schedule.read": receipt = try await scheduler.read(id, ownerTaskID: ownerID)
        case "schedule.pause": receipt = try await scheduler.pause(id, ownerTaskID: ownerID)
        case "schedule.resume": receipt = try await scheduler.resume(id, ownerTaskID: ownerID)
        case "schedule.cancel": receipt = try await scheduler.cancel(id, ownerTaskID: ownerID)
        default: throw CocoaError(.featureUnsupported)
        }
        guard let receipt else { throw CocoaError(.fileNoSuchFile) }
        await armTimer()
        return try data(scheduleObject(receipt))
    }

    /// The caller holds both referenced tasks until this journal commit finishes.
    private func createSchedule(_ args: [String: Any], scope: AgentTaskScope?, operationID: UUID?,
                                ownerID: UUID, scheduler: AgentTaskScheduler) async throws -> Data {
        guard let operationID, let prompt = args["prompt"] as? String,
              let due = date(args["due_at"] as? String) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let destination: AgentTaskScheduleTarget
        if args["provider"] != nil {
            let request = try await newRequest(args, scope: scope, parentOverride: ownerID)
            destination = .newTask(request)
        } else {
            let target = (args["target_task_id"] as? String).flatMap(UUID.init(uuidString:)) ?? ownerID
            try await authorizeTarget(scope, id: target, operation: .send)
            guard let targetRecord = try await runtime.coordinator.record(target), targetRecord.retirement == nil,
                  !runtime.coordinator.isRetiredOrRetiring(target) else { throw CocoaError(.userCancelled) }
            destination = .existingTask(target)
        }
        if case .newTask = destination {
            let ownerScope: AgentTaskScope
            if let scope { ownerScope = scope }
            else {
                let generation = "task:" + ownerID.uuidString + ":" + authority.epoch.uuidString
                ownerScope = try await issueScope(ownerID: ownerID, generation: generation).scope
            }
            // Long recurrences should reuse one conversation. Fresh workers consume
            // immutable lifetime lineage slots; completion never silently refills them.
            let remaining = try await authority.remainingChildCapacity(owner: ownerScope)
            guard (1...max(1, remaining)).contains(args["max_runs"] as? Int ?? 1), remaining > 0 else {
                throw AgentTaskScopeError.childLimitExceeded
            }
        }
        let recurrence: AgentTaskScheduleRequest.Recurrence
        if let seconds = args["repeat_seconds"] as? Double { recurrence = .interval(seconds: seconds) }
        else { recurrence = .once }
        let request = AgentTaskScheduleRequest(ownerTaskID: ownerID, target: destination, prompt: prompt,
            dueAt: due, timeZoneID: args["time_zone"] as? String ?? TimeZone.current.identifier,
            recurrence: recurrence,
            misfire: (args["misfire"] as? String).flatMap(AgentTaskScheduleRequest.MisfirePolicy.init(rawValue:)) ?? .hold,
            expiresAt: date(args["expires_at"] as? String), maxRuns: args["max_runs"] as? Int ?? 1)
        let receipt = try await scheduler.create(request, callerID: operationID)
        await armTimer()
        return try data(scheduleObject(receipt))
    }

    func scheduleObject(_ schedule: AgentTaskSchedule) throws -> [String: Any] {
        var row = try object(schedule)
        var request = row["request"] as? [String: Any] ?? [:]
        request.removeValue(forKey: "prompt")
        // New-task scheduling intent contains a second copy of the private prompt.
        if var target = request["target"] as? [String: Any], var wrapper = target["newTask"] as? [String: Any],
           var task = wrapper["_0"] as? [String: Any] {
            task.removeValue(forKey: "prompt"); wrapper["_0"] = task; target["newTask"] = wrapper; request["target"] = target
        }
        row["request"] = request
        row["dispatch_lifetime"] = "while_cmux_is_open"
        return row
    }

    /// Persistent schedule grants refer to exact app-owned records, never ephemeral bearer tokens.
    func authorizeSchedule(_ schedule: AgentTaskSchedule) async throws {
        guard enabled, !runtime.coordinator.isRetiredOrRetiring(schedule.request.ownerTaskID),
              let owner = try await runtime.coordinator.record(schedule.request.ownerTaskID), owner.retirement == nil,
              runtime.workspaceID(for: owner) != nil, owner.sessionID != nil else { throw CocoaError(.fileReadNoPermission) }
        switch schedule.request.target {
        case .existingTask(let id):
            guard try await isDescendantOrSelf(id, of: owner.id),
                  !runtime.coordinator.isRetiredOrRetiring(id),
                  let target = try await runtime.coordinator.record(id), target.retirement == nil, target.sessionID != nil,
                  runtime.workspaceID(for: target) != nil else { throw CocoaError(.fileReadNoPermission) }
        case .newTask(let request):
            guard request.parentTaskID == owner.id, request.workspaceStableID != nil,
                  request.permissionMode != .unrestricted,
                  let stable = request.workspaceStableID,
                  AppDelegate.shared?.mainWindowContexts.values.lazy.flatMap({ $0.tabManager.tabs })
                    .contains(where: { $0.stableId == stable && !$0.isRemoteWorkspace }) == true else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
    }

    /// Readiness is checked when due, so a working parent can schedule its own future turn.
    func preflightSchedule(_ schedule: AgentTaskSchedule) async throws {
        if case .newTask(let request) = schedule.request.target {
            guard let ownerID = request.parentTaskID else { throw CocoaError(.fileReadNoPermission) }
            let generation = "task:" + ownerID.uuidString + ":" + authority.epoch.uuidString
            let owner = try await issueScope(ownerID: ownerID, generation: generation)
            guard try await authority.remainingChildCapacity(owner: owner.scope) > 0 else { throw AgentTaskScopeError.childLimitExceeded }
        }
        if case .existingTask(let id) = schedule.request.target {
            guard let target = try await runtime.coordinator.record(id), target.phase.isFinished else { throw CocoaError(.userCancelled) }
            try requireExclusiveWorker(id)
            if target.provider == .codex, let session = target.sessionID {
                await runtime.backend.observeSession(session)
                if await runtime.backend.sessionActivitySnapshot(session)?.phase == .working { throw CocoaError(.userCancelled) }
            }
        }
    }

    func dispatchSchedule(_ target: AgentTaskScheduleTarget, prompt: String, operationID: UUID) async throws -> AgentTaskScheduleAcceptance {
        let taskID: UUID
        switch target {
        case .existingTask(let id):
            taskID = id
            _ = try await runtime.coordinator.send(id, prompt: prompt, operationID: operationID)
        case .newTask(var request):
            guard let stable = request.workspaceStableID,
                  let workspace = AppDelegate.shared?.mainWindowContexts.values.lazy.flatMap({ $0.tabManager.tabs })
                    .first(where: { $0.stableId == stable && !$0.isRemoteWorkspace }) else { throw CocoaError(.fileNoSuchFile) }
            request.workspaceID = workspace.id
            request.presentation = .background
            taskID = operationID
            guard let ownerID = request.parentTaskID else { throw CocoaError(.fileReadNoPermission) }
            let generation = "task:" + ownerID.uuidString + ":" + authority.epoch.uuidString
            let owner = try await issueScope(ownerID: ownerID, generation: generation)
            _ = try await authority.allowChild(owner: owner.scope, newChildID: operationID)
            _ = try await runtime.coordinator.start(request, id: operationID)
        }
        // Admission alone is insufficient. Wait only for provider activity or a confirmed terminal receipt.
        for _ in 0..<3 {
            guard let turn = try await runtime.coordinator.turn(operationID) else { throw CocoaError(.fileReadUnknown) }
            if turn.phase == .running || turn.phase == .needsInput || turn.phase == .completed {
                guard let session = turn.sessionID else { throw CocoaError(.fileReadUnknown) }
                let native = await runtime.backend.providerTurn(id: taskID)
                let reference = native.flatMap { $0.operationID == operationID ? $0.providerTurnID : nil }
                    ?? "session-ack:" + session + ":" + operationID.uuidString
                return AgentTaskScheduleAcceptance(taskID: taskID, operationID: operationID,
                    providerReference: reference)
            }
            if turn.phase == .disconnected || turn.phase.isFinished { throw CocoaError(.fileReadUnknown) }
            _ = try await runtime.coordinator.waitTurn(operationID)
        }
        throw CocoaError(.fileReadUnknown)
    }

    func isDescendantOrSelf(_ id: UUID, of owner: UUID) async throws -> Bool {
        if id == owner { return true }
        var cursor: UUID? = id
        for _ in 0..<4 {
            guard let next = cursor, let record = try await runtime.coordinator.record(next) else { return false }
            if record.parentTaskID == owner { return true }
            cursor = record.parentTaskID
        }
        return false
    }

    func date(_ string: String?) -> Date? {
        guard let string, string.contains("T"), string.hasSuffix("Z") || string.dropFirst(10).contains("+") || string.dropFirst(10).contains("-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
