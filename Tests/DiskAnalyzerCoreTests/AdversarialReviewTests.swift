import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

// Adversarial review tests (fariseu-qa, 2026-10-08).
//
// Every fixture here is built by hand, independently of `FixtureBuilder`, so the scanner is
// checked against data its author did not shape. Expectations come from a second source
// (`du(1)`, `FileManager`'s enumerator, `lstat`), never from the scanner itself.
//
// Tests tagged `.reviewDefect` describe a contract the implementation does not meet yet.
// They are expected to FAIL until the defect is fixed; do not weaken them to make them pass.

extension Tag {
    @Tag static var reviewDefect: Self
}

private func write(_ path: String, bytes: Int) throws {
    try Data(repeating: 0x5A, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// Allocated and logical bytes below `root`, computed with FileManager's enumerator (not fts),
/// counting each inode once and never following symlinks.
private func independentTotals(_ root: String) -> (allocated: Int64, logical: Int64) {
    var seen = Set<[UInt64]>()
    var allocated: Int64 = 0, logical: Int64 = 0
    func add(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) != S_IFDIR, info.st_nlink > 1 {
            guard seen.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted else { return }
        }
        allocated += Int64(info.st_blocks) * 512
        if (info.st_mode & S_IFMT) != S_IFDIR { logical += Int64(info.st_size) }
    }
    add(root)
    let enumerator = FileManager.default.enumerator(atPath: root)
    while let relative = enumerator?.nextObject() as? String { add(root + "/" + relative) }
    return (allocated, logical)
}

@Suite("Adversarial: scanner against independent sources")
struct AdversarialScannerTests {
    @Test func handBuiltTreeAgreesWithDuAndEnumerator() throws {
        let fixture = try TemporaryFixture(build: false)
        let root = fixture.rootPath
        let outside = try TemporaryFixture(build: false)
        try write(outside.path("big-outside.bin"), bytes: 4 << 20)

        try mkdir(root + "/a/deep/er")
        try mkdir(root + "/b")
        try write(root + "/a/deep/er/file.bin", bytes: 300_000)
        try write(root + "/a/one.bin", bytes: 70_001)
        #expect(link(root + "/a/one.bin", root + "/b/one-link.bin") == 0)
        #expect(link(root + "/a/one.bin", root + "/b/one-link-2.bin") == 0)
        // Sparse: 1 GiB logical, a single block allocated.
        let sparse = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: root + "/sparse.img", contents: nil); return root + "/sparse.img" }())!
        try sparse.seek(toOffset: 1 << 30)
        try sparse.write(contentsOf: Data([1]))
        try sparse.close()
        // Links that must never be followed: to a big folder outside, to "/", and a loop.
        #expect(symlink(outside.rootPath, root + "/to-outside") == 0)
        #expect(symlink("/", root + "/to-root") == 0)
        #expect(symlink(root + "/loop-b", root + "/loop-a") == 0)
        #expect(symlink(root + "/loop-a", root + "/loop-b") == 0)
        #expect(mkfifo(root + "/pipe", 0o644) == 0)

        let result = try fixture.scan()
        let tree = result.tree
        let expected = independentTotals(root)

        #expect(tree.root.allocatedSize == expected.allocated, "scanner vs enumerator, allocated")
        #expect(tree.root.logicalSize == expected.logical, "scanner vs enumerator, logical")
        let du = try run("/usr/bin/du", ["-s", "-k", "-x", root])
        let duKiB = Int64(du.split(separator: "\t").first.map(String.init) ?? "") ?? -1
        #expect(tree.root.allocatedSize == duKiB * 1024, "scanner vs du -skx")

        let sparseNode = try #require(tree.node(at: "sparse.img"))
        #expect(sparseNode.logicalSize == (1 << 30) + 1)
        #expect(sparseNode.allocatedSize < 1 << 20, "sparse file must not report its logical size as allocated")
        #expect(result.statistics.hardLinkDuplicates == 2)
        #expect(tree.node(at: "to-outside")?.kind == .symlink)
        #expect(tree.node(at: "to-outside/big-outside.bin") == nil, "symlink target must not be entered")
        #expect(tree.root.allocatedSize < 4 << 20, "outside folder must not be counted")
        #expect(tree.node(at: "pipe")?.kind == .other)
        #expect(result.failureCount == 0)
    }

    /// Invariant on a real scan: every directory == its own blocks + its counted children.
    @Test func everyDirectoryEqualsOwnBlocksPlusCountedChildren() throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let tree = try fixture.scan().tree
        for index in 0..<tree.count {
            let id = NodeID(index)
            let node = tree[id]
            guard node.isDirectory else { continue }
            let kids = tree.children(of: id).map { tree[$0] }.filter { !$0.flags.contains(.hardLinkDuplicate) }
            let own = allocatedBytes(tree.path(of: id))
            #expect(node.allocatedSize == own + kids.reduce(0) { $0 + $1.allocatedSize }, "\(tree.path(of: id))")
            #expect(node.itemCount == kids.reduce(0) { $0 + $1.itemCount })
        }
    }

    @Test func folderWithoutSearchPermissionReportsEveryChild() throws {
        let fixture = try TemporaryFixture(build: false)
        let dir = fixture.path("listable-not-searchable")
        try mkdir(dir)
        for index in 0..<5 { try write(dir + "/f\(index)", bytes: 10_000) }
        chmod(dir, 0o444) // names can be listed, metadata cannot be read
        defer { chmod(dir, 0o755) }
        let result = try fixture.scan()
        #expect(result.failureCount >= 1)
        #expect(result.tree.root.allocatedSize < 50_000, "unmeasurable children must not be invented")
    }

    @Test func cancellationCutsALargeWalkShort() async throws {
        let fixture = try TemporaryFixture(build: false)
        for folder in 0..<40 {
            let dir = fixture.path("d\(folder)")
            try mkdir(dir)
            for file in 0..<500 { FileManager.default.createFile(atPath: dir + "/f\(file)", contents: nil) }
        }
        let full = try fixture.scan()
        #expect(full.tree.root.itemCount == 20_000)

        // Cancel from inside the walk, once it is well under way, and measure how far it got.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<ScanResult, Error>?
            var lastSeen = 0
        }
        let box = Box()
        let task = Task {
            try await DiskScanner().scan(ScanOptions(root: fixture.root, progressInterval: .zero)) { progress in
                box.lock.withLock {
                    box.lastSeen = progress.entriesVisited
                    if progress.entriesVisited >= 2_000 { box.task?.cancel() }
                }
            }
        }
        box.lock.withLock { box.task = task }
        do {
            _ = try await task.value
            Issue.record("a scan cancelled mid-walk returned a result")
        } catch is CancellationError {
            let seen = box.lock.withLock { box.lastSeen }
            #expect(seen >= 2_000 && seen < 2_000 + 1_024, "stopped at \(seen) entries")
        }
    }

    /// A real second volume mounted inside the scanned folder: not entered, not trashable.
    @Test func mountedVolumeIsNotEnteredAndCannotBeTrashed() throws {
        let fixture = try TemporaryFixture(build: false)
        let image = fixture.path("vol.dmg"), mount = fixture.path("mnt")
        try mkdir(mount)
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "HFS+", "-volname", "DAReview", "-quiet", image])
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-mountpoint", mount, "-quiet", image])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"]) }
        var parentInfo = stat(), mountInfo = stat()
        guard lstat(fixture.rootPath, &parentInfo) == 0, lstat(mount, &mountInfo) == 0, parentInfo.st_dev != mountInfo.st_dev else {
            Issue.record("could not attach a disk image (hdiutil unavailable here)")
            return
        }
        try write(mount + "/inside.bin", bytes: 2 << 20)
        let result = try fixture.scan { $0.staysOnVolume = true }
        #expect(result.issueCounts[.otherVolume] == 1)
        #expect(result.tree.node(at: "mnt/inside.bin") == nil)
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: [])
        #expect(policy.validate(path: mount, expectedDirectory: true) == .volumeRoot)
    }
}

@Suite("Adversarial: Trash and Collector contracts")
struct AdversarialTrashTests {
    /// Defect: the scan-root check is lexical. If a folder inside the scan is replaced by a
    /// symlink after the scan, the re-validation passes and the move lands outside the scan root.
    @Test(.tags(.reviewDefect)) func revalidationRefusesPathThatNowResolvesOutsideScanRoot() throws {
        let fixture = try TemporaryFixture(build: false)
        let victim = try TemporaryFixture(build: false)
        try mkdir(victim.path("precious"))
        try write(victim.path("precious/thesis.docx"), bytes: 1_000)
        try mkdir(fixture.path("cache/precious"))
        let tree = try fixture.scan().tree
        let item = Collector.Item(tree: tree, id: try #require(tree.id("cache/precious")))

        // After the scan, "cache" becomes a link to another folder that has the same layout.
        try FileManager.default.moveItem(atPath: fixture.path("cache"), toPath: fixture.path("cache-old"))
        #expect(symlink(victim.rootPath, fixture.path("cache")) == 0)

        let mover = RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: []), mover: mover)
        #expect(!outcome[0].succeeded, "would move \(victim.path("precious")), outside the scanned folder")
        #expect(mover.moved.isEmpty)
    }

    /// Defect: protection compares strings, so an alias of a protected folder is not protected.
    @Test(.tags(.reviewDefect)) func protectedFolderReachedThroughSymlinkedScanRootIsRefused() throws {
        let fakeHome = try TemporaryFixture(build: false)
        try mkdir(fakeHome.path("Documents"))
        let holder = try TemporaryFixture(build: false)
        let alias = holder.path("home-alias")
        #expect(symlink(fakeHome.rootPath, alias) == 0)
        let policy = TrashPolicy(scanRoot: alias, protectedPaths: TrashPolicy.defaultProtectedPaths(home: fakeHome.root))
        #expect(policy.validate(path: alias + "/Documents", expectedDirectory: true) != nil,
                "the account's Documents folder must stay protected when reached through an alias")
    }

    /// Defect: two paths of one inode are both summed, although the README promises that
    /// nothing in the Collector counts twice and the scan itself counts the inode once.
    @Test(.tags(.reviewDefect)) func collectorCountsAHardLinkedInodeOnce() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir(fixture.path("a"))
        try mkdir(fixture.path("b"))
        try write(fixture.path("a/data.bin"), bytes: 1 << 20)
        #expect(link(fixture.path("a/data.bin"), fixture.path("b/data-link.bin")) == 0)
        let tree = try fixture.scan().tree
        var collector = Collector()
        collector.add(Collector.Item(tree: tree, id: try #require(tree.id("a/data.bin"))))
        collector.add(Collector.Item(tree: tree, id: try #require(tree.id("b/data-link.bin"))))
        #expect(collector.totalAllocated == allocatedBytes(fixture.path("a/data.bin")),
                "Collector shows \(collector.totalAllocated) for one inode of \(allocatedBytes(fixture.path("a/data.bin")))")
    }

    /// Defect: a folder the scan could not list is shown as 0 bytes / 0 items, and the Trash
    /// policy lets it through, so the confirmation dialog understates what is moved.
    @Test(.tags(.reviewDefect)) func unmeasuredFolderIsNotTrashedAsIfItWereEmpty() throws {
        let fixture = try TemporaryFixture(build: false)
        let opaque = fixture.path("opaque")
        try mkdir(opaque)
        try write(opaque + "/hidden-weight.bin", bytes: 3 << 20)
        chmod(opaque, 0o300) // writable and searchable, not listable
        defer { chmod(opaque, 0o755) }
        let tree = try fixture.scan().tree
        let id = try #require(tree.id("opaque"))
        #expect(tree[id].flags.contains(.unreadable))
        let item = Collector.Item(tree: tree, id: id)
        #expect(item.itemCount == 0) // what the confirmation dialog is based on

        let mover = RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: []), mover: mover)
        #expect(!outcome[0].succeeded, "an unmeasured folder (3 MB inside) would be trashed as an empty one")
    }

    /// Control for the defects above: the same flows on a clean tree must still succeed.
    @Test func controlCleanFolderIsAccepted() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir(fixture.path("cache/precious"))
        try write(fixture.path("cache/precious/x.bin"), bytes: 1_000)
        let tree = try fixture.scan().tree
        let item = Collector.Item(tree: tree, id: try #require(tree.id("cache/precious")))
        let mover = RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: []), mover: mover)
        #expect(outcome[0].succeeded)
        #expect(mover.moved == [fixture.path("cache/precious")])
        #expect(FileManager.default.fileExists(atPath: fixture.path("cache/precious/x.bin")))
    }
}
