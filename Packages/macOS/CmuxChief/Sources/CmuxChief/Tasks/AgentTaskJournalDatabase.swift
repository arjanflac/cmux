import Darwin
import Foundation
import SQLite3

/// Non-Sendable connection owned exclusively by AgentTaskJournal; teardown never accesses actor state.
final class AgentTaskJournalDatabase {
    private var handle: OpaquePointer?

    init(url: URL, maximumPages: Int) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), maximumPages >= 16 else {
            throw AgentTaskJournalError.invalidRequest
        }
        let parent = url.deletingLastPathComponent()
        let files = FileManager()
        try files.createDirectory(at: parent, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(parent.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), chmod(parent.path, 0o700) == 0 else {
            throw AgentTaskJournalError.insecurePath
        }
        // O_NOFOLLOW also protects an existing database from a symlink substitution at open.
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentTaskJournalError.insecurePath }
        defer { Darwin.close(descriptor) }
        var file = stat()
        guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid(), file.st_nlink == 1, fchmod(descriptor, 0o600) == 0 else {
            throw AgentTaskJournalError.insecurePath
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw AgentTaskJournalError.storage(result)
        }
        handle = opened
        do {
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA foreign_keys = ON")
            let mode = try rows("PRAGMA journal_mode = WAL")
            guard mode.first?.first == "wal" else { throw AgentTaskJournalError.storage(SQLITE_ERROR) }
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA max_page_count = \(maximumPages)")
            try execute("""
                CREATE TABLE IF NOT EXISTS task_schedules (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL, caller TEXT NOT NULL,
                    payload_hash TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(owner, caller))
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS task_occurrences (
                    id TEXT PRIMARY KEY, schedule TEXT NOT NULL REFERENCES task_schedules(id),
                    ordinal INTEGER NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(schedule, ordinal))
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS task_inbox (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                    owner TEXT NOT NULL, task TEXT NOT NULL, operation TEXT NOT NULL,
                    kind TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(owner, task, operation, kind))
                """)
            try execute("CREATE INDEX IF NOT EXISTS task_occurrences_state ON task_occurrences(state)")
            try execute("CREATE INDEX IF NOT EXISTS task_inbox_owner_sequence ON task_inbox(owner, sequence)")
        } catch {
            sqlite3_close_v2(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String, _ parameters: [String] = []) throws {
        _ = try rows(sql, parameters)
    }

    func rows(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        guard let handle else { throw AgentTaskJournalError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw AgentTaskJournalError.storage(prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, text) in parameters.enumerated() {
            let result = text.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, -1,
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw AgentTaskJournalError.storage(result) }
        }
        var output: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw AgentTaskJournalError.storage(result) }
            output.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
