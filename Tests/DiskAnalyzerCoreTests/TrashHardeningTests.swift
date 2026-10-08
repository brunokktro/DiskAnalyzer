import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

// Follow-up to the adversarial review: the rules added to close D1 to D4, each with a
// positive control so a fix that refuses everything cannot pass.

private func write(_ path: String, bytes: Int) throws {
    try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

@Suite("Trash hardening: resolved paths and identity")
struct TrashResolutionTests {
    /// Control for D1/D2: scanning through an alias is legitimate, and ordinary items inside stay trashable.
    @Test func ordinaryItemUnderSymlinkedScanRootIsAccepted() throws {
        let real = try TemporaryFixture(build: false)
        try mkdir(real.path("old-builds"))
        let holder = try TemporaryFixture(build: false)
        let alias = holder.path("alias")
        #expect(symlink(real.rootPath, alias) == 0)
        let policy = TrashPolicy(scanRoot: alias, protectedPaths: TrashPolicy.defaultProtectedPaths(home: real.root))
        #expect(policy.validate(path: alias + "/old-builds", expectedDirectory: true) == nil)
        #expect(policy.validate(path: alias + "/Documents", expectedDirectory: true) == .missing)
    }

    @Test func pathThatNowNamesAnotherObjectIsRefused() throws {
        let fixture = try TemporaryFixture(build: false)
        try write(fixture.path("report.pdf"), bytes: 4_000)
        let tree = try fixture.scan().tree
        let item = Collector.Item(tree: tree, id: try #require(tree.id("report.pdf")))
        #expect(item.identity != nil)

        // Same name and type, different object (what a "safe save" or a rename swap does).
        try FileManager.default.removeItem(atPath: fixture.path("report.pdf"))
        try write(fixture.path("report.pdf"), bytes: 4_000)
        let mover = RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: []), mover: mover)
        guard case .refused(.replaced) = outcome[0].status else { Issue.record("expected .replaced, got \(outcome[0].status)"); return }
        #expect(mover.moved.isEmpty)
    }

    @Test func protectedFolderGivenThroughAnAliasIsStillProtected() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir(fixture.path("Keep"))
        let holder = try TemporaryFixture(build: false)
        #expect(symlink(fixture.path("Keep"), holder.path("keep-alias")) == 0)
        // The protected list names the folder only through an alias; the scan reaches it directly.
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: [holder.path("keep-alias")])
        #expect(policy.validate(path: fixture.path("Keep"), expectedDirectory: true) == .protectedLocation(fixture.path("Keep")))
    }

    @Test func symlinkIsValidatedAsItselfEvenWhenItPointsAtAProtectedFolder() throws {
        let fixture = try TemporaryFixture(build: false)
        let outside = try TemporaryFixture(build: false)
        #expect(symlink(outside.rootPath, fixture.path("shortcut")) == 0)
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: [outside.rootPath])
        // Moving the link moves the link; the protected target is untouched.
        #expect(policy.validate(path: fixture.path("shortcut"), expectedDirectory: false) == nil)
    }
}

@Suite("Collector: measurement and hard links")
struct CollectorMeasurementTests {
    @Test func unmeasuredFolderIsRefusedButItsParentIsTrashableWithAWarning() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir(fixture.path("parent/opaque"))
        try write(fixture.path("parent/opaque/weight.bin"), bytes: 1 << 20)
        try write(fixture.path("parent/visible.bin"), bytes: 10_000)
        chmod(fixture.path("parent/opaque"), 0o300)
        defer { chmod(fixture.path("parent/opaque"), 0o755) }
        let tree = try fixture.scan().tree

        var collector = Collector()
        let opaque = Collector.Item(tree: tree, id: try #require(tree.id("parent/opaque")))
        #expect(opaque.limitation == .notMeasured)
        #expect(collector.add(opaque) == .refused(.notMeasured))
        #expect(collector.isEmpty)

        let parent = Collector.Item(tree: tree, id: try #require(tree.id("parent")))
        #expect(parent.isTrashable)
        #expect(parent.unmeasuredFolders == 1)
        #expect(collector.add(parent) == .added(absorbed: 0))
        #expect(collector.unmeasuredFolders == 1)
    }

    @Test func hardLinkDuplicateInsideACollectedFolderIsNotCountedAgain() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir(fixture.path("a"))
        try mkdir(fixture.path("b"))
        try write(fixture.path("a/data.bin"), bytes: 1 << 20)
        #expect(link(fixture.path("a/data.bin"), fixture.path("b/data.bin")) == 0)
        let tree = try fixture.scan().tree
        let ids = [try #require(tree.id("a/data.bin")), try #require(tree.id("b/data.bin"))]
        let duplicate = try #require(ids.first { tree[$0].flags.contains(.hardLinkDuplicate) })
        let primary = try #require(ids.first { $0 != duplicate })
        let primaryFolder = tree[primary].parent

        var collector = Collector()
        collector.add(Collector.Item(tree: tree, id: primaryFolder))
        collector.add(Collector.Item(tree: tree, id: duplicate))
        #expect(collector.count == 2)
        #expect(collector.totalAllocated == tree[primaryFolder].allocatedSize)
        #expect(collector.totalLogical == tree[primaryFolder].logicalSize)
    }

    @Test func invalidNameAnywhereOnThePathBlocksCollection() {
        let tree = makeTree([("broken/", 0, 0), ("broken/inner.bin", 10, 4096), ("fine.bin", 10, 4096)],
                            flags: ["broken": .invalidName])
        let inner = tree.nodeID(forPath: "/fixture/broken/inner.bin")!
        let fine = tree.nodeID(forPath: "/fixture/fine.bin")!
        #expect(Collector.Item.limitation(of: inner, in: tree) == .invalidName)
        #expect(Collector.Item.limitation(of: fine, in: tree) == nil)
    }

    @Test func refusedItemsNeverReachTheMover() {
        let item = Collector.Item(path: "/x/opaque", name: "opaque", isDirectory: true, allocatedSize: 0, logicalSize: 0,
                                  itemCount: 0, limitation: .notMeasured)
        let mover = RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: "/x", protectedPaths: []), mover: mover)
        guard case .refused(.notMeasured) = outcome[0].status else { Issue.record("expected .notMeasured"); return }
        #expect(mover.moved.isEmpty)
    }
}

@Suite("Treemap and hard links")
struct TreemapHardLinkTests {
    @Test func duplicateGetsNoArea() {
        let tree = makeTree([("dir/", 0, 0), ("dir/original.bin", 1_000, 4096), ("dir/link.bin", 1_000, 4096), ("other.bin", 1_000, 4096)],
                            flags: ["dir/link.bin": .hardLinkDuplicate])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: TreemapRect(x: 0, y: 0, width: 400, height: 300), metric: .allocated)
        let duplicate = tree.nodeID(forPath: "/fixture/dir/link.bin")!
        let original = tree.nodeID(forPath: "/fixture/dir/original.bin")!
        #expect(!tiles.contains { $0.nodeID == duplicate })
        #expect(tiles.contains { $0.nodeID == original })
    }
}
