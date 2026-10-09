import Foundation
import Testing
@testable import DiskAnalyzerCore

/// fariseu-qa, final review of the R6-1/R6-2 fix. The R6 tests run ONE rescan after the disk
/// changed; these feed the snapshot a rescan produced (its real output) into the NEXT rescan,
/// and compare with a FRESH scan of the same disk state.
@Suite("Review 0.2.0: round 7 (fariseu-qa)")
struct ReviewRound7Tests {
    /// A/x and B/y are two links to one 64 KiB inode; fts visits A first, so A/x is counted.
    private func linkedFixture() throws -> TemporaryFixture {
        let fixture = try TemporaryFixture(build: false)
        let fm = FileManager.default
        for folder in ["A", "B", "D"] { try fm.createDirectory(atPath: fixture.path(folder), withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: fixture.path("A/single.txt")))
        try Data(repeating: 3, count: 4096).write(to: URL(fileURLWithPath: fixture.path("D/d.txt")))
        try Data(repeating: 2, count: 64 * 1024).write(to: URL(fileURLWithPath: fixture.path("A/x")))
        try fm.linkItem(atPath: fixture.path("A/x"), toPath: fixture.path("B/y"))
        return fixture
    }

    private func countedLinks(_ tree: FileTree) -> Int {
        [tree.node(at: "A/x"), tree.node(at: "B/y")].compactMap { $0 }
            .filter { !$0.flags.contains(.hardLinkDuplicate) && !$0.flags.contains(.removed) }.count
    }

    /// R7-1. Counted A/x outside deleted, rescan B (R6-1 fix marks B/y duplicate), rescan B
    /// AGAIN. B/y now has one link, so the first rescan stored no inode for it; the second
    /// rescan cannot see that it was a duplicate and counts it next to the stale A/x.
    @Test func rescanningTheDuplicateFolderTwiceAfterTheCountedLinkOutsideWasDeleted() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))

        let once = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        #expect(countedLinks(once.tree) == 1)
        let twice = try await SubtreeRescan.run(once, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        #expect(countedLinks(twice.tree) == 1)
        #expect(twice.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// R7-1 through the real persistence path: save the once-rescanned snapshot, reload it in
    /// another store, rescan B again.
    @Test func theSameAfterSaveAndRestore() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let once = try await SubtreeRescan.run(full, folder: fixture.path("B"))

        let store = try TemporaryStore()
        try await store.open().save(once)
        let reader = store.open()
        let restored = try await reader.load(id: try #require(await reader.summaries().first?.id))
        let twice = try await SubtreeRescan.run(restored, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        #expect(twice.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// R7-2. Same start, then the user rescans A, the folder that held the deleted counted link.
    /// A/x leaves the tree; B/y is a duplicate with no stored inode, so it is never promoted
    /// and the inode is counted ZERO times. A and B were both rescanned, so the whole tree is
    /// as fresh as a new scan.
    @Test func rescanningTheFolderOfTheDeletedCountedLinkAfterwards() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let afterB = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let afterA = try await SubtreeRescan.run(afterB, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(afterA.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == false)
        #expect(afterA.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// R7-2 with the stale path replaced by ANOTHER inode (one link) instead of deleted.
    @Test func staleCountedPathReplacedByAnotherInodeThenBothFoldersRescanned() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        try Data(repeating: 7, count: 16 * 1024).write(to: URL(fileURLWithPath: fixture.path("A/x")))
        let afterB = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        #expect(afterB.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == true)
        let afterA = try await SubtreeRescan.run(afterB, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(afterA.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    // MARK: - Attacks that held

    /// Three links (A/x counted, B/y, C/z): B/y keeps two links, so its inode is stored, and
    /// rescanning B twice and then A matches a fresh scan.
    @Test func threeLinksSurviveRepeatedRescans() async throws {
        let fixture = try linkedFixture()
        try FileManager.default.createDirectory(atPath: fixture.path("C"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: fixture.path("A/x"), toPath: fixture.path("C/z"))
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let b1 = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let b2 = try await SubtreeRescan.run(b1, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        #expect(b2.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        let a = try await SubtreeRescan.run(b2, folder: fixture.path("A"))
        #expect(a.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }

    /// After the R6-1 fix, an unrelated folder rescan changes nothing about the link pair.
    @Test func unrelatedRescanAfterTheFixLeavesThePairAlone() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))
        let afterB = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let afterD = try await SubtreeRescan.run(afterB, folder: fixture.path("D"))
        #expect(afterD.tree.root.allocatedSize == afterB.tree.root.allocatedSize)
        #expect(countedLinks(afterD.tree) == 1)
    }

    /// Counted A/x trashed by the app (still linked from the Trash, so B/y keeps two links),
    /// then the DUPLICATE's folder is rescanned instead of A.
    @Test func trashedCountedLinkThenTheDuplicateFolderRescanned() async throws {
        let fixture = try linkedFixture()
        let elsewhere = try TemporaryFixture(build: false)
        var full = try snapshot(of: fixture.scan())
        let x = try #require(full.tree.id("A/x"))
        let marked = full.result.tree.markRemoved(x)
        #expect(marked)
        try FileManager.default.moveItem(atPath: fixture.path("A/x"), toPath: elsewhere.path("x"))
        let updated = try await SubtreeRescan.run(full, folder: fixture.path("B"))
        let fresh = try fixture.scan()
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
    }
}
