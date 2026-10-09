import Foundation
import Testing
@testable import DiskAnalyzerCore

// MARK: - Helpers shared by the 0.2.0 suites

/// A store in its own temporary folder. Tests never touch the user's saved scans.
final class TemporaryStore: @unchecked Sendable {
    let folder: TemporaryFixture
    let url: URL

    init() throws {
        folder = try TemporaryFixture(build: false)
        url = folder.root.appending(path: "Support/Snapshots.sqlite")
    }

    var path: String { url.path(percentEncoded: false) }

    func open(schema: SnapshotSchema = .current, maxSnapshots: Int = SnapshotStore.defaultMaxSnapshots) -> SnapshotStore {
        SnapshotStore(url: url, schema: schema, maxSnapshots: maxSnapshots)
    }

    /// Files in the store folder other than the database itself (set-aside copies).
    func setAsideFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false))
            .filter { $0.contains(".unreadable-") && $0.hasSuffix(".sqlite") }
    }
}

/// A snapshot of a real scan, with the real root identity of the scanned folder.
func snapshot(of result: ScanResult, scope: CoverageScope = .folder, end: VolumeBaseline? = nil,
              start: VolumeBaseline? = nil) throws -> ScanSnapshot {
    let identity = try #require(RootIdentity.capture(path: result.tree.rootPath))
    return ScanSnapshot(result: result, root: identity, scope: scope, startBaseline: start,
                        endBaseline: end ?? VolumeBaseline.capture(forPath: result.tree.rootPath))
}

/// A snapshot of an in-memory tree with a made-up identity (never checked against the disk).
func syntheticSnapshot(_ tree: FileTree, key fileID: UInt64 = 1, issues: [ScanIssue] = [],
                       counts: [ScanIssue.Kind: Int] = [:], scope: CoverageScope = .folder,
                       start: VolumeBaseline? = nil, end: VolumeBaseline? = nil) -> ScanSnapshot {
    let result = ScanResult(tree: tree, options: ScanOptions(root: URL(fileURLWithPath: tree.rootPath)), issues: issues,
                            issueCounts: counts, statistics: ScanStatistics(), finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let root = RootIdentity(path: tree.rootPath, volumeUUID: "TEST-UUID", mountPath: "/", fileSystemType: "apfs", fileID: fileID)
    return ScanSnapshot(result: result, root: root, scope: scope, startBaseline: start, endBaseline: end)
}

func treesEqual(_ a: FileTree, _ b: FileTree) -> Bool {
    a.rootPath == b.rootPath && a.nodes == b.nodes && a.childIndex == b.childIndex
}

func sha256(ofFile path: String) throws -> Data {
    TreeCodec.checksum(try Data(contentsOf: URL(fileURLWithPath: path)))
}

/// Runs SQL on a database file through a separate connection (to tamper with it, as another process could).
func sqlite(_ path: String, _ statements: String...) throws {
    let db = try SQLiteConnection(path: path)
    for statement in statements { try db.execute(statement) }
    db.close()
}

// MARK: - Tree codec

@Suite("Tree codec")
struct TreeCodecTests {
    @Test func roundTripsARealScanExactly() throws {
        let fixture = try TemporaryFixture()
        let tree = try fixture.scan().tree
        let decoded = try TreeCodec.decode(TreeCodec.encode(tree))
        #expect(treesEqual(decoded, tree))
        #expect(decoded.root.allocatedSize == tree.root.allocatedSize)
        for index in 0..<tree.count { #expect(decoded.path(of: NodeID(index)) == tree.path(of: NodeID(index))) }
    }

    @Test func keepsFlagsIncludingRemovedAndInvalidNames() throws {
        var tree = makeTree([("a/", 0, 0), ("a/x", 10, 4096), ("b", 5, 4096)], flags: ["b": [.invalidName, .hidden]])
        tree.markRemoved(tree.id("a/x")!)
        let decoded = try TreeCodec.decode(TreeCodec.encode(tree))
        #expect(treesEqual(decoded, tree))
        let removed = try #require(decoded.nodes.firstIndex { $0.name == "x" })
        #expect(decoded.isRemoved(NodeID(removed)))
        #expect(decoded.node(at: "b")?.flags.contains(.invalidName) == true)
    }

    @Test func everyTruncationThrowsInsteadOfCrashing() throws {
        let data = TreeCodec.encode(makeTree([("a/", 0, 0), ("a/x", 10, 4096), ("ü.txt", 1, 4096)]))
        for length in 0..<data.count {
            #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(data.prefix(length)) }
        }
        #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(data + Data([0])) }
    }

    @Test func structuralDamageIsRejected() throws {
        let tree = makeTree([("a/", 0, 0), ("a/x", 10, 4096), ("b", 5, 4096)])
        let data = TreeCodec.encode(tree)
        // Flip every byte once: the decoder must either throw or return a tree that still
        // satisfies every invariant navigation relies on. It must never crash.
        for offset in 0..<data.count {
            var damaged = data
            damaged[offset] ^= 0xFF
            if let decoded = try? TreeCodec.decode(damaged) {
                for index in 0..<decoded.count {
                    _ = decoded.children(of: NodeID(index))
                    _ = decoded.path(of: NodeID(index))
                }
            }
        }
        // A child pointing at a node whose parent is someone else.
        var nodes = tree.nodes
        nodes[2].parent = 2
        #expect(throws: TreeCodec.DecodeError.self) {
            try TreeCodec.validate(nodes: nodes, childIndex: tree.childIndex, rootPath: tree.rootPath)
        }
    }

    @Test func otherFormatVersionIsNotDecoded() throws {
        var data = TreeCodec.encode(makeTree([("x", 1, 1)]))
        data[4] = UInt8(TreeCodec.formatVersion + 1)
        #expect(throws: TreeCodec.DecodeError.unsupportedVersion(TreeCodec.formatVersion + 1)) { try TreeCodec.decode(data) }
    }
}

// MARK: - Store: writing and reading back

@Suite("Snapshot store")
struct SnapshotStoreTests {
    @Test func aSecondStoreReadsBackWhatTheFirstWrote() async throws {
        let fixture = try TemporaryFixture()
        let result = try fixture.scan()
        let saved = try snapshot(of: result)
        let temp = try TemporaryStore()
        try await temp.open().save(saved)

        // A new instance, as after a relaunch: nothing is shared with the writer but the file.
        let reader = temp.open()
        #expect(await reader.takeNotices().isEmpty)
        let summaries = await reader.summaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.root == saved.root)
        #expect(summary.allocatedBytes == result.tree.root.allocatedSize)
        #expect(summary.failureCount == result.failureCount)
        let loaded = try await reader.load(id: summary.id)
        #expect(treesEqual(loaded.tree, result.tree))
        #expect(loaded.result.issues.map(\.path) == result.issues.map(\.path))
        #expect(loaded.result.issueCounts == result.issueCounts)
        #expect(loaded.result.statistics.files == result.statistics.files)
        #expect(loaded.result.options.staysOnVolume == result.options.staysOnVolume)
        // Dates go through JSON as seconds, so they match to well under a millisecond.
        let end = try #require(loaded.endBaseline), savedEnd = try #require(saved.endBaseline)
        #expect(abs(end.capturedAt.timeIntervalSince(savedEnd.capturedAt)) < 0.001)
        #expect(end.volumeUUID == savedEnd.volumeUUID && end.used == savedEnd.used && end.mountPath == savedEnd.mountPath)
        #expect(end.availableForImportantUsage == savedEnd.availableForImportantUsage)
        #expect(abs(loaded.result.finishedAt.timeIntervalSince(result.finishedAt)) < 0.001)
        #expect(loaded.scope == saved.scope)
        let restored = try #require(await reader.restorableSnapshot())
        #expect(treesEqual(restored.tree, result.tree))
    }

    @Test func storeFileIsPrivateToTheUser() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("x", 1, 1)])))
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: temp.url.deletingLastPathComponent().path(percentEncoded: false))
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func savingTheSameRootReplacesItsSnapshot() async throws {
        let temp = try TemporaryStore()
        let store = temp.open()
        try await store.save(syntheticSnapshot(makeTree([("x", 1, 4096)]), key: 7))
        try await store.save(syntheticSnapshot(makeTree([("x", 1, 4096), ("y", 2, 8192)]), key: 7))
        let summaries = await store.summaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.allocatedBytes == 12_288)
    }

    @Test func keepsTheMostRecentRootsUpToTheLimit() async throws {
        let temp = try TemporaryStore()
        let store = temp.open(maxSnapshots: 3)
        for key in 1...5 { try await store.save(syntheticSnapshot(makeTree([("x", 1, Int64(key) * 4096)]), key: UInt64(key))) }
        let kept = await store.summaries().map(\.root.fileID)
        #expect(kept == [5, 4, 3])
    }

    @Test func aTamperedTreeIsSkippedAndTheNextValidSnapshotIsRestored() async throws {
        let first = try TemporaryFixture()
        let second = try TemporaryFixture()
        let temp = try TemporaryStore()
        let store = temp.open()
        let older = try snapshot(of: first.scan())
        try await store.save(older)
        try await Task.sleep(for: .milliseconds(20))
        try await store.save(snapshot(of: second.scan()))
        // Damage the most recent row's tree as a disk error or another program could.
        try sqlite(temp.path, "UPDATE snapshots SET tree = zeroblob(64) WHERE id = (SELECT id FROM snapshots ORDER BY saved_at DESC LIMIT 1)")
        let reader = temp.open()
        let newest = try #require(await reader.summaries().first)
        await #expect(throws: SnapshotStoreError.self) { try await reader.load(id: newest.id) }
        let restored = try #require(await reader.restorableSnapshot())
        #expect(restored.root == older.root)
        #expect(await reader.summaries().count == 2) // the damaged one is kept, not deleted
    }

    @Test func aSnapshotInAnotherTreeFormatIsListedButNeverDecoded() async throws {
        let fixture = try TemporaryFixture()
        let temp = try TemporaryStore()
        try await temp.open().save(snapshot(of: fixture.scan()))
        try sqlite(temp.path, "UPDATE snapshots SET format_version = \(TreeCodec.formatVersion + 1)")
        let reader = temp.open()
        let summary = try #require(await reader.summaries().first)
        #expect(!summary.isCompatible)
        #expect(await reader.restorableSnapshot() == nil)
        await #expect(throws: SnapshotStoreError.incompatible(TreeCodec.formatVersion + 1)) { try await reader.load(id: summary.id) }
        #expect(await reader.recentScans().first?.canOpen == false)
    }

    @Test func aFailedWriteKeepsThePreviousSnapshot() async throws {
        let fixture = try TemporaryFixture()
        let temp = try TemporaryStore()
        let original = try snapshot(of: fixture.scan())
        try await temp.open().save(original)
        let before = try sha256(ofFile: temp.path)

        chmod(temp.path, 0o400)
        defer { chmod(temp.path, 0o600) }
        let writer = temp.open()
        var changed = original
        changed.rescannedFolders = ["/somewhere"]
        await #expect(throws: (any Error).self) { try await writer.save(changed) }

        #expect(try sha256(ofFile: temp.path) == before)
        let reader = temp.open()
        let loaded = try #require(await reader.restorableSnapshot())
        #expect(treesEqual(loaded.tree, original.tree))
        #expect(loaded.rescannedFolders.isEmpty)
    }
}
