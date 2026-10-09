import Foundation

/// Database schema version, the SQL that creates it from nothing, and the SQL that upgrades
/// an older file one version at a time (`migrations[n]` turns version `n` into `n + 1`).
public struct SnapshotSchema: Sendable {
    public let version: Int
    public let create: [String]
    public let migrations: [Int: [String]]
    /// Tables and columns the store reads and writes. Checked at every open, after any
    /// upgrade: a file without them is set aside instead of failing every save.
    public let requiredColumns: [String: Set<String>]

    public init(version: Int, create: [String], migrations: [Int: [String]],
                requiredColumns: [String: Set<String>] = SnapshotSchema.snapshotColumns) {
        self.version = version
        self.create = create
        self.migrations = migrations
        self.requiredColumns = requiredColumns
    }

    public static let snapshotColumns: [String: Set<String>] = ["snapshots": [
        "id", "root_key", "root_identity", "scope", "finished_at", "saved_at", "allocated_bytes", "logical_bytes",
        "item_count", "failure_count", "format_version", "details", "tree", "row_sha256",
    ]]

    /// `true` when every step from `start` up to ``version`` exists.
    func canMigrate(from start: Int) -> Bool {
        start >= 1 && (start..<version).allSatisfy { migrations[$0] != nil }
    }

    public static let current = SnapshotSchema(version: 1, create: [
        """
        CREATE TABLE snapshots (
            id INTEGER PRIMARY KEY,
            root_key TEXT NOT NULL UNIQUE,
            root_identity TEXT NOT NULL,
            scope TEXT NOT NULL,
            finished_at REAL NOT NULL,
            saved_at REAL NOT NULL,
            allocated_bytes INTEGER NOT NULL,
            logical_bytes INTEGER NOT NULL,
            item_count INTEGER NOT NULL,
            failure_count INTEGER NOT NULL,
            format_version INTEGER NOT NULL,
            details TEXT NOT NULL,
            tree BLOB NOT NULL,
            row_sha256 BLOB NOT NULL
        )
        """,
        "CREATE INDEX snapshots_saved_at ON snapshots(saved_at DESC)",
    ], migrations: [:])
}

/// Something the user should know about the saved scans, reported once.
public enum StoreNotice: Sendable, Equatable {
    /// The database could not be read. It was moved aside, kept on disk, and every snapshot
    /// that still passed its checksum was copied into a new database.
    case recovered(keptAt: String, salvaged: Int, unreadable: Int, reason: String)
    /// The file is not one this version can upgrade. It was moved aside, unchanged, and a new
    /// database was started.
    case setAside(keptAt: String, reason: String)
    /// Written by a newer Disk Analyzer. Left untouched; saving is off for this session.
    case newerVersion(Int)
    /// The database could not be opened or created; saving is off for this session.
    case unavailable(String)

    public var message: String {
        switch self {
        case let .recovered(path, salvaged, unreadable, reason):
            "The saved scans could not be read (\(reason)). \(salvaged) saved \(salvaged == 1 ? "scan was" : "scans were") recovered"
                + (unreadable > 0 ? " and \(unreadable) could not be." : ".")
                + " The original file was kept at \(path)."
        case let .setAside(path, reason):
            "The saved scans file was set aside (\(reason)) and a new one was started. The original file was kept at \(path)."
        case .newerVersion(let version):
            "The saved scans were written by a newer version of Disk Analyzer (format \(version)). They were left untouched, and scans are not saved in this session."
        case .unavailable(let reason):
            "Saved scans are not available in this session: \(reason)"
        }
    }
}

public enum SnapshotStoreError: Error, LocalizedError, Equatable {
    case disabled(String)
    case notFound
    case incompatible(Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .disabled(let reason): "Saving scans is off: \(reason)"
        case .notFound: "The saved scan no longer exists."
        case .incompatible(let version): "The saved scan uses tree format \(version), which this version cannot read."
        case .unreadable(let reason): "The saved scan could not be read: \(reason)."
        }
    }
}

/// Saves the last scan of each root in an SQLite database and reads them back.
///
/// - One snapshot per root identity (volume UUID + folder file ID); saving the same root again
///   replaces it in one transaction, so a failed or interrupted write keeps the previous one.
/// - At most ``maxSnapshots`` roots are kept; the least recently saved one is dropped when
///   another root is saved.
/// - The file is opened on first use, off the main thread. A damaged file is moved aside
///   (never deleted) and the readable snapshots are copied out of it; a file from a newer
///   version is left untouched and saving is turned off. See ``StoreNotice``.
public actor SnapshotStore {
    /// `PRAGMA application_id` of a Disk Analyzer database ("DASS").
    public static let applicationID: Int64 = 0x4441_5353
    public static let defaultMaxSnapshots = 10

    public nonisolated let url: URL
    let schema: SnapshotSchema
    let maxSnapshots: Int
    private var connection: SQLiteConnection?
    private var didOpen = false
    private var disabledReason: String?
    private var notices: [StoreNotice] = []

    public init(url: URL, schema: SnapshotSchema = .current, maxSnapshots: Int = SnapshotStore.defaultMaxSnapshots) {
        self.url = url
        self.schema = schema
        self.maxSnapshots = max(1, maxSnapshots)
    }

    /// `~/Library/Application Support/Disk Analyzer/Snapshots.sqlite`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "Disk Analyzer/Snapshots.sqlite", directoryHint: .notDirectory)
    }

    /// Opens the database if needed and returns the notices collected so far, once.
    public func takeNotices() -> [StoreNotice] {
        ensureOpen()
        defer { notices = [] }
        return notices
    }

    public var isWritable: Bool {
        ensureOpen()
        return connection != nil && disabledReason == nil
    }

    // MARK: - Writing

    public func save(_ snapshot: ScanSnapshot) throws {
        let db = try writableConnection()
        let row = try SavedRow(snapshot, savedAt: Date())
        try db.transaction {
            let insert = try db.prepare("""
                INSERT INTO snapshots (\(SavedRow.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(root_key) DO UPDATE SET
                    root_identity = excluded.root_identity, scope = excluded.scope, finished_at = excluded.finished_at,
                    saved_at = excluded.saved_at, allocated_bytes = excluded.allocated_bytes, logical_bytes = excluded.logical_bytes,
                    item_count = excluded.item_count, failure_count = excluded.failure_count, format_version = excluded.format_version,
                    details = excluded.details, tree = excluded.tree, row_sha256 = excluded.row_sha256
                """)
            try row.bind(to: insert)
            try insert.step()
            let prune = try db.prepare("DELETE FROM snapshots WHERE id NOT IN (SELECT id FROM snapshots ORDER BY saved_at DESC, id DESC LIMIT ?)")
            try prune.bind(1, Int64(maxSnapshots))
            try prune.step()
        }
    }

    // MARK: - Reading

    /// Saved snapshots, most recently saved first. Rows that cannot be read are skipped.
    public func summaries() -> [SnapshotSummary] {
        ensureOpen()
        guard let db = connection else { return [] }
        var result: [SnapshotSummary] = []
        do {
            let query = try db.prepare("""
                SELECT id, root_identity, scope, finished_at, saved_at, allocated_bytes, logical_bytes, item_count,
                       failure_count, format_version FROM snapshots ORDER BY saved_at DESC, id DESC
                """)
            while try query.step() {
                // The list is read without the row checksum, so every figure it shows is range-checked.
                let finished = query.double(3), saved = query.double(4), failures = query.int64(8), format = query.int64(9)
                guard let json = query.string(1), let root = try? Self.decoder.decode(RootIdentity.self, from: Data(json.utf8)),
                      let scope = query.string(2).flatMap(CoverageScope.init(rawValue:)),
                      SavedRange.isDate(finished), SavedRange.isDate(saved),
                      [query.int64(5), query.int64(6), query.int64(7)].allSatisfy(SavedRange.isBytes),
                      SavedRange.isCount(failures), SavedRange.isCount(format) else { continue }
                result.append(SnapshotSummary(
                    id: query.int64(0), root: root, scope: scope,
                    finishedAt: Date(timeIntervalSince1970: finished), savedAt: Date(timeIntervalSince1970: saved),
                    allocatedBytes: query.int64(5), logicalBytes: query.int64(6), itemCount: query.int64(7),
                    failureCount: Int(failures), formatVersion: Int(format)
                ))
            }
        } catch {
            // A page went bad after the open check: keep what was read; the next launch recovers the file.
        }
        return result
    }

    public func recentScans(probe: RootProbe = .system) -> [RecentScan] {
        summaries().map { RecentScan(summary: $0, availability: $0.root.availability(probe: probe)) }
    }

    /// Decodes one snapshot after checking its format version and checksum.
    public func load(id: Int64) throws -> ScanSnapshot {
        ensureOpen()
        guard let db = connection else { throw SnapshotStoreError.disabled(disabledReason ?? "not open") }
        do {
            let query = try db.prepare("SELECT \(SavedRow.columns) FROM snapshots WHERE id = ?")
            try query.bind(1, id)
            guard try query.step() else { throw SnapshotStoreError.notFound }
            let version = Int(clamping: query.int64(9))
            guard TreeCodec.isSupported(version) else { throw SnapshotStoreError.incompatible(version) }
            guard let row = SavedRow(query) else { throw SnapshotStoreError.unreadable("missing fields") }
            return try row.snapshot()
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.unreadable(String(describing: error))
        }
    }

    /// The most recently saved snapshot that is compatible, decodes, and whose root is the
    /// same folder on the same volume now. Unreadable or unavailable ones are skipped, not removed.
    public func restorableSnapshot(probe: RootProbe = .system) -> ScanSnapshot? {
        for summary in summaries() where summary.isCompatible && summary.root.availability(probe: probe).isRestorable {
            if let snapshot = try? load(id: summary.id) { return snapshot }
        }
        return nil
    }

    // MARK: - Opening, migration, recovery

    private func writableConnection() throws -> SQLiteConnection {
        ensureOpen()
        if let disabledReason { throw SnapshotStoreError.disabled(disabledReason) }
        guard let connection else { throw SnapshotStoreError.disabled("not open") }
        return connection
    }

    private func ensureOpen() {
        guard !didOpen else { return }
        didOpen = true
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try open()
        } catch {
            connection?.close()
            connection = nil
            disabledReason = String(describing: error)
            notices.append(.unavailable(String(describing: error)))
        }
    }

    private enum OpenProblem: Error {
        case corrupt(String)
    }

    private func open() throws {
        let path = url.path(percentEncoded: false)
        let db = try SQLiteConnection(path: path)
        do {
            let appID = try db.integer("PRAGMA application_id")
            let version = Int(try db.integer("PRAGMA user_version"))
            let objects = try db.integer("SELECT count(*) FROM sqlite_master")
            if appID == 0, version == 0, objects == 0 {
                // A new or zero-byte file holds no snapshots: create the schema in it.
                try create(db)
                return adopt(db, path: path, restrictPermissions: true)
            }
            guard appID == Self.applicationID else {
                db.close()
                return try startOver(setAsideReason: "it is not a Disk Analyzer database")
            }
            if version > schema.version {
                db.close()
                disabledReason = "written by a newer version (format \(version))"
                notices.append(.newerVersion(version))
                return
            }
            if version < schema.version {
                guard schema.canMigrate(from: version) else {
                    db.close()
                    return try startOver(setAsideReason: "format \(version) cannot be upgraded to \(schema.version)")
                }
                try migrate(db, from: version)
            }
            let check = try db.prepare("PRAGMA quick_check")
            var findings: [String] = []
            while try check.step() { findings.append(check.string(0) ?? "") }
            guard findings == ["ok"] else { throw OpenProblem.corrupt(findings.first ?? "integrity check failed") }
            guard try hasRequiredColumns(db) else {
                db.close()
                return try startOver(setAsideReason: "its tables are missing or different")
            }
            adopt(db, path: path, restrictPermissions: false)
        } catch let error as SQLiteError where error.isCorruption {
            db.close()
            try recover(reason: error.message)
        } catch OpenProblem.corrupt(let reason) {
            db.close()
            try recover(reason: reason)
        }
    }

    /// `true` when every table and column the store uses exists. A file with the right
    /// application ID and version can still lack them (edited, or written by a pre-release build).
    private func hasRequiredColumns(_ db: SQLiteConnection) throws -> Bool {
        for (table, columns) in schema.requiredColumns {
            let info = try db.prepare("SELECT name FROM pragma_table_info(?)")
            try info.bind(1, table)
            var found: Set<String> = []
            while try info.step() { if let name = info.string(0) { found.insert(name) } }
            guard columns.isSubset(of: found) else { return false }
        }
        return true
    }

    /// Files the store creates are readable by the user only (`0600`): they list file names.
    /// An existing file keeps the permissions it has.
    private func adopt(_ db: SQLiteConnection, path: String, restrictPermissions: Bool) {
        if restrictPermissions { chmod(path, 0o600) }
        connection = db
    }

    /// Creates the current schema in an empty database, in one transaction.
    private func create(_ db: SQLiteConnection) throws {
        try db.transaction {
            for statement in schema.create { try db.execute(statement) }
            try stamp(db)
        }
    }

    /// Runs every upgrade step from `start` to the current version in one transaction, so a
    /// failed upgrade leaves the file exactly as it was.
    private func migrate(_ db: SQLiteConnection, from start: Int) throws {
        try db.transaction {
            for version in start..<schema.version {
                guard let steps = schema.migrations[version] else {
                    throw SQLiteError(code: 1, message: "no upgrade from format \(version)")
                }
                for statement in steps { try db.execute(statement) }
            }
            try stamp(db)
        }
    }

    private func stamp(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA application_id = \(Self.applicationID)")
        try db.execute("PRAGMA user_version = \(schema.version)")
    }

    private func startOver(setAsideReason reason: String) throws {
        let kept = try setAside()
        try createFresh()
        notices.append(.setAside(keptAt: kept, reason: reason))
    }

    private func recover(reason: String) throws {
        let kept = try setAside()
        try createFresh()
        let (salvaged, unreadable) = salvage(from: kept)
        notices.append(.recovered(keptAt: kept, salvaged: salvaged, unreadable: unreadable, reason: reason))
    }

    private func createFresh() throws {
        let path = url.path(percentEncoded: false)
        let db = try SQLiteConnection(path: path)
        try create(db)
        adopt(db, path: path, restrictPermissions: true)
    }

    /// Moves the database and its journal files next to it under a dated name. Nothing is deleted.
    private func setAside() throws -> String {
        let manager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let base = url.deletingPathExtension().lastPathComponent
        var target = url.deletingLastPathComponent().appending(path: "\(base).unreadable-\(stamp).sqlite")
        var suffix = 1
        while manager.fileExists(atPath: target.path(percentEncoded: false)) {
            suffix += 1
            target = url.deletingLastPathComponent().appending(path: "\(base).unreadable-\(stamp)-\(suffix).sqlite")
        }
        try manager.moveItem(at: url, to: target)
        for sidecar in ["-journal", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path(percentEncoded: false) + sidecar)
            if manager.fileExists(atPath: from.path(percentEncoded: false)) {
                try? manager.moveItem(at: from, to: URL(fileURLWithPath: target.path(percentEncoded: false) + sidecar))
            }
        }
        return target.path(percentEncoded: false)
    }

    /// Copies every row of the set-aside file that still reads, passes its checksum and decodes.
    /// Rows are read in storage order so a damaged page loses only what is on it and after it.
    ///
    /// Reading happens on a temporary copy whose header page count is cleared: SQLite refuses a
    /// file shorter than that count (a truncated file), and with the field at zero it uses the
    /// real file size instead (SQLite file format, "in-header database size"). The set-aside
    /// file itself is never changed.
    private func salvage(from path: String) -> (salvaged: Int, unreadable: Int) {
        let copy = FileManager.default.temporaryDirectory.appending(path: "DiskAnalyzer-salvage-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)) != nil else { return (0, 0) }
        Self.clearHeaderPageCount(copy)
        guard let db = connection, let source = try? SQLiteConnection(path: copy.path(percentEncoded: false), readOnly: true),
              (try? source.integer("PRAGMA application_id")) == Self.applicationID,
              let rows = try? source.prepare("SELECT \(SavedRow.columns) FROM snapshots") else { return (0, 0) }
        var salvaged = 0, unreadable = 0
        while true {
            do {
                guard try rows.step() else { break }
            } catch {
                unreadable += 1
                break
            }
            guard let row = SavedRow(rows), TreeCodec.isSupported(Int(row.formatVersion)), (try? row.snapshot()) != nil
            else { unreadable += 1; continue }
            do {
                let insert = try db.prepare("INSERT OR IGNORE INTO snapshots (\(SavedRow.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
                try row.bind(to: insert)
                try insert.step()
                salvaged += 1
            } catch {
                unreadable += 1
            }
        }
        return (salvaged, unreadable)
    }

    /// Zeroes bytes 28-31 of an SQLite header (the in-header database size), if the file has one.
    private static func clearHeaderPageCount(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 32), header.count == 32,
              header.prefix(16) == Data("SQLite format 3\u{0}".utf8) else { return }
        try? handle.seek(toOffset: 28)
        try? handle.write(contentsOf: Data(count: 4))
    }

    // MARK: - Encoding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Ranges a saved figure must be in before it is used. A row outside them was damaged or
/// edited; it is skipped, never restored, so it cannot crash the app at launch.
enum SavedRange {
    /// 2^56 bytes (72 PB): far above any Mac volume, and low enough that adding a few such
    /// figures cannot overflow `Int64`.
    static let maxBytes: Int64 = 1 << 56
    /// About 1653 to 2286 (±10^10 s from 1970).
    static func isDate(_ seconds: Double) -> Bool { seconds.isFinite && Swift.abs(seconds) <= 1e10 }
    static func isDate(_ date: Date) -> Bool { isDate(date.timeIntervalSince1970) }
    static func isBytes(_ value: Int64) -> Bool { value >= 0 && value <= maxBytes }
    static func isBytes(_ value: Int64?) -> Bool { value.map(isBytes) ?? true }
    static func isCount(_ value: Int64) -> Bool { value >= 0 && value <= Int64(Int32.max) }
    static func isCount(_ value: Int) -> Bool { isCount(Int64(value)) }
}

extension VolumeBaseline {
    /// Every figure is a plausible size or absent, and the date is plausible.
    var isPlausible: Bool {
        SavedRange.isDate(capturedAt) && SavedRange.isBytes(totalCapacity) && SavedRange.isBytes(availableCapacity)
            && SavedRange.isBytes(availableForImportantUsage)
    }
}

/// One row of the `snapshots` table, in column order, with the SHA-256 that covers all of it.
///
/// The checksum is over every stored field (identity, scope, dates, list figures, details
/// and tree), so damage anywhere in the row, not just in the tree, keeps it from being restored.
/// It detects damage, not a deliberate edit (anyone can recompute it); the range checks in
/// ``SnapshotDetails`` and ``TreeCodec`` are what keep an edited row from crashing the app.
struct SavedRow {
    static let columns = "root_key, root_identity, scope, finished_at, saved_at, allocated_bytes, logical_bytes, "
        + "item_count, failure_count, format_version, details, tree, row_sha256"

    let rootKey: String
    let rootIdentity: String
    let scope: String
    let finishedAt: Double
    let savedAt: Double
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let itemCount: Int64
    let failureCount: Int64
    let formatVersion: Int64
    let details: String
    let tree: Data
    let digest: Data

    init(_ snapshot: ScanSnapshot, savedAt date: Date) throws {
        let root = snapshot.tree.root
        let unsigned = SavedRow(
            rootKey: snapshot.root.key,
            rootIdentity: String(decoding: try SnapshotStore.encoder.encode(snapshot.root), as: UTF8.self),
            scope: snapshot.scope.rawValue,
            finishedAt: snapshot.result.finishedAt.timeIntervalSince1970,
            savedAt: date.timeIntervalSince1970,
            allocatedBytes: root.allocatedSize, logicalBytes: root.logicalSize, itemCount: root.itemCount,
            failureCount: Int64(snapshot.result.failureCount), formatVersion: Int64(TreeCodec.formatVersion),
            details: String(decoding: try SnapshotStore.encoder.encode(SnapshotDetails(snapshot)), as: UTF8.self),
            tree: TreeCodec.encode(snapshot.tree), digest: Data())
        self = unsigned.withDigest(unsigned.computedDigest)
    }

    /// Reads columns 0-12 in ``columns`` order; `nil` if a text or blob column is missing.
    init?(_ statement: SQLiteConnection.Statement) {
        guard let key = statement.string(0), let identity = statement.string(1), let scope = statement.string(2),
              let details = statement.string(10), let tree = statement.data(11), let digest = statement.data(12) else { return nil }
        self.init(rootKey: key, rootIdentity: identity, scope: scope, finishedAt: statement.double(3), savedAt: statement.double(4),
                  allocatedBytes: statement.int64(5), logicalBytes: statement.int64(6), itemCount: statement.int64(7),
                  failureCount: statement.int64(8), formatVersion: statement.int64(9), details: details, tree: tree, digest: digest)
    }

    init(rootKey: String, rootIdentity: String, scope: String, finishedAt: Double, savedAt: Double, allocatedBytes: Int64,
         logicalBytes: Int64, itemCount: Int64, failureCount: Int64, formatVersion: Int64, details: String, tree: Data, digest: Data) {
        self.rootKey = rootKey
        self.rootIdentity = rootIdentity
        self.scope = scope
        self.finishedAt = finishedAt
        self.savedAt = savedAt
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.itemCount = itemCount
        self.failureCount = failureCount
        self.formatVersion = formatVersion
        self.details = details
        self.tree = tree
        self.digest = digest
    }

    func withDigest(_ digest: Data) -> SavedRow {
        SavedRow(rootKey: rootKey, rootIdentity: rootIdentity, scope: scope, finishedAt: finishedAt, savedAt: savedAt,
                 allocatedBytes: allocatedBytes, logicalBytes: logicalBytes, itemCount: itemCount, failureCount: failureCount,
                 formatVersion: formatVersion, details: details, tree: tree, digest: digest)
    }

    /// SHA-256 of every field except the digest, each length-prefixed so no two rows share a byte stream.
    var computedDigest: Data {
        var bytes = Data("DASR1".utf8)
        func append(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func append(_ data: Data) { append(UInt64(data.count)); bytes.append(data) }
        for text in [rootKey, rootIdentity, scope] { append(Data(text.utf8)) }
        append(finishedAt.bitPattern)
        append(savedAt.bitPattern)
        for value in [allocatedBytes, logicalBytes, itemCount, failureCount, formatVersion] { append(UInt64(bitPattern: value)) }
        append(Data(details.utf8))
        append(tree)
        return TreeCodec.checksum(bytes)
    }

    func bind(to statement: SQLiteConnection.Statement) throws {
        try statement.bind(1, rootKey)
        try statement.bind(2, rootIdentity)
        try statement.bind(3, scope)
        try statement.bind(4, finishedAt)
        try statement.bind(5, savedAt)
        try statement.bind(6, allocatedBytes)
        try statement.bind(7, logicalBytes)
        try statement.bind(8, itemCount)
        try statement.bind(9, failureCount)
        try statement.bind(10, formatVersion)
        try statement.bind(11, details)
        try statement.bind(12, tree)
        try statement.bind(13, digest)
    }

    /// The snapshot, after the checksum, the root identity, every range and the tree structure check out.
    func snapshot() throws -> ScanSnapshot {
        guard computedDigest == digest else { throw TreeCodec.DecodeError.checksumMismatch }
        guard let scope = CoverageScope(rawValue: scope) else { throw TreeCodec.DecodeError.invalidStructure("scope") }
        let root = try SnapshotStore.decoder.decode(RootIdentity.self, from: Data(rootIdentity.utf8))
        guard root.key == rootKey else { throw TreeCodec.DecodeError.invalidStructure("root key") }
        let details = try SnapshotStore.decoder.decode(SnapshotDetails.self, from: Data(self.details.utf8))
        let tree = try TreeCodec.decode(tree)
        guard tree.rootPath == root.path else { throw TreeCodec.DecodeError.invalidStructure("root path") }
        return try details.snapshot(tree: tree, root: root, scope: scope)
    }
}

/// Everything about a snapshot except the tree, stored as JSON.
struct SnapshotDetails: Codable {
    struct Issue: Codable {
        let path: String
        let kind: String
        let errorCode: Int32
    }

    struct Statistics: Codable {
        let files, directories, symlinks, otherEntries, hardLinkDuplicates, foldersAlreadyCounted: Int
        let durationSeconds: Double
    }

    let staysOnVolume: Bool
    let excludedPaths: [String]
    /// Absent in snapshots written before cloud-safe scan modes existed.
    let cloudScanMode: String?
    let detectsPackages: Bool
    let finishedAt: Date
    let issues: [Issue]
    let issueCounts: [String: Int]
    let statistics: Statistics
    let startBaseline: VolumeBaseline?
    let endBaseline: VolumeBaseline?
    let rescannedFolders: [String]
    /// Absent in rows written before folder rescans recorded it.
    let rescanAllocatedChange: Int64?

    init(_ snapshot: ScanSnapshot) {
        let result = snapshot.result
        staysOnVolume = result.options.staysOnVolume
        excludedPaths = result.options.excludedPaths.sorted()
        cloudScanMode = result.options.cloudScanMode.rawValue
        detectsPackages = result.options.detectsPackages
        finishedAt = result.finishedAt
        issues = result.issues.map { Issue(path: $0.path, kind: $0.kind.rawValue, errorCode: $0.errorCode) }
        issueCounts = Dictionary(uniqueKeysWithValues: result.issueCounts.map { ($0.key.rawValue, $0.value) })
        let stats = result.statistics
        let duration = stats.duration.components
        statistics = Statistics(files: stats.files, directories: stats.directories, symlinks: stats.symlinks,
                                otherEntries: stats.otherEntries, hardLinkDuplicates: stats.hardLinkDuplicates,
                                foldersAlreadyCounted: stats.foldersAlreadyCounted,
                                durationSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        startBaseline = snapshot.startBaseline
        endBaseline = snapshot.endBaseline
        rescannedFolders = snapshot.rescannedFolders
        rescanAllocatedChange = snapshot.rescanAllocatedChange
    }

    func snapshot(tree: FileTree, root: RootIdentity, scope: CoverageScope) throws -> ScanSnapshot {
        func require(_ condition: Bool, _ detail: String) throws {
            if !condition { throw TreeCodec.DecodeError.invalidStructure(detail) }
        }
        let s = statistics
        try require([s.files, s.directories, s.symlinks, s.otherEntries, s.hardLinkDuplicates, s.foldersAlreadyCounted]
            .allSatisfy(SavedRange.isCount), "statistics")
        try require(s.durationSeconds.isFinite && s.durationSeconds >= 0 && s.durationSeconds <= 1e9, "duration")
        try require(SavedRange.isDate(finishedAt), "finish date")
        try require(issueCounts.values.allSatisfy(SavedRange.isCount) && issues.count <= Int(Int32.max), "issue counts")
        try require([startBaseline, endBaseline].allSatisfy { $0?.isPlausible ?? true }, "volume baseline")
        let rescanChange = rescanAllocatedChange ?? 0
        try require(rescanChange.magnitude <= UInt64(SavedRange.maxBytes), "folder rescan change")
        let decodedIssues = try issues.enumerated().map { index, issue -> ScanIssue in
            guard let kind = ScanIssue.Kind(rawValue: issue.kind) else { throw TreeCodec.DecodeError.invalidStructure("issue kind") }
            return ScanIssue(id: index, path: issue.path, kind: kind, errorCode: issue.errorCode)
        }
        var counts: [ScanIssue.Kind: Int] = [:]
        for (raw, value) in issueCounts {
            guard let kind = ScanIssue.Kind(rawValue: raw), value >= 0 else { throw TreeCodec.DecodeError.invalidStructure("issue count") }
            counts[kind] = value
        }
        var stats = ScanStatistics()
        stats.files = statistics.files
        stats.directories = statistics.directories
        stats.symlinks = statistics.symlinks
        stats.otherEntries = statistics.otherEntries
        stats.hardLinkDuplicates = statistics.hardLinkDuplicates
        stats.foldersAlreadyCounted = statistics.foldersAlreadyCounted
        stats.duration = .milliseconds(Int64((statistics.durationSeconds * 1000).rounded()))
        let mode: CloudScanMode
        if let cloudScanMode {
            guard let decoded = CloudScanMode(rawValue: cloudScanMode) else {
                throw TreeCodec.DecodeError.invalidStructure("cloud scan mode")
            }
            mode = decoded
        } else {
            mode = .legacyUnspecified
        }
        let options = ScanOptions(root: URL(fileURLWithPath: tree.rootPath, isDirectory: true), staysOnVolume: staysOnVolume,
                                  excludedPaths: Set(excludedPaths), cloudScanMode: mode, detectsPackages: detectsPackages)
        let result = ScanResult(tree: tree, options: options, issues: decodedIssues, issueCounts: counts,
                                statistics: stats, finishedAt: finishedAt)
        return ScanSnapshot(result: result, root: root, scope: scope, startBaseline: startBaseline,
                            endBaseline: endBaseline, rescannedFolders: rescannedFolders, rescanAllocatedChange: rescanChange)
    }
}
