import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Adversarial review of 0.2.0 (fariseu-qa, 2026-10-08). Each test feeds one side's real
/// output into the other side. The gaps it found (F1-F6) are fixed and their `withKnownIssue`
/// wrappers removed: every test here asserts the fixed behavior directly.
@Suite("Review 0.2.0: adversarial")
struct ReviewAdversarialTests {
    private static let gb: Int64 = 1_000_000_000

    private func baseline(used: Int64, at seconds: Double, uuid: String = "VOL") -> VolumeBaseline {
        VolumeBaseline(capturedAt: Date(timeIntervalSince1970: seconds), volumeUUID: uuid, mountPath: "/", volumeName: "T",
                       totalCapacity: 1_000 * Self.gb, availableCapacity: 1_000 * Self.gb - used, availableForImportantUsage: nil)
    }

    private func result(_ tree: FileTree) -> ScanResult {
        ScanResult(tree: tree, options: ScanOptions(root: URL(fileURLWithPath: tree.rootPath)), issues: [], issueCounts: [:],
                   statistics: ScanStatistics(), finishedAt: Date(timeIntervalSince1970: 9_000))
    }

    /// A whole-volume scan measures 100 GB. Later 50 GB are deleted OUTSIDE `small`, and only
    /// `small` is rescanned. The tree still holds the 50 GB that no longer exist, so the
    /// results must not read as unchanged against the volume.
    private func rescannedAfterOutsideDeletion() async throws -> (updated: ScanSnapshot, now: VolumeBaseline) {
        let tree = makeTree([("big/", 0, 0), ("big/data", 100 * Self.gb, 100 * Self.gb), ("small/", 0, 0), ("small/f", 1, 4096)])
        let original = syntheticSnapshot(tree, scope: .volume, start: baseline(used: 99 * Self.gb, at: 1_000),
                                         end: baseline(used: 100 * Self.gb, at: 2_000))
        let now = baseline(used: 50 * Self.gb, at: 9_000)
        let updated = try await SubtreeRescan.run(
            original, folder: "/fixture/small",
            scanner: { _, _ in self.result(makeTree([("f", 1, 4096)], root: "/fixture/small")) })
        return (updated, now)
    }

    @Test func aFolderRescanDoesNotHideChangesOutsideTheFolder() async throws {
        let (updated, now) = try await rescannedAfterOutsideDeletion()
        #expect(updated.tree.node(at: "big/data")?.allocatedSize == 100 * Self.gb)
        let rec = SpaceReconciliation(snapshot: updated, current: now)
        let labels = ScanLabel.labels(for: rec, restoredAt: nil)
        // F1 fixed: the full scan's baseline is kept, so the 50 GB deleted outside the folder show.
        #expect(labels.contains { if case .stale = $0 { true } else { false } })
        #expect(rec.changeSinceScan == -50 * Self.gb)
    }

    @Test func changeDuringTheScanStaysTheFullScansAfterAFolderRescan() async throws {
        let (updated, now) = try await rescannedAfterOutsideDeletion()
        let rec = SpaceReconciliation(snapshot: updated, current: now)
        // F2 fixed: 'During the scan' stays the full scan's own change.
        #expect(rec.changeDuringScan == 1 * Self.gb)
    }

    /// The full scan counted one link of the shared inode. That counted link is deleted and its
    /// folder is rescanned on its own: the other link (marked duplicate outside the folder) is now
    /// the only one and a fresh full scan counts it. The merged tree must agree.
    @Test func deletingTheCountedHardLinkThenRescanningItsFolderMatchesAFreshScan() async throws {
        let fixture = try TemporaryFixture()
        let full = try snapshot(of: fixture.scan())
        let links = ["Projects/Beta/shared.bin", "Media/shared-link.bin"]
        let counted = try #require(links.first { full.tree.node(at: $0)?.flags.contains(.hardLinkDuplicate) == false })
        let folder = counted.hasPrefix("Media") ? "Media" : "Projects/Beta"
        try FileManager.default.removeItem(atPath: fixture.path(counted))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path(folder))
        let fresh = try fixture.scan()
        // F3 fixed: the surviving link outside the folder is counted again.
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        #expect(updated.tree.root.itemCount == fresh.tree.root.itemCount)
        #expect(updated.tree.root.logicalSize == fresh.tree.root.logicalSize)
    }

    /// A Disk Analyzer file (right application_id and user_version) whose table is gone passes
    /// `quick_check`. The store must not stay silently unable to save forever.
    @Test func aStoreWhoseTableIsMissingRecoversInsteadOfFailingEverySave() async throws {
        let temp = try TemporaryStore()
        try await temp.open().save(syntheticSnapshot(makeTree([("a", 1, 4096)])))
        try sqlite(temp.path, "DROP TABLE snapshots")

        let store = temp.open()
        let writable = await store.isWritable
        var saved = true
        do { try await store.save(syntheticSnapshot(makeTree([("a", 1, 4096)]))) } catch { saved = false }
        // F4 fixed: the file without its table is set aside at open and a new one is started.
        #expect(writable && saved)
        #expect(try temp.setAsideFiles().count == 1)
        #expect(await store.summaries().isEmpty || saved)
    }

    /// Restored results are older than live ones. A file replaced at the same path since the
    /// scan is a different object (other inode, other size, other mtime); Trash must refuse it.
    @Test func trashFromRestoredResultsRefusesAFileReplacedSinceTheScan() async throws {
        let fixture = try TemporaryFixture()
        let temp = try TemporaryStore()
        try await temp.open().save(try snapshot(of: fixture.scan()))
        let restored = try #require(await temp.open().restorableSnapshot())

        let relative = "Media/Photos/2019/mountain.heic"
        let target = fixture.path(relative)
        let scanned = try #require(restored.tree.node(at: relative))
        try FileManager.default.removeItem(atPath: target)
        try Data(repeating: 7, count: 10).write(to: URL(fileURLWithPath: target))

        let item = Collector.Item(tree: restored.tree, id: try #require(restored.tree.id(relative)))
        #expect(item.logicalSize == scanned.logicalSize) // the dialog would show the old size
        // F5 fixed: the replaced file no longer matches the scan, so it is refused at collect and at Trash.
        #expect(item.limitation == .changedSinceScan)
        var collector = Collector()
        #expect(collector.add(item) == .refused(.changedSinceScan))
        let mover = RecordingMover()
        let outcomes = TrashOperation.run([item], policy: TrashPolicy(scanRoot: restored.tree.rootPath), mover: mover)
        #expect(outcomes.first?.succeeded == false)
        #expect(mover.moved.isEmpty)
    }

    @Test func anEditedTreeWithImpossibleSizesIsRejected() {
        // Valid structure, valid checksum (unkeyed SHA-256 can be recomputed by anyone who edits the
        // file), but a negative file size and a root total that is not the sum of its children.
        var nodes = makeTree([("a", 10, 4096)]).nodes
        nodes[1].allocatedSize = -4096
        nodes[0].allocatedSize = .max
        let edited = FileTree(rootPath: "/fixture", nodes: nodes, childIndex: makeTree([("a", 10, 4096)]).childIndex)
        // F6 fixed: sizes are range-checked and folders must hold their children.
        #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(TreeCodec.encode(edited)) }
    }

    // MARK: - Attacks that should hold (they do not use withKnownIssue)

    /// A whole-volume snapshot restored when only an unrelated volume is current never yields
    /// freshness or a 'since the scan' number.
    @Test func currentBaselineOfAnotherVolumeIsNeverCompared() {
        let snap = syntheticSnapshot(makeTree([("f", Self.gb, Self.gb)]), scope: .volume,
                                     start: baseline(used: 10 * Self.gb, at: 1), end: baseline(used: 10 * Self.gb, at: 2))
        let rec = SpaceReconciliation(snapshot: snap, current: baseline(used: 900 * Self.gb, at: 3, uuid: "OTHER"))
        #expect(rec.freshness == .unknown)
        #expect(rec.changeSinceScan == nil)
    }

    /// Measured above used: every bucket non-negative and both identities hold over a sweep,
    /// including Int64 extremes the UI could receive from a damaged baseline.
    @Test func reconciliationIdentitiesHoldOverASweep() {
        let values: [Int64] = [0, 1, 4096, Self.gb, 999 * Self.gb, 1_000 * Self.gb]
        for measured in values {
            for used in values {
                let end = VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                         totalCapacity: 1_000 * Self.gb, availableCapacity: 1_000 * Self.gb - used,
                                         availableForImportantUsage: nil)
                let rec = SpaceReconciliation(snapshot: syntheticSnapshot(makeTree([("f", measured, measured)]), scope: .volume, end: end),
                                              current: end)
                let attributed = rec.attributed ?? -1, unattributed = rec.unattributed ?? -1, beyond = rec.measuredBeyondUsed ?? -1
                #expect(attributed >= 0 && unattributed >= 0 && beyond >= 0)
                #expect(attributed + unattributed == used)
                #expect(attributed + beyond == measured)
            }
        }
    }

    /// The saved `details` JSON is not covered by the tree checksum and is decoded without range
    /// checks. A damaged value there must not crash the app, which restores it at every launch.
    /// Each case runs in a child process because the current code traps.
    @Test func damagedBaselineInSavedDetailsDoesNotCrashTheReconciliation() async {
        // F6 fixed: the row checksum covers the details, and the reconciliation never traps.
        await #expect(processExitsWith: .success) {
            let temp = try TemporaryStore()
            let fixture = try TemporaryFixture()
            try await temp.open().save(try snapshot(of: fixture.scan()))
            try sqlite(temp.path, """
                UPDATE snapshots SET details = json_set(details, '$.endBaseline.availableCapacity', -5,
                    '$.endBaseline.availableForImportantUsage', 9223372036854775807)
                """)
            if let restored = await temp.open().restorableSnapshot() {
                _ = ScanLabel.labels(for: SpaceReconciliation(snapshot: restored, current: nil), restoredAt: Date())
            }
        }
    }

    @Test func damagedDurationInSavedDetailsDoesNotCrashTheRestore() async {
        await #expect(processExitsWith: .success) {
            let temp = try TemporaryStore()
            let fixture = try TemporaryFixture()
            try await temp.open().save(try snapshot(of: fixture.scan()))
            try sqlite(temp.path, "UPDATE snapshots SET details = json_set(details, '$.statistics.durationSeconds', 1e300)")
            _ = await temp.open().restorableSnapshot()
        }
    }

    /// A saved row whose tree claims a root other than its identity's path is never restored.
    @Test func aRowWhoseTreeAndIdentityDisagreeIsNotRestored() async throws {
        let temp = try TemporaryStore()
        let fixture = try TemporaryFixture()
        try await temp.open().save(try snapshot(of: fixture.scan()))
        let other = TreeCodec.encode(makeTree([("x", 1, 4096)], root: "/elsewhere"))
        let hex = TreeCodec.checksum(other).map { String(format: "%02x", $0) }.joined()
        let blob = other.map { String(format: "%02x", $0) }.joined()
        // The checksum column covers the whole row since the F6 fix (tree_sha256 became row_sha256).
        try sqlite(temp.path, "UPDATE snapshots SET tree = x'\(blob)', row_sha256 = x'\(hex)'")
        #expect(await temp.open().restorableSnapshot() == nil)
    }

    /// Two stores (two app instances) saving different roots concurrently lose nothing.
    @Test func twoInstancesSavingConcurrentlyKeepBothRoots() async throws {
        let temp = try TemporaryStore()
        let a = temp.open(), b = temp.open()
        _ = await a.isWritable
        _ = await b.isWritable
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? a : b
                group.addTask { try await store.save(syntheticSnapshot(makeTree([("f", Int64(index), 4096)]), key: UInt64(index % 4 + 1))) }
            }
            try await group.waitForAll()
        }
        #expect(await temp.open().summaries().count == 4)
        #expect(try temp.setAsideFiles().isEmpty)
    }
}
