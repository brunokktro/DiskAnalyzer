import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Every damaged or unexpected file must open without a crash, and nothing that may still
/// hold a valid snapshot is deleted: it is moved aside, unchanged, and the user is told.
@Suite("Snapshot store: damaged and foreign files")
struct SnapshotStoreRecoveryTests {
    private func writeFile(_ path: String, _ data: Data) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func keptPath(_ notices: [StoreNotice]) -> String? {
        for notice in notices {
            switch notice {
            case .recovered(let path, _, _, _), .setAside(let path, _): return path
            default: continue
            }
        }
        return nil
    }

    @Test func zeroByteFileBecomesAnEmptyStore() async throws {
        let temp = try TemporaryStore()
        try writeFile(temp.path, Data())
        let store = temp.open()
        #expect(await store.takeNotices().isEmpty)
        #expect(await store.isWritable)
        try await store.save(syntheticSnapshot(makeTree([("x", 1, 4096)])))
        #expect(await temp.open().summaries().count == 1)
        #expect(try temp.setAsideFiles().isEmpty)
    }

    @Test func garbageIsSetAsideUnchangedAndANewStoreStarts() async throws {
        let temp = try TemporaryStore()
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try writeFile(temp.path, garbage)
        let store = temp.open()
        let notices = await store.takeNotices()
        guard case .recovered(_, let salvaged, _, _)? = notices.first else {
            Issue.record("expected a recovery notice, got \(notices)")
            return
        }
        #expect(salvaged == 0)
        let kept = try #require(keptPath(notices))
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == garbage)
        #expect(await store.isWritable)
        try await store.save(syntheticSnapshot(makeTree([("x", 1, 4096)])))
        #expect(await temp.open().summaries().count == 1)
    }

    @Test func aDamagedHeaderOfARealStoreIsKeptAside() async throws {
        let fixture = try TemporaryFixture()
        let temp = try TemporaryStore()
        try await temp.open().save(snapshot(of: fixture.scan()))
        var bytes = try Data(contentsOf: temp.url)
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0x41, count: 16))
        try bytes.write(to: temp.url)

        let store = temp.open()
        let notices = await store.takeNotices()
        let kept = try #require(keptPath(notices))
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == bytes)
        #expect(await store.summaries().isEmpty)
        #expect(await store.isWritable)
    }

    @Test func aTruncatedStoreOpensKeepsTheFileAndOnlySalvagesValidRows() async throws {
        let temp = try TemporaryStore()
        let store = temp.open()
        let small = [syntheticSnapshot(makeTree([("a", 1, 4096)]), key: 1), syntheticSnapshot(makeTree([("b", 2, 8192)]), key: 2)]
        for item in small { try await store.save(item) }
        let big = try TemporaryFixture(options: .init(includesUnreadableFolder: false, bulkFolders: 30, bulkFilesPerFolder: 60))
        let bigSnapshot = try snapshot(of: big.scan())
        try await store.save(bigSnapshot)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: temp.url)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()
        let truncated = try Data(contentsOf: temp.url)

        let reader = temp.open()
        let notices = await reader.takeNotices()
        guard case .recovered(let kept, let salvaged, _, _)? = notices.first else {
            Issue.record("expected a recovery notice, got \(notices)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == truncated)
        // Whatever was salvaged is a complete, checksum-valid copy of a saved snapshot.
        let summaries = await reader.summaries()
        #expect(summaries.count == salvaged)
        let originals = small + [bigSnapshot]
        for summary in summaries {
            let loaded = try await reader.load(id: summary.id)
            let original = try #require(originals.first { $0.root == summary.root })
            #expect(treesEqual(loaded.tree, original.tree))
        }
        #expect(await reader.isWritable)
    }

    /// Damage outside the rows (here an index page) must not cost any snapshot.
    @Test func damageOutsideTheRowsKeepsEverySnapshot() async throws {
        let temp = try TemporaryStore()
        let store = temp.open()
        let originals = (1...3).map { syntheticSnapshot(makeTree([("f\($0)", Int64($0), Int64($0) * 4096)]), key: UInt64($0)) }
        for item in originals { try await store.save(item) }
        let check = try SQLiteConnection(path: temp.path, readOnly: true)
        let indexPage = try check.integer("SELECT rootpage FROM sqlite_master WHERE name = 'snapshots_saved_at'")
        let pageSize = try check.integer("PRAGMA page_size")
        check.close()
        let handle = try FileHandle(forUpdating: temp.url)
        try handle.seek(toOffset: UInt64((indexPage - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: Int(pageSize)))
        try handle.close()

        let reader = temp.open()
        let notices = await reader.takeNotices()
        guard case .recovered(_, let salvaged, let unreadable, _)? = notices.first else {
            Issue.record("expected a recovery notice, got \(notices)")
            return
        }
        #expect(salvaged == 3)
        #expect(unreadable == 0)
        for original in originals {
            let summary = try #require(await reader.summaries().first { $0.root == original.root })
            #expect(treesEqual(try await reader.load(id: summary.id).tree, original.tree))
        }
    }

    @Test func aNewerFormatIsLeftUntouchedAndSavingIsOff() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("x", 1, 4096)])))
        try sqlite(temp.path, "PRAGMA user_version = 99")
        let before = try sha256(ofFile: temp.path)

        let store = temp.open()
        #expect(await store.takeNotices() == [.newerVersion(99)])
        #expect(await !store.isWritable)
        #expect(await store.summaries().isEmpty)
        await #expect(throws: SnapshotStoreError.self) { try await store.save(syntheticSnapshot(makeTree([("y", 1, 4096)]))) }
        #expect(try sha256(ofFile: temp.path) == before)
        #expect(try temp.setAsideFiles().isEmpty)
    }

    @Test func anOlderFormatIsUpgradedInPlaceAndKeepsItsSnapshots() async throws {
        let temp = try TemporaryStore()
        let original = syntheticSnapshot(makeTree([("x", 1, 4096), ("d/", 0, 0), ("d/y", 3, 8192)]))
        try await temp.open().save(original)
        let v2 = SnapshotSchema(version: 2, create: SnapshotSchema.current.create + ["ALTER TABLE snapshots ADD COLUMN note TEXT"],
                                migrations: [1: ["ALTER TABLE snapshots ADD COLUMN note TEXT"]])
        let store = temp.open(schema: v2)
        #expect(await store.takeNotices().isEmpty)
        let summary = try #require(await store.summaries().first)
        #expect(treesEqual(try await store.load(id: summary.id).tree, original.tree))
        let check = try SQLiteConnection(path: temp.path, readOnly: true)
        #expect(try check.integer("PRAGMA user_version") == 2)
        #expect(try check.integer("SELECT count(*) FROM pragma_table_info('snapshots') WHERE name = 'note'") == 1)
        #expect(try temp.setAsideFiles().isEmpty)
    }

    @Test func anOlderFormatWithoutAnUpgradePathIsSetAsideUnchanged() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("x", 1, 4096)])))
        let before = try Data(contentsOf: temp.url)
        let v3 = SnapshotSchema(version: 3, create: SnapshotSchema.current.create, migrations: [2: ["SELECT 1"]])
        let store = temp.open(schema: v3)
        let notices = await store.takeNotices()
        guard case .setAside(let kept, _)? = notices.first else {
            Issue.record("expected a set-aside notice, got \(notices)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == before)
        #expect(await store.isWritable)
        #expect(try SQLiteConnection(path: temp.path, readOnly: true).integer("PRAGMA user_version") == 3)
    }

    @Test func aFailedUpgradeLeavesTheFileAsItWas() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("x", 1, 4096)])))
        let before = try sha256(ofFile: temp.path)
        let broken = SnapshotSchema(version: 2, create: SnapshotSchema.current.create,
                                    migrations: [1: ["ALTER TABLE snapshots ADD COLUMN note TEXT", "THIS IS NOT SQL"]])
        let store = temp.open(schema: broken)
        let notices = await store.takeNotices()
        guard case .unavailable? = notices.first else {
            Issue.record("expected the store to be unavailable, got \(notices)")
            return
        }
        #expect(await !store.isWritable)
        #expect(try sha256(ofFile: temp.path) == before)
        #expect(await temp.open().summaries().count == 1) // the current build still reads it
    }

    @Test func aForeignDatabaseIsSetAsideUnchanged() async throws {
        let temp = try TemporaryStore()
        try FileManager.default.createDirectory(at: temp.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqlite(temp.path, "CREATE TABLE notes (body TEXT)", "INSERT INTO notes VALUES ('keep me')")
        let before = try Data(contentsOf: temp.url)
        let store = temp.open()
        let notices = await store.takeNotices()
        guard case .setAside(let kept, _)? = notices.first else {
            Issue.record("expected a set-aside notice, got \(notices)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == before)
        #expect(await store.isWritable)
    }

    @Test func noticesAreReportedOnce() async throws {
        let temp = try TemporaryStore()
        try writeFile(temp.path, Data("not a database".utf8))
        let store = temp.open()
        #expect(await store.takeNotices().count == 1)
        #expect(await store.takeNotices().isEmpty)
    }
}
