import Foundation
import Testing
@testable import DiskAnalyzerCore

/// fariseu-qa, re-review of 65a20b8 (R5-1, R5-2). Every expectation here compares a folder
/// rescan with a FRESH scan of the same disk state: the fresh scanner is the other side of
/// the pair, so the expectation is not authored by the rule under test.
@Suite("Review 0.2.0: round 6 (fariseu-qa)")
struct ReviewRound6Tests {
    /// A/x and B/y are two links to one 64 KiB inode; fts visits A first, so A/x is counted.
    private func linkedFixture() throws -> TemporaryFixture {
        let fixture = try TemporaryFixture(build: false)
        let fm = FileManager.default
        for folder in ["A", "B"] { try fm.createDirectory(atPath: fixture.path(folder), withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: fixture.path("A/single.txt")))
        try Data(repeating: 2, count: 64 * 1024).write(to: URL(fileURLWithPath: fixture.path("A/x")))
        try fm.linkItem(atPath: fixture.path("A/x"), toPath: fixture.path("B/y"))
        return fixture
    }

    /// Real pair: scanner -> SQLite store -> a second store decodes it -> folder rescan.
    /// The inode list must survive the real persistence path, not only `TreeCodec` in memory.
    @Test func aRestoredSnapshotSettlesHardLinksLikeAFreshScan() async throws {
        let fixture = try linkedFixture()
        let store = try TemporaryStore()
        try await store.open().save(try snapshot(of: fixture.scan()))
        let reader = store.open()
        let id = try #require(await reader.summaries().first?.id)
        let restored = try await reader.load(id: id)
        #expect(restored.tree.linkInodes.count == 2)

        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let updated = try await SubtreeRescan.run(restored, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        #expect(updated.tree.root.itemCount == fresh.tree.root.itemCount)

        // And the rescanned snapshot saves and reloads with its inode list intact.
        try await reader.save(updated)
        let again = try await store.open().load(id: try #require(await store.open().summaries().first?.id))
        #expect(again.tree.linkInodes == updated.tree.linkInodes)
    }

    /// Mirror of R5-2. The counted link (A/x) is OUTSIDE the rescanned folder and is deleted;
    /// the duplicate (B/y) is inside. Deleting a link frees no space, so freshness cannot see it.
    /// The commit claims "a link deleted outside never makes the inode count twice" and
    /// ARCHITECTURE.md says the reconciliation keeps "each inode counted exactly once".
    @Test func rescanningTheFolderOfTheDuplicateAfterTheCountedLinkOutsideWasDeleted() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        #expect(full.tree.node(at: "A/x")?.flags.contains(.hardLinkDuplicate) == false)
        #expect(full.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == true)
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        // Stale A/x still counted + B/y now counted = the inode twice.
        let counted = [updated.tree.node(at: "A/x"), updated.tree.node(at: "B/y")]
            .compactMap { $0 }.filter { !$0.flags.contains(.hardLinkDuplicate) && !$0.flags.contains(.removed) }.count
        #expect(counted == 1)
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// Three links, counted one outside (A/x), duplicates inside B and outside C. Delete A/x,
    /// rescan B: the rescan sees B/y with two links, finds no LIVE counted link outside and counts
    /// it, while the tree still counts the stale A/x.
    @Test func threeLinksAndTheCountedOneOutsideDeleted() async throws {
        let fixture = try linkedFixture()
        try FileManager.default.createDirectory(atPath: fixture.path("C"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: fixture.path("A/x"), toPath: fixture.path("C/z"))
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// Regression of the R5-2 fix: the counted link inside the folder was moved to the Trash by
    /// the app (node flagged `.removed`, file gone from the root). `countedInsideBefore` walks
    /// live children only, so the duplicate outside is never promoted, while 0.2.0 at f4a0df4
    /// promoted it. A fresh scan counts B/y.
    @Test func aCountedLinkTrashedByTheAppThenTheFolderRescanned() async throws {
        let fixture = try linkedFixture()
        let elsewhere = try TemporaryFixture(build: false)
        var full = try snapshot(of: fixture.scan())
        let x = try #require(full.tree.id("A/x"))
        let marked = full.result.tree.markRemoved(x)
        #expect(marked)
        try FileManager.default.moveItem(atPath: fixture.path("A/x"), toPath: elsewhere.path("x"))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(updated.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == false)
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// Control for the rule R5-2 added: the original R5-2 case still holds (counted link outside
    /// deleted, duplicate outside, rescan of an unrelated folder never promotes).
    @Test func theOriginalR5_2CaseStillHolds() async throws {
        let fixture = try linkedFixture()
        try FileManager.default.createDirectory(atPath: fixture.path("D"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4096).write(to: URL(fileURLWithPath: fixture.path("D/d.txt")))
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let updated = try await SubtreeRescan.run(full, folder: fixture.path("D"))
        #expect(updated.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == true)
    }

    /// R5-1 invariants on a REAL rescan with real baselines (not a synthetic change value).
    @Test func bucketsAddUpOnARealFolderRescan() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan(), scope: .volume)
        try Data(repeating: 9, count: 512 * 1024).write(to: URL(fileURLWithPath: fixture.path("A/new.bin")))
        let updated = try await SubtreeRescan.run(full, folder: fixture.path("A"))
        #expect(updated.rescanAllocatedChange > 0)
        let rec = SpaceReconciliation(snapshot: updated, current: VolumeBaseline.capture(forPath: fixture.rootPath))
        let accounted = try #require(rec.accountedUsed), used = try #require(rec.used)
        #expect(accounted == used + updated.rescanAllocatedChange)
        let a = try #require(rec.attributed), u = try #require(rec.unattributed), b = try #require(rec.measuredBeyondUsed)
        #expect(a >= 0 && u >= 0 && b >= 0)
        #expect(a + u == accounted)
        #expect(a + b == rec.measuredAllocated)
    }
}
