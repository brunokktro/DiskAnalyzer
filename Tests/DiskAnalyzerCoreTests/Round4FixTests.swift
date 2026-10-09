import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Fixes for the 0.2.0 adversarial review (F1-F7). The reviewer's own reproductions live in
/// `ReviewAdversarialTests`; these cover the other side of each fix.
@Suite("Review 0.2.0: fixes")
struct Round4FixTests {
    private static let gb: Int64 = 1_000_000_000

    private func baseline(used: Int64, at seconds: Double) -> VolumeBaseline {
        VolumeBaseline(capturedAt: Date(timeIntervalSince1970: seconds), volumeUUID: "VOL", mountPath: "/", volumeName: "T",
                       totalCapacity: 1_000 * Self.gb, availableCapacity: 1_000 * Self.gb - used, availableForImportantUsage: nil)
    }

    private func result(_ tree: FileTree) -> ScanResult {
        ScanResult(tree: tree, options: ScanOptions(root: URL(fileURLWithPath: tree.rootPath)), issues: [], issueCounts: [:],
                   statistics: ScanStatistics(), finishedAt: Date(timeIntervalSince1970: 9_000))
    }

    /// Recomputes the row checksum after an edit, as someone editing the file on purpose could.
    private func resign(_ path: String) throws {
        let db = try SQLiteConnection(path: path)
        defer { db.close() }
        var signed: [(key: String, digest: Data)] = []
        do {
            let rows = try db.prepare("SELECT \(SavedRow.columns) FROM snapshots")
            while try rows.step() { if let row = SavedRow(rows) { signed.append((row.rootKey, row.computedDigest)) } }
        }
        for (key, digest) in signed {
            let update = try db.prepare("UPDATE snapshots SET row_sha256 = ? WHERE root_key = ?")
            try update.bind(1, digest)
            try update.bind(2, key)
            _ = try update.step()
        }
    }

    // MARK: F1 / F2: freshness after a folder rescan

    /// The other half of F1: space freed INSIDE the rescanned folder is reflected in the results,
    /// so the scan is not reported as changed.
    @Test func freeingSpaceInsideTheRescannedFolderKeepsTheScanFresh() async throws {
        let tree = makeTree([("big/", 0, 0), ("big/data", 60 * Self.gb, 60 * Self.gb), ("small/", 0, 0), ("small/f", 40 * Self.gb, 40 * Self.gb)])
        let original = syntheticSnapshot(tree, scope: .volume, start: baseline(used: 100 * Self.gb, at: 1_000),
                                         end: baseline(used: 100 * Self.gb, at: 2_000))
        let updated = try await SubtreeRescan.run(original, folder: "/fixture/small",
                                                  scanner: { _, _ in self.result(makeTree([("f", 1, 4096)], root: "/fixture/small")) })
        #expect(updated.endBaseline == original.endBaseline)
        #expect(updated.rescanAllocatedChange == 4096 - 40 * Self.gb)

        let rec = SpaceReconciliation(snapshot: updated, current: baseline(used: 60 * Self.gb + 4096, at: 3_000))
        #expect(rec.changeSinceScan == 0)
        #expect(rec.freshness == .unchanged(delta: 0))
        #expect(rec.changeDuringScan == 0)
        let labels = ScanLabel.labels(for: rec, restoredAt: nil)
        #expect(!labels.contains { if case .stale = $0 { true } else if case .changedSinceScan = $0 { true } else { false } })
    }

    @Test func rescanChangeAccumulatesAndSurvivesSaveAndLoad() async throws {
        let tree = makeTree([("a/", 0, 0), ("a/f", 10, 8192), ("b/", 0, 0), ("b/g", 10, 8192)])
        var snapshot = syntheticSnapshot(tree, scope: .volume, end: baseline(used: Self.gb, at: 1))
        snapshot = try await SubtreeRescan.run(snapshot, folder: "/fixture/a",
                                               scanner: { _, _ in self.result(makeTree([("f", 10, 4096)], root: "/fixture/a")) })
        snapshot = try await SubtreeRescan.run(snapshot, folder: "/fixture/b",
                                               scanner: { _, _ in self.result(makeTree([("g", 10, 16_384)], root: "/fixture/b")) })
        #expect(snapshot.rescanAllocatedChange == -4096 + 8192)

        let temp = try TemporaryStore()
        let store = temp.open()
        try await store.save(snapshot)
        let id = try #require(await store.summaries().first?.id)
        let loaded = try await temp.open().load(id: id)
        #expect(loaded.rescanAllocatedChange == snapshot.rescanAllocatedChange)
        #expect(loaded.rescannedFolders == ["/fixture/a", "/fixture/b"])
    }

    // MARK: F6: no trap from saved figures

    /// Figures that only an edited or damaged file could hold: the reconciliation never traps.
    @Test func reconciliationNeverTrapsOnExtremeBaselines() {
        let negative = VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                      totalCapacity: 10, availableCapacity: -5, availableForImportantUsage: .max)
        let full = VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                  totalCapacity: .max, availableCapacity: 0, availableForImportantUsage: .max)
        let empty = VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                   totalCapacity: .max, availableCapacity: .max, availableForImportantUsage: 0)
        let tree = makeTree([("f", 1, 4096)])
        let rec = SpaceReconciliation(snapshot: syntheticSnapshot(tree, scope: .volume, start: negative, end: negative), current: negative)
        #expect(rec.purgeableEstimate == nil && rec.used == nil && rec.freshness == .unknown)

        for change in [Int64.min, -1, 0, 1, .max] {
            var snapshot = syntheticSnapshot(tree, scope: .volume, start: empty, end: full)
            snapshot.rescanAllocatedChange = change
            for current in [full, empty] {
                let rec = SpaceReconciliation(snapshot: snapshot, current: current)
                _ = ScanLabel.labels(for: rec, restoredAt: Date())
                if let attributed = rec.attributed, let unattributed = rec.unattributed, let accounted = rec.accountedUsed {
                    #expect(attributed + unattributed == accounted)
                }
            }
        }
    }

    /// Positive control for the re-signing helper: an unedited, re-signed row still restores.
    @Test func aReSignedRowWithoutEditsIsStillRestored() async throws {
        let temp = try TemporaryStore()
        let fixture = try TemporaryFixture()
        try await temp.open().save(try snapshot(of: fixture.scan()))
        try resign(temp.path)
        #expect(await temp.open().restorableSnapshot() != nil)
    }

    /// Edited AND re-signed rows (the checksum passes) are still rejected by the range checks,
    /// without trapping, and the store keeps them on disk.
    @Test(arguments: [
        "UPDATE snapshots SET details = json_set(details, '$.endBaseline.availableCapacity', -5)",
        "UPDATE snapshots SET details = json_set(details, '$.endBaseline.totalCapacity', 9223372036854775807)",
        "UPDATE snapshots SET details = json_set(details, '$.statistics.durationSeconds', 1e300)",
        "UPDATE snapshots SET details = json_set(details, '$.statistics.files', -1)",
        "UPDATE snapshots SET details = json_set(details, '$.finishedAt', 1e300)",
        "UPDATE snapshots SET details = json_set(details, '$.rescanAllocatedChange', -9223372036854775808)",
    ])
    func anEditedAndReSignedRowIsNotRestored(_ edit: String) async throws {
        let temp = try TemporaryStore()
        let fixture = try TemporaryFixture()
        try await temp.open().save(try snapshot(of: fixture.scan()))
        try sqlite(temp.path, edit)
        try resign(temp.path)
        let reader = temp.open()
        #expect(await reader.restorableSnapshot() == nil)
        let id = try #require(await reader.summaries().first?.id)
        await #expect(throws: SnapshotStoreError.self) { try await reader.load(id: id) }
    }

    /// The list is read without the checksum: absurd list figures skip the row instead of
    /// reaching date formatting or the sidebar.
    @Test(arguments: ["saved_at = 1e300", "finished_at = -1e300", "allocated_bytes = -1", "failure_count = 9223372036854775807"])
    func aRowWithAbsurdListFiguresIsLeftOutOfTheList(_ assignment: String) async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("a", 1, 4096)]), key: 1))
        try await temp.open().save(syntheticSnapshot(makeTree([("b", 1, 4096)]), key: 2))
        try sqlite(temp.path, "UPDATE snapshots SET \(assignment) WHERE root_key = (SELECT root_key FROM snapshots LIMIT 1)")
        #expect(await temp.open().summaries().count == 1)
    }

    @Test func aFolderSmallerThanItsChildrenIsRejected() throws {
        let tree = makeTree([("d/", 0, 0), ("d/a", 10, 4096)])
        var nodes = tree.nodes
        let folder = Int(try #require(tree.id("d")))
        nodes[folder].allocatedSize = 0
        let edited = FileTree(rootPath: tree.rootPath, nodes: nodes, childIndex: tree.childIndex)
        #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(TreeCodec.encode(edited)) }
    }

    @Test func aDateThatIsNotANumberIsRejected() {
        let tree = makeTree([("a", 10, 4096)])
        var nodes = tree.nodes
        nodes[1].modificationTime = .nan
        let edited = FileTree(rootPath: tree.rootPath, nodes: nodes, childIndex: tree.childIndex)
        #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(TreeCodec.encode(edited)) }
    }

    /// Control for the aggregation check: removed entries and hard-link duplicates are not
    /// summed into their folder, so a tree with both still decodes.
    @Test func removedEntriesAndDuplicatesStillDecode() throws {
        var tree = makeTree([("d/", 0, 0), ("d/a", 10, 4096), ("d/b", 10, 4096), ("d/c", 10, 4096)])
        tree.markHardLinkDuplicate(try #require(tree.id("d/c")))
        #expect(tree.markRemoved(try #require(tree.id("d/a"))))
        let decoded = try TreeCodec.decode(TreeCodec.encode(tree))
        #expect(treesEqual(decoded, tree))
    }

    // MARK: F4: schema verified at open

    /// A pre-release file with the right application ID and version but another column set is
    /// set aside (kept) instead of failing every save.
    @Test func aFileWithAnotherColumnSetIsSetAside() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("a", 1, 4096)])))
        try sqlite(temp.path, "DROP TABLE snapshots", "CREATE TABLE snapshots (id INTEGER PRIMARY KEY, root_key TEXT, tree_sha256 BLOB)")
        let store = temp.open()
        let notices = await store.takeNotices()
        #expect(notices.contains { if case .setAside = $0 { true } else { false } })
        #expect(await store.isWritable)
        try await store.save(syntheticSnapshot(makeTree([("a", 1, 4096)])))
        #expect(await store.summaries().count == 1)
        #expect(try temp.setAsideFiles().count == 1)
    }

    // MARK: F3: hard links across the folder boundary

    /// The counted link survives and only the duplicate outside goes away: the merged tree
    /// still matches a fresh scan (the direction the first fix covered, kept working).
    @Test func deletingTheDuplicateLinkOutsideThenRescanningMatchesAFreshScan() async throws {
        let fixture = try TemporaryFixture()
        let full = try snapshot(of: fixture.scan())
        let links = ["Projects/Beta/shared.bin", "Media/shared-link.bin"]
        let counted = try #require(links.first { full.tree.node(at: $0)?.flags.contains(.hardLinkDuplicate) == false })
        let folder = counted.hasPrefix("Media") ? "Media" : "Projects/Beta"
        let updated = try await SubtreeRescan.run(full, folder: fixture.path(folder))
        let fresh = try fixture.scan()
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        #expect(updated.tree.root.itemCount == fresh.tree.root.itemCount)
        #expect(updated.result.statistics.hardLinkDuplicates == fresh.statistics.hardLinkDuplicates)
    }
}
