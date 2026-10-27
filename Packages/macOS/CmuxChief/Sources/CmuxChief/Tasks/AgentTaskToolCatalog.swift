import Foundation

/// The native Codex namespace exposed only when an app-owned tool router is enabled.
struct AgentTaskToolCatalog {
    func tools() -> ChiefJSON {
        let schema: ChiefJSON = ["type": "object", "required": ["action"], "additionalProperties": false,
            "properties": ["action": ["type": "string", "enum": ["start", "send", "read", "turns", "result", "wait", "cancel", "interactions", "respond", "inbox", "ack", "schedule.create", "schedule.list", "schedule.read", "schedule.pause", "schedule.resume", "schedule.cancel"]],
                           "body": ["type": "object", "description": "Action parameters: task_id, operation_id, prompt, provider, model, effort, cwd; schedules add due_at (ISO8601), target_task_id or provider, time_zone, misfire and finite max_runs. Use a stable UUID request_id to reconcile the same mutation across calls."]]]
        return [["type": "namespace", "name": "cmux_tasks", "description": "Manage cmux background conversations and their results.",
                 "tools": [["type": "function", "name": "task", "description": "Start or message a worker; inspect, wait or cancel a turn; read the passive inbox; manage finite schedules. No automatic approval or prompt replay.",
                            "inputSchema": schema]]]]
    }
}
