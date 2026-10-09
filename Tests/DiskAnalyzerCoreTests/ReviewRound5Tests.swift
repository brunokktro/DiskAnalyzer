import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Re-review of the F1-F8 fixes (fariseu-qa, 2026-10-08, commit f4a0df4). Scope: only what the
/// fixes changed. R5-1 and R5-2 were regressions of those fixes; both are fixed and their tests
/// now assert the behavior directly.
@Suite("Review 0.2.0: re-review of the F1-F8 fixes")
struct ReviewRound5Tests {
    private static let gb: Int64 = 1_000_000_000

    private func baseline(used: Int64, at seconds: Double) -> VolumeBaseline {
        VolumeBaseline(capturedAt: Date(timeIntervalSince1970: seconds), volumeUUID: "VOL", mountPath: "/", volumeName: "T",
                       totalCapacity: 1_000 * Self.gb, availableCapacity: 1_000 * Self.gb - used, availableForImportantUsage: nil)
    }

    private func result(_ tree: FileTree) -> ScanResult {
        ScanResult(tree: tree, options: ScanOptions(root: URL(fileURLWithPath: tree.rootPath)), issues: [], issueCounts: [:],
                   statistics: ScanStatistics(), finishedAt: Date(timeIntervalSince1970: 9_000))
    }

    /// Whole-volume scan: used 100 GB, measured 90 GB, so 10 GB not attributed. Then only
    /// `small` changes on disk (to `newSize`) and only `small` is rescanned. Nothing outside
    /// changed, so the not-attributed space is still the same 10 GB.
    private func rescanOfTheOnlyFolderThatChanged(to newSize: Int64) async throws -> SpaceReconciliation {
        let tree = makeTree([("big/", 0, 0), ("big/data", 60 * Self.gb, 60 * Self.gb), ("small/", 0, 0),
                             ("small/f", 30 * Self.gb, 30 * Self.gb)])
        let original = syntheticSnapshot(tree, scope: .volume, start: baseline(used: 100 * Self.gb, at: 1_000),
                                         end: baseline(used: 100 * Self.gb, at: 2_000))
        let updated = try await SubtreeRescan.run(
            original, folder: "/fixture/small",
            scanner: { _, _ in self.result(makeTree([("f", newSize, newSize)], root: "/fixture/small")) })
        let now = baseline(used: 100 * Self.gb + (newSize - 30 * Self.gb), at: 9_000)
        return SpaceReconciliation(snapshot: updated, current: now)
    }

    /// R5-1 (regression of the F1 fix): freshness now uses `end.used + rescanAllocatedChange`,
    /// but the buckets still use `end.used`. Freeing 20 GB inside the rescanned folder then shows
    /// up as 20 GB more "not attributed or shared" storage, which does not exist.
    @Test func spaceFreedInARescannedFolderIsNotReportedAsUnattributed() async throws {
        let rec = try await rescanOfTheOnlyFolderThatChanged(to: 10 * Self.gb)
        #expect(rec.freshness == .unchanged(delta: 0)) // the F1 fix itself holds
        #expect(rec.unattributed == 10 * Self.gb)
    }

    /// R5-1, other direction: 20 GB written inside the rescanned folder are not clones or shared
    /// blocks, yet they show up as "measured beyond used".
    @Test func spaceAddedInARescannedFolderIsNotReportedAsMeasuredBeyondUsed() async throws {
        let rec = try await rescanOfTheOnlyFolderThatChanged(to: 50 * Self.gb)
        #expect(rec.freshness == .unchanged(delta: 0))
        #expect(rec.measuredBeyondUsed == 0)
        #expect(rec.unattributed == 10 * Self.gb)
    }

    /// R5-2 (regression of the F3 fix), real disk. B/x and B/y are two links of one inode; the full
    /// scan counts one of them. The counted one is deleted, and an UNRELATED folder A is rescanned.
    /// A fresh scan counts the inode once in B. Before the fix the rescan left B as it was (the
    /// stale link counted, once). Now the surviving duplicate is promoted while the deleted link
    /// is still in the tree, so B counts the inode twice, and the volume's used space did not move,
    /// so freshness does not flag it below the 100 MB tolerance.
    @Test func rescanningAnUnrelatedFolderDoesNotCountAStaleHardLinkTwice() async throws {
        let fixture = try TemporaryFixture(build: false)
        let fm = FileManager.default
        for folder in ["A", "B"] { try fm.createDirectory(atPath: fixture.path(folder), withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: fixture.path("A/a.txt")))
        try Data(repeating: 2, count: 256 * 1024).write(to: URL(fileURLWithPath: fixture.path("B/x")))
        try fm.linkItem(atPath: fixture.path("B/x"), toPath: fixture.path("B/y"))

        let full = try snapshot(of: fixture.scan())
        let counted = try #require(["B/x", "B/y"].first { full.tree.node(at: $0)?.flags.contains(.hardLinkDuplicate) == false })
        try fm.removeItem(atPath: fixture.path(counted))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(updated.tree.node(at: "B")?.allocatedSize == fresh.tree.node(at: "B")?.allocatedSize)
    }

    // MARK: - Attacks on the fixes that should hold

    /// F5 pair: the Collector's `matchesScan` must agree with what the scanner recorded. Every file
    /// of a real, untouched scan is collectable; a false `.changedSinceScan` would block every Trash.
    @Test func everyUntouchedFileOfARealScanPassesTheChangedSinceScanGate() throws {
        let fixture = try TemporaryFixture()
        let tree = try fixture.scan().tree
        var checked = 0, refused: [String] = []
        tree.walkDescendants(of: FileTree.rootID) { id, node in
            if node.kind == .file {
                checked += 1
                if Collector.Item(tree: tree, id: id).limitation == .changedSinceScan { refused.append(tree.path(of: id)) }
            }
            return true
        }
        #expect(checked > 10)
        #expect(refused.isEmpty, "\(refused)")
    }

    /// F5 again, with a file whose mtime has nanoseconds and is touched to the same size: the gate
    /// must see the mtime change.
    @Test func aFileRewrittenWithTheSameSizeIsRefusedFromRestoredResults() throws {
        let fixture = try TemporaryFixture(build: false)
        let path = fixture.path("same-size.bin")
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path))
        let tree = try fixture.scan().tree
        let id = try #require(tree.id("same-size.bin"))
        var times = [timespec(tv_sec: 1_800_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_800_000_000, tv_nsec: 123_456_789)]
        #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
        try Data(repeating: 9, count: 8192).write(to: URL(fileURLWithPath: path))
        #expect(Collector.Item(tree: tree, id: id).limitation == .changedSinceScan)
    }

    /// F6 pair: the TreeCodec range and folder-total checks must accept what the real scanner
    /// produces, including hard links, packages, symlinks and unreadable folders of the fixture,
    /// and the result of a real folder rescan. A false rejection silently drops a saved scan.
    @Test func realScannerOutputAndARealFolderRescanSurviveTheRangeChecks() async throws {
        let fixture = try TemporaryFixture()
        let full = try snapshot(of: fixture.scan())
        _ = try TreeCodec.decode(TreeCodec.encode(full.tree))
        for folder in ["Media", "Projects", "Projects/Beta"] {
            guard full.tree.id(folder) != nil else { continue }
            let updated = try await SubtreeRescan.run(full, folder: fixture.path(folder))
            _ = try TreeCodec.decode(TreeCodec.encode(updated.tree))
            let temp = try TemporaryStore()
            try await temp.open().save(updated)
            #expect(await temp.open().restorableSnapshot() != nil, "folder \(folder)")
        }
    }

    /// F6: a row whose digest is recomputed (the checksum is not a signature) and whose baselines
    /// are inside the accepted ranges but mutually inconsistent, plus a folder-rescan change at the
    /// edge of its range, must not trap in the reconciliation or the labels. Child process: a trap
    /// would otherwise kill the test runner.
    @Test func extremeButInRangeSavedFiguresDoNotTrap() async {
        await #expect(processExitsWith: .success) {
            let max = SavedRange.maxBytes
            let fixture = try TemporaryFixture()
            let base = try snapshot(of: fixture.scan())
            let end = VolumeBaseline(capturedAt: Date(timeIntervalSince1970: 1e10), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                     totalCapacity: max, availableCapacity: 0, availableForImportantUsage: max)
            let start = VolumeBaseline(capturedAt: Date(timeIntervalSince1970: -1e10), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                       totalCapacity: 0, availableCapacity: max, availableForImportantUsage: 0)
            for change in [-max, max] {
                let edited = ScanSnapshot(result: base.result, root: base.root, scope: .volume, startBaseline: start,
                                          endBaseline: end, rescannedFolders: ["/x"], rescanAllocatedChange: change)
                let temp = try TemporaryStore()
                try await temp.open().save(edited)
                let restored = await temp.open().restorableSnapshot() ?? edited
                for current in [VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                               totalCapacity: .max, availableCapacity: 0, availableForImportantUsage: .max),
                                VolumeBaseline(capturedAt: Date(), volumeUUID: "V", mountPath: "/", volumeName: nil,
                                               totalCapacity: 0, availableCapacity: 0, availableForImportantUsage: .min)] {
                    let rec = SpaceReconciliation(snapshot: restored, current: current)
                    _ = ScanLabel.labels(for: rec, restoredAt: Date()).map(\.detail)
                }
            }
        }
    }

    /// F4: a store file that only lacks the new `row_sha256` column (a pre-rename dev build) is set
    /// aside, not deleted, and saving works afterwards.
    @Test func aDevFileWithTheOldChecksumColumnIsSetAsideNotDeleted() async throws {
        let temp = try TemporaryStore()
        let fixture = try TemporaryFixture()
        try await temp.open().save(try snapshot(of: fixture.scan()))
        try sqlite(temp.path, "ALTER TABLE snapshots RENAME COLUMN row_sha256 TO tree_sha256")
        let store = temp.open()
        try await store.save(try snapshot(of: fixture.scan()))
        #expect(await store.isWritable)
        let aside = try temp.setAsideFiles()
        #expect(aside.count == 1)
        let asidePath = temp.url.deletingLastPathComponent().appending(path: try #require(aside.first)).path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: asidePath))
    }
}
