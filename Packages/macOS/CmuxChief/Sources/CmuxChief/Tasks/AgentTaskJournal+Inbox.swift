import Foundation

extension AgentTaskJournal {
    /// Appends a passive child event, idempotent on owner, task, exact turn and phase.
    ///
    /// No provider is contacted. Duplicate appends preserve the original sequence and acknowledgement.
    /// Task-cache pruning cannot remove these records; capacity exhaustion fails instead of dropping unread results.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Managed parent authorized by the composition root.
    ///   - taskID: Exact managed child ID validated by the caller.
    ///   - operationID: Exact child turn ID validated against its persisted receipt.
    ///   - phase: Event kind included in the uniqueness key.
    ///   - result: Optional bounded private text or reference.
    /// - Returns: The original or newly committed event.
    /// - Throws: Conflicting duplicate payload, capacity, validation or storage errors.
    public func appendInbox(ownerTaskID: UUID, taskID: UUID, operationID: UUID,
                            phase: AgentTaskRecord.Phase, result: AgentTaskInboxResult? = nil) throws -> AgentTaskInboxEvent {
        try result?.validate()
        return try db().transaction {
            let key = [ownerTaskID.uuidString, taskID.uuidString, operationID.uuidString, phase.rawValue]
            if let row = try db().rows("SELECT sequence, payload FROM task_inbox WHERE owner = ? AND task = ? AND operation = ? AND kind = ?", key).first {
                let event = try inboxEvent(row)
                guard event.result == result else { throw AgentTaskJournalError.conflict }
                return event
            }
            if let row = try db().rows("SELECT payload FROM task_inbox_acks WHERE owner = ? AND task = ? AND operation = ? AND kind = ?", key).first {
                let tombstone = try decode(AgentTaskInboxTombstone.self, row[0])
                guard try tombstone.matches(result) else { throw AgentTaskJournalError.conflict }
                return tombstone.replay(result)
            }
            var count = try db().rows("SELECT COUNT(*) FROM task_inbox").first?.first.flatMap(Int.init) ?? 0
            if count >= inboxCapacity {
                // Global pressure may evict even a recent acknowledged payload, never an unread one.
                let oldest = try db().rows("SELECT sequence, payload FROM task_inbox WHERE json_extract(payload, '$.acknowledgedAt') IS NOT NULL ORDER BY sequence LIMIT ?",
                                           [String(count - inboxCapacity + 1)])
                try compactAcknowledged(oldest)
                count = try db().rows("SELECT COUNT(*) FROM task_inbox").first?.first.flatMap(Int.init) ?? 0
            }
            guard count < inboxCapacity else { throw AgentTaskJournalError.capacity }
            let event = AgentTaskInboxEvent(ownerTaskID: ownerTaskID, taskID: taskID, operationID: operationID,
                                           phase: phase, result: result, now: now())
            try db().execute("INSERT INTO task_inbox(id, owner, task, operation, kind, payload) VALUES (?, ?, ?, ?, ?, ?)",
                             [event.id.uuidString] + key + [try encode(event)])
            guard let row = try db().rows("SELECT sequence, payload FROM task_inbox WHERE id = ?", [event.id.uuidString]).first else {
                throw AgentTaskJournalError.notFound
            }
            return try inboxEvent(row)
        }
    }

    /// Replays an owner's passive inbox in ascending sequence order without model submission.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Owner already authorized by the app's scope layer.
    ///   - afterSequence: Exclusive durable cursor, default zero.
    ///   - limit: Bounded page size between 1 and 1,000, default 100.
    /// - Returns: Recent acknowledged payloads and every unread event; old acknowledgements may be compacted. Advance a cursor only after consuming a returned page.
    /// - Throws: Invalid cursor or limit, storage or decoding errors.
    public func inbox(ownerTaskID: UUID, afterSequence: Int64 = 0, limit: Int = 100) throws -> [AgentTaskInboxEvent] {
        guard afterSequence >= 0, (1...1_000).contains(limit) else { throw AgentTaskJournalError.invalidRequest }
        return try db().rows("SELECT sequence, payload FROM task_inbox WHERE owner = ? AND sequence > ? ORDER BY sequence LIMIT ?",
                             [ownerTaskID.uuidString, String(afterSequence), String(limit)]).map { try inboxEvent($0) }
    }

    /// Counts every unread event for an authorized owner without loading result bodies or paging history.
    /// - Parameter ownerTaskID: Owner already authorized by the app's scope layer.
    /// - Returns: Number of unacknowledged events across the retained inbox.
    /// - Throws: Storage errors.
    public func unreadInboxCount(ownerTaskID: UUID) throws -> Int {
        try db().rows("SELECT COUNT(*) FROM task_inbox WHERE owner = ? AND json_extract(payload, '$.acknowledgedAt') IS NULL",
                      [ownerTaskID.uuidString]).first?.first.flatMap(Int.init) ?? 0
    }

    /// Acknowledges one owner's event without starting, resuming or notifying a model.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Authorized owner; another owner's event is reported as missing.
    ///   - eventID: Stable event ID from a replay page.
    /// - Returns: The acknowledged event; duplicate acknowledgements preserve the first timestamp.
    /// - Throws: Ownership, missing record, storage or decoding errors.
    public func acknowledge(ownerTaskID: UUID, eventID: UUID) throws -> AgentTaskInboxEvent {
        try db().transaction {
            guard let row = try db().rows("SELECT sequence, payload FROM task_inbox WHERE owner = ? AND id = ?",
                                         [ownerTaskID.uuidString, eventID.uuidString]).first else {
                guard let saved = try db().rows("SELECT payload FROM task_inbox_acks WHERE owner = ? AND id = ?",
                                               [ownerTaskID.uuidString, eventID.uuidString]).first else { throw AgentTaskJournalError.notFound }
                return try decode(AgentTaskInboxTombstone.self, saved[0]).event
            }
            var event = try inboxEvent(row)
            guard event.acknowledgedAt == nil else { return event }
            event.acknowledgedAt = now()
            try db().execute("UPDATE task_inbox SET payload = ? WHERE owner = ? AND id = ?",
                             [try encode(event), ownerTaskID.uuidString, eventID.uuidString])
            let old = try db().rows("SELECT sequence, payload FROM task_inbox WHERE owner = ? AND json_extract(payload, '$.acknowledgedAt') IS NOT NULL ORDER BY sequence DESC LIMIT -1 OFFSET ?",
                                   [ownerTaskID.uuidString, String(acknowledgedInboxPerOwner)])
            try compactAcknowledged(old)
            return event
        }
    }

    /// Runs inside the caller's existing transaction, preserving exact acknowledgement identity.
    private func compactAcknowledged(_ rows: [[String]]) throws {
        for row in rows {
            let event = try inboxEvent(row)
            guard event.acknowledgedAt != nil else { throw AgentTaskJournalError.invalidTransition }
            let tombstone = try AgentTaskInboxTombstone(event)
            try db().execute("INSERT INTO task_inbox_acks(id, owner, task, operation, kind, payload) VALUES (?, ?, ?, ?, ?, ?)",
                             [event.id.uuidString, event.ownerTaskID.uuidString, event.taskID.uuidString,
                              event.operationID.uuidString, event.phase.rawValue, try encode(tombstone)])
            try db().execute("DELETE FROM task_inbox WHERE id = ?", [event.id.uuidString])
        }
    }

    private func inboxEvent(_ row: [String]) throws -> AgentTaskInboxEvent {
        var event = try decode(AgentTaskInboxEvent.self, row[1])
        guard let sequence = Int64(row[0]) else { throw AgentTaskJournalError.invalidRequest }
        event.sequence = sequence
        return event
    }
}
