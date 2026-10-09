import Foundation
import SQLite3

/// An SQLite result code that is not success, with the library's message.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    /// The file is not a database, or its pages are damaged (`SQLITE_NOTADB`, `SQLITE_CORRUPT`).
    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT
    }

    var isReadOnly: Bool { code & 0xFF == SQLITE_READONLY }

    var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal wrapper around the system `libsqlite3`, used only by ``SnapshotStore``.
/// Not thread safe: the store owns one connection and is an actor.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?

    /// Opens (and with `create`, creates) the database at `path`. Uses the full-mutex
    /// threading mode, disables URI names and memory-mapped I/O, and waits up to 2 s on a lock.
    init(path: String, readOnly: Bool = false, create: Bool = true) throws {
        var flags = SQLITE_OPEN_FULLMUTEX
        if readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE
            if create { flags |= SQLITE_OPEN_CREATE }
        }
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(db)
            throw SQLiteError(code: code, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var isReadOnly: Bool { handle.map { sqlite3_db_readonly($0, "main") == 1 } ?? true }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw SQLiteError(code: code, message: lastMessage) }
        return Statement(statement, connection: self)
    }

    /// Single integer from a query such as `PRAGMA user_version`.
    func integer(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.int64(0)
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`; any thrown error rolls everything back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection" }
    var lastCode: Int32 { handle.map { sqlite3_extended_errcode($0) } ?? SQLITE_MISUSE }

    final class Statement {
        private var statement: OpaquePointer?
        private unowned let connection: SQLiteConnection

        fileprivate init(_ statement: OpaquePointer, connection: SQLiteConnection) {
            self.statement = statement
            self.connection = connection
        }

        deinit { sqlite3_finalize(statement) }

        /// `true` when a row is available, `false` when done.
        @discardableResult
        func step() throws -> Bool {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError(code: connection.lastCode, message: connection.lastMessage)
            }
        }

        func bind(_ index: Int32, _ value: Int64) throws {
            try check(sqlite3_bind_int64(statement, index, value))
        }

        func bind(_ index: Int32, _ value: Double) throws {
            try check(sqlite3_bind_double(statement, index, value))
        }

        func bind(_ index: Int32, _ value: String) throws {
            try check(sqlite3_bind_text(statement, index, value, -1, Self.transient))
        }

        func bind(_ index: Int32, _ value: Data) throws {
            let code = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob64(statement, index, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1),
                                    sqlite3_uint64(buffer.count), Self.transient)
            }
            try check(code)
        }

        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data? {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_blob(statement, column) else { return count == 0 ? Data() : nil }
            return Data(bytes: bytes, count: count)
        }

        private func check(_ code: Int32) throws {
            guard code == SQLITE_OK else { throw SQLiteError(code: code, message: connection.lastMessage) }
        }

        /// `SQLITE_TRANSIENT`: SQLite copies the bound bytes before the call returns.
        private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    }
}
