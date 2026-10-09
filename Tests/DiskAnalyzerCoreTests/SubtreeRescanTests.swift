import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Every node as (path, kind, sizes, items, flags without `removed`), for comparing two trees
/// of the same folder regardless of arena order.
private func inventory(_ tree: FileTree) -> [String: [Int64]] {
    var entries: [String: [Int64]] = [:]
    entries[tree.rootPath] = [tree.root.logicalSize, tree.root.allocatedSize, tree.root.itemCount]
    tree.walkDescendants(of: FileTree.rootID) { id, node in
        entries[tree.path(of: id)] = [Int64(node.kind.rawValue), node.logicalSize, node.allocatedSize, node.itemCount,
                                      Int64(node.flags.subtracting(.removed).rawValue)]
        return true
    }
    return entries
}

/// Folder totals equal their own contribution plus their counted children, everywhere.
private func aggregatesAreConsistent(_ tree: FileTree) -> Bool {
    for index in 0..<tree.count where tree[NodeID(index)].isDirectory && !tree.isRemoved(NodeID(index)) {
        let id = NodeID(index)
        let own = tree.ownContribution(of: id)
        guard own.logical >= 0, own.allocated >= 0, own.items == 0 || tree[id].flags.contains(.hardLinkDuplicate) else { return false }
    }
    return true
}

private func write(_ path: String, bytes: Int) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
}

@Suite("Rescan This Folder: subtree replacement")
struct SubtreeReplacementTests {
    @Test func replacingAChangedFolderMatchesAFreshFullScan() throws {
        let fixture = try TemporaryFixture()
        let before = try fixture.scan()
        try write(fixture.path("Media/Photos/2019/new.raw"), bytes: 300_000)
        try FileManager.default.removeItem(atPath: fixture.path("Media/Photos/2019/mountain.heic"))
        try write(fixture.path("Media/Photos/2020/x.jpg"), bytes: 70_000)

        let rescan = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: fixture.path("Media/Photos"))))
        let merged = try before.replacingSubtree(at: fixture.path("Media/Photos"), with: rescan)
        let fresh = try fixture.scan()

        #expect(merged.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        #expect(merged.tree.root.logicalSize == fresh.tree.root.logicalSize)
        #expect(merged.tree.root.itemCount == fresh.tree.root.itemCount)
        #expect(inventory(merged.tree) == inventory(fresh.tree))
        #expect(merged.statistics.files == fresh.statistics.files)
        #expect(merged.statistics.directories == fresh.statistics.directories)
        #expect(merged.statistics.symlinks == fresh.statistics.symlinks)
        #expect(merged.statistics.hardLinkDuplicates == fresh.statistics.hardLinkDuplicates)
        #expect(merged.finishedAt == before.finishedAt)
        #expect(aggregatesAreConsistent(merged.tree))
        // Outside the rescanned folder nothing moved.
        let sizes = { (tree: FileTree) in tree.node(at: "Projects").map { [$0.logicalSize, $0.allocatedSize, $0.itemCount] } }
        #expect(sizes(merged.tree) == sizes(before.tree))
        #expect(merged.tree.node(at: "Media/Photos/2019/mountain.heic") == nil)
    }

    /// `Projects/Beta/shared.bin` and `Media/shared-link.bin` are one inode. Rescanning either
    /// folder on its own must keep it counted once, as a fresh full scan does.
    @Test func aHardLinkAcrossTheFolderBoundaryStaysCountedOnce() async throws {
        let fixture = try TemporaryFixture()
        let full = try snapshot(of: fixture.scan())
        #expect(full.result.statistics.hardLinkDuplicates == 1)
        for folder in ["Media", "Projects/Beta", "Projects"] {
            let updated = try await SubtreeRescan.run(full, folder: fixture.path(folder))
            let fresh = try fixture.scan()
            #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize, "\(folder)")
            #expect(updated.tree.root.logicalSize == fresh.tree.root.logicalSize, "\(folder)")
            #expect(updated.tree.root.itemCount == fresh.tree.root.itemCount, "\(folder)")
            #expect(updated.result.statistics.hardLinkDuplicates == 1, "\(folder)")
            #expect(aggregatesAreConsistent(updated.tree))
            // The copy the full scan counted is still the counted one.
            for path in ["Projects/Beta/shared.bin", "Media/shared-link.bin"] {
                #expect(updated.tree.node(at: path)?.flags.contains(.hardLinkDuplicate)
                        == full.tree.node(at: path)?.flags.contains(.hardLinkDuplicate), "\(folder) \(path)")
            }
        }
    }

    @Test func aRescanThatCanNowReadAFolderReplacesItsIssues() throws {
        let fixture = try TemporaryFixture()
        let before = try fixture.scan()
        #expect(before.issueCounts[.permissionDenied] == 1)
        #expect(before.tree.node(at: "Locked")?.flags.contains(.unreadable) == true)

        chmod(fixture.path("Locked"), 0o755)
        let rescan = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: fixture.path("Locked"))))
        let merged = try before.replacingSubtree(at: fixture.path("Locked"), with: rescan)
        #expect(merged.issueCounts[.permissionDenied] == nil)
        #expect(!merged.issues.contains { $0.path.hasSuffix("/Locked") })
        #expect(merged.tree.node(at: "Locked")?.flags.contains(.unreadable) == false)
        #expect(merged.tree.node(at: "Locked/secret.txt") != nil)
        #expect(merged.failureCount == before.failureCount - 1)
        let fresh = try fixture.scan()
        #expect(inventory(merged.tree) == inventory(fresh.tree))
        #expect(merged.issues.map(\.id) == Array(0..<merged.issues.count))
    }

    @Test func entriesMovedToTheTrashAreDroppedAndTotalsStayConsistent() throws {
        var tree = makeTree([("a/", 0, 0), ("a/x", 10, 4096), ("a/y", 20, 8192), ("b/", 0, 0), ("b/z", 5, 4096)])
        tree.markRemoved(tree.id("a/x")!)
        let replacement = makeTree([("z", 50, 12_288), ("w/", 0, 0), ("w/v", 1, 4096)], root: "/fixture/b")
        let merged = try tree.replacingSubtree(at: tree.id("b")!, with: replacement)
        #expect(merged.root.allocatedSize == 8192 + 12_288 + 4096)
        #expect(merged.root.itemCount == 3)
        #expect(merged.node(at: "a/x") == nil)
        #expect(merged.count == tree.count - 1 + 2) // x dropped, z replaced, w and w/v added
        #expect(merged.node(at: "b")?.name == "b")
        #expect(aggregatesAreConsistent(merged))
        // The decoder accepts it, so a saved merged tree reads back.
        #expect(treesEqual(try TreeCodec.decode(TreeCodec.encode(merged)), merged))
    }

    @Test func folderPropertiesOfTheNameSurvive() throws {
        let tree = makeTree([("Tool.app/", 0, 0), ("Tool.app/bin", 9, 4096), (".hidden/", 0, 0)])
        let package = try tree.replacingSubtree(at: tree.id("Tool.app")!, with: makeTree([("bin", 99, 8192)], root: "/fixture/Tool.app"))
        #expect(package.node(at: "Tool.app")?.isPackage == true)
        let hidden = try tree.replacingSubtree(at: tree.id(".hidden")!, with: makeTree([], root: "/fixture/.hidden"))
        #expect(hidden.node(at: ".hidden")?.flags.contains(.hidden) == true)
    }

    @Test func replacingTheRootGivesTheRescan() throws {
        let tree = makeTree([("a", 1, 4096)])
        let rescan = makeTree([("b/", 0, 0), ("b/c", 2, 8192)])
        let merged = try tree.replacingSubtree(at: FileTree.rootID, with: rescan)
        #expect(inventory(merged) == inventory(rescan))
    }

    @Test func refusesWhatItCannotReplace() throws {
        let tree = makeTree([("a/", 0, 0), ("f", 1, 4096)])
        #expect(throws: SubtreeReplacementError.notAFolder("/fixture/f")) {
            try tree.replacingSubtree(at: tree.id("f")!, with: makeTree([], root: "/fixture/f"))
        }
        #expect(throws: SubtreeReplacementError.rootMismatch(expected: "/fixture/a", found: "/elsewhere")) {
            try tree.replacingSubtree(at: tree.id("a")!, with: makeTree([], root: "/elsewhere"))
        }
        let other = makeTree([("x/", 0, 0)], flags: ["x": [.otherVolume]])
        #expect(!SubtreeRescan.canRescan(other.id("x")!, in: other))
        let invalid = makeTree([("x/", 0, 0)], flags: ["x": [.invalidName]])
        #expect(!SubtreeRescan.canRescan(invalid.id("x")!, in: invalid))
    }
}

/// The rescan writes nothing until it has finished, and a saved snapshot read back by a
/// separate store instance is the one from before a cancelled or failed rescan.
@Suite("Rescan This Folder: atomicity with the saved snapshot")
struct SubtreeRescanAtomicityTests {
    private struct InjectedFailure: Error {}

    /// Mirrors what the app does: save the rescan's result only when `run` returns.
    private func rescanAndSave(_ snapshot: ScanSnapshot, folder: String, store: SnapshotStore,
                               scanner: @escaping SubtreeRescan.Scanner = SubtreeRescan.diskScanner,
                               progress: DiskScanner.ProgressHandler? = nil) async throws {
        let updated = try await SubtreeRescan.run(snapshot, folder: folder, scanner: scanner, progress: progress)
        try await store.save(updated)
    }

    private func assertStoreStillHolds(_ original: ScanSnapshot, temp: TemporaryStore) async throws {
        let reader = temp.open()
        let loaded = try #require(await reader.restorableSnapshot())
        #expect(treesEqual(loaded.tree, original.tree))
        #expect(loaded.rescannedFolders == original.rescannedFolders)
        #expect(await reader.summaries().count == 1)
    }

    @Test func cancellingMidWalkKeepsTheSavedSnapshot() async throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false, bulkFolders: 40, bulkFilesPerFolder: 500))
        let original = try snapshot(of: fixture.scan())
        let temp = try TemporaryStore()
        try await temp.open().save(original)

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<Void, Error>?
            var seen = 0
        }
        let box = Box()
        let store = temp.open()
        let task = Task {
            try await rescanAndSave(original, folder: fixture.path("Bulk"), store: store, scanner: { options, progress in
                var fast = options
                fast.progressInterval = .zero
                return try await DiskScanner().scan(fast, progress: progress)
            }, progress: { update in
                box.lock.withLock {
                    box.seen = update.entriesVisited
                    if update.entriesVisited >= 2_000 { box.task?.cancel() }
                }
            })
        }
        box.lock.withLock { box.task = task }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(box.lock.withLock { box.seen } >= 2_000)
        try await assertStoreStillHolds(original, temp: temp)
    }

    @Test func aFailureAfterTheWalkKeepsTheSavedSnapshot() async throws {
        let fixture = try TemporaryFixture()
        let original = try snapshot(of: fixture.scan())
        let temp = try TemporaryStore()
        try await temp.open().save(original)
        try write(fixture.path("Projects/Beta/more.bin"), bytes: 50_000)

        await #expect(throws: InjectedFailure.self) {
            try await rescanAndSave(original, folder: fixture.path("Projects"), store: temp.open(), scanner: { options, progress in
                _ = try await DiskScanner().scan(options, progress: progress) // the walk itself succeeds
                throw InjectedFailure()                                       // then the I/O layer fails
            })
        }
        try await assertStoreStillHolds(original, temp: temp)
    }

    @Test func aFolderThatVanishedKeepsTheSavedSnapshot() async throws {
        let fixture = try TemporaryFixture()
        let original = try snapshot(of: fixture.scan())
        let temp = try TemporaryStore()
        try await temp.open().save(original)
        try FileManager.default.removeItem(atPath: fixture.path("Media/Photos"))

        await #expect(throws: ScanError.self) {
            try await rescanAndSave(original, folder: fixture.path("Media/Photos"), store: temp.open())
        }
        try await assertStoreStillHolds(original, temp: temp)
    }

    @Test func aFinishedRescanIsSavedAndReadBack() async throws {
        let fixture = try TemporaryFixture()
        let original = try snapshot(of: fixture.scan())
        let temp = try TemporaryStore()
        try await temp.open().save(original)
        try write(fixture.path("Projects/Beta/more.bin"), bytes: 50_000)

        try await rescanAndSave(original, folder: fixture.path("Projects"), store: temp.open())
        let loaded = try #require(await temp.open().restorableSnapshot())
        #expect(loaded.rescannedFolders == [fixture.path("Projects")])
        #expect(loaded.tree.node(at: "Projects/Beta/more.bin")?.logicalSize == 50_000)
        #expect(inventory(loaded.tree) == inventory(try fixture.scan().tree))
    }
}
