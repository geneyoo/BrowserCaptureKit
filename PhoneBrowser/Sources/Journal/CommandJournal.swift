import Foundation
import SQLite3

struct JournalRecord: Equatable {
    let commandID: String
    let sessionID: String
    let digest: String
    var state: CommandState
    let acceptedAt: Date
    var dispatchingAt: Date?
    var completedAt: Date?
    var retryClassification: RetryClassification?
    var resultJSON: Data?
}

enum JournalAcceptOutcome: Equatable {
    case accepted
    case duplicate(JournalRecord)
    case reusedWithDifferentPayload(JournalRecord)
}

struct JournalRecovery: Equatable {
    /// Rows found `dispatching` at launch: the previous process may have
    /// dispatched a side effect. Marked uncertain, never re-run.
    let uncertainCommandIDs: [String]
    /// Rows found `accepted` at launch: never dispatched, expired conservatively.
    let expiredCommandIDs: [String]
}

enum CommandJournalError: Error, Equatable {
    case open(String)
    case statement(String)
    case unknownCommand(String)
}

/// Transactional command ledger on the phone. The device is the authority on
/// whether dispatch began, so the `dispatching` marker is written and fsynced
/// before any side-effecting browser call and the result is written before it
/// is acknowledged as terminal.
actor CommandJournal {
    static let inMemoryPath = ":memory:"

    private let db: OpaquePointer
    private let encoder = JSONEncoder()

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw CommandJournalError.open(message)
        }
        db = handle
        encoder.dateEncodingStrategy = .iso8601
        try Self.execute(
            db,
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            CREATE TABLE IF NOT EXISTS commands (
              command_id TEXT PRIMARY KEY NOT NULL,
              session_id TEXT NOT NULL,
              digest TEXT NOT NULL,
              state TEXT NOT NULL,
              accepted_at REAL NOT NULL,
              dispatching_at REAL,
              completed_at REAL,
              retry_classification TEXT,
              result_json BLOB
            );
            """
        )
    }

    deinit {
        sqlite3_close(db)
    }

    /// Resolves rows left non-terminal by a previous process instance.
    func recoverAfterLaunch(now: Date = Date()) throws -> JournalRecovery {
        let uncertain = try commandIDs(inState: .dispatching)
        for commandID in uncertain {
            let result = CommandResultMessage(
                commandID: commandID,
                state: .uncertain,
                startedAt: nil,
                completedAt: now,
                retryClassification: .unsafe,
                reason: nil,
                message: "The app process ended after dispatch began; the website outcome is unknown. Re-observe before retrying.",
                payload: nil
            )
            try complete(
                commandID: commandID,
                state: .uncertain,
                retryClassification: .unsafe,
                resultJSON: try encoder.encode(result),
                now: now
            )
        }
        let expired = try commandIDs(inState: .accepted)
        for commandID in expired {
            let result = CommandResultMessage(
                commandID: commandID,
                state: .rejected,
                startedAt: nil,
                completedAt: now,
                retryClassification: .notStarted,
                reason: .expired,
                message: "The app process ended before this command was dispatched.",
                payload: nil
            )
            try complete(
                commandID: commandID,
                state: .rejected,
                retryClassification: .notStarted,
                resultJSON: try encoder.encode(result),
                now: now
            )
        }
        return JournalRecovery(uncertainCommandIDs: uncertain, expiredCommandIDs: expired)
    }

    func accept(commandID: String, sessionID: String, digest: String, now: Date = Date()) throws -> JournalAcceptOutcome {
        try Self.execute(db, "BEGIN IMMEDIATE;")
        do {
            if let existing = try record(commandID: commandID) {
                try Self.execute(db, "COMMIT;")
                return existing.digest == digest ? .duplicate(existing) : .reusedWithDifferentPayload(existing)
            }
            let statement = try prepare(
                "INSERT INTO commands (command_id, session_id, digest, state, accepted_at) VALUES (?, ?, ?, ?, ?);"
            )
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, commandID)
            bind(statement, 2, sessionID)
            bind(statement, 3, digest)
            bind(statement, 4, CommandState.accepted.rawValue)
            sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
            try step(statement)
            try Self.execute(db, "COMMIT;")
            return .accepted
        } catch {
            try? Self.execute(db, "ROLLBACK;")
            throw error
        }
    }

    /// Atomic `accepted -> dispatching`. Returns `false` when the row is no
    /// longer `accepted` (cancelled or already claimed), so a cancel racing a
    /// dispatch can never both win.
    func claimDispatch(commandID: String, now: Date = Date()) throws -> Bool {
        let statement = try prepare(
            "UPDATE commands SET state = ?, dispatching_at = ? WHERE command_id = ? AND state = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, CommandState.dispatching.rawValue)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        bind(statement, 3, commandID)
        bind(statement, 4, CommandState.accepted.rawValue)
        try step(statement)
        return sqlite3_changes(db) == 1
    }

    /// Atomic `accepted -> cancelled`. Returns `false` when dispatch already began.
    func cancelIfUndispatched(commandID: String, resultJSON: Data, now: Date = Date()) throws -> Bool {
        let statement = try prepare(
            """
            UPDATE commands SET state = ?, completed_at = ?, retry_classification = ?, result_json = ?
            WHERE command_id = ? AND state = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, CommandState.cancelled.rawValue)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        bind(statement, 3, RetryClassification.notStarted.rawValue)
        bind(statement, 4, resultJSON)
        bind(statement, 5, commandID)
        bind(statement, 6, CommandState.accepted.rawValue)
        try step(statement)
        return sqlite3_changes(db) == 1
    }

    func complete(
        commandID: String,
        state: CommandState,
        retryClassification: RetryClassification,
        resultJSON: Data,
        now: Date = Date()
    ) throws {
        precondition(state.isTerminal, "complete() requires a terminal state")
        let statement = try prepare(
            """
            UPDATE commands SET state = ?, completed_at = ?, retry_classification = ?, result_json = ?
            WHERE command_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, state.rawValue)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        bind(statement, 3, retryClassification.rawValue)
        bind(statement, 4, resultJSON)
        bind(statement, 5, commandID)
        try step(statement)
        guard sqlite3_changes(db) == 1 else {
            throw CommandJournalError.unknownCommand(commandID)
        }
    }

    func record(commandID: String) throws -> JournalRecord? {
        let statement = try prepare(
            """
            SELECT command_id, session_id, digest, state, accepted_at, dispatching_at, completed_at,
                   retry_classification, result_json
            FROM commands WHERE command_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, commandID)
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            if code == SQLITE_DONE {
                return nil
            }
            throw CommandJournalError.statement(String(cString: sqlite3_errmsg(db)))
        }
        return JournalRecord(
            commandID: String(cString: sqlite3_column_text(statement, 0)),
            sessionID: String(cString: sqlite3_column_text(statement, 1)),
            digest: String(cString: sqlite3_column_text(statement, 2)),
            state: CommandState(rawValue: String(cString: sqlite3_column_text(statement, 3))) ?? .uncertain,
            acceptedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            dispatchingAt: sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            completedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            retryClassification: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : RetryClassification(rawValue: String(cString: sqlite3_column_text(statement, 7))),
            resultJSON: blob(statement, 8)
        )
    }

    // MARK: - SQLite helpers

    private func commandIDs(inState state: CommandState) throws -> [String] {
        let statement = try prepare("SELECT command_id FROM commands WHERE state = ? ORDER BY accepted_at;")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, state.rawValue)
        var ids: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(statement, 0)))
            } else if code == SQLITE_DONE {
                return ids
            } else {
                throw CommandJournalError.statement(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw CommandJournalError.statement(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CommandJournalError.statement(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CommandJournalError.statement(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
        }
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let pointer = sqlite3_column_blob(statement, index)
        else {
            return nil
        }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
