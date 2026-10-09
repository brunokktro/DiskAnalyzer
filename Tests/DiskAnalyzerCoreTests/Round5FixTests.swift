import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Fixes for the re-review (R5-1, R5-2). The reviewer's reproductions live in
/// `ReviewRound5Tests`; these cover the other side of each fix.
@Suite("Review 0.2.0: re-review fixes")
struct Round5FixTests {
    private static let gb: Int64 = 1_000_000_000

    private func baseline(used: Int64) -> VolumeBaseline {
        VolumeBaseline(capturedAt: Date(timeIntervalSince1970: 1_000), volumeUUID: "VOL", mountPath: "/", volumeName: "T",
                       totalCapacity: 1_000 * Self.gb, availableCapacity: 1_000 * Self.gb - used, availableForImportantUsage: nil)
    }

    // MARK: R5-1: buckets against the used space the results account for

    /// Both identities hold against `accountedUsed` for every combination of measured total and
    /// folder-rescan change, with no bucket negative and the measured total never reduced.
    @Test func bucketsAddUpToTheAccountedUsedSpace() {
        let used = 100 * Self.gb
        for measured in [0, 40 * Self.gb, 100 * Self.gb, 130 * Self.gb] {
            for change in [-150 * Self.gb, -20 * Self.gb, 0, 20 * Self.gb] {
                let tree = makeTree([("f", measured, measured)])
                var snapshot = syntheticSnapshot(tree, scope: .volume, start: baseline(used: used), end: baseline(used: used))
                snapshot.rescanAllocatedChange = change
                let rec = SpaceReconciliation(snapshot: snapshot, current: nil)
                let accounted = max(0, used + change)
                #expect(rec.used == used)
                #expect(rec.accountedUsed == accounted)
                guard let attributed = rec.attributed, let unattributed = rec.unattributed, let beyond = rec.measuredBeyondUsed else {
                    Issue.record("no volume buckets for measured \(measured) change \(change)")
                    continue
                }
                #expect(attributed >= 0 && unattributed >= 0 && beyond >= 0)
                #expect(attributed + unattributed == accounted, "measured \(measured) change \(change)")
                #expect(attributed + beyond == measured, "measured \(measured) change \(change)")
            }
        }
    }

    /// Without folder rescans the accounted used space is the volume's used space, so the
    /// buckets are what they were before the fix.
    @Test func withoutFolderRescansTheAccountedUsedIsTheUsedSpace() {
        let tree = makeTree([("f", 90 * Self.gb, 90 * Self.gb)])
        let snapshot = syntheticSnapshot(tree, scope: .volume, start: baseline(used: 100 * Self.gb), end: baseline(used: 100 * Self.gb))
        let rec = SpaceReconciliation(snapshot: snapshot, current: baseline(used: 100 * Self.gb))
        #expect(rec.accountedUsed == rec.used)
        #expect(rec.unattributed == 10 * Self.gb)
        #expect(rec.freshness == .unchanged(delta: 0))
    }

    /// A folder scan never gets volume buckets, whatever the rescans changed.
    @Test func aFolderScanStillHasNoVolumeBuckets() {
        let tree = makeTree([("f", 10, 4096)])
        var snapshot = syntheticSnapshot(tree, scope: .folder, start: baseline(used: 100 * Self.gb), end: baseline(used: 100 * Self.gb))
        snapshot.rescanAllocatedChange = 5 * Self.gb
        let rec = SpaceReconciliation(snapshot: snapshot, current: nil)
        #expect(rec.attributed == nil && rec.unattributed == nil && rec.measuredBeyondUsed == nil)
        #expect(!rec.comparesWithVolume)
    }

    // MARK: R5-2: link inodes recorded, carried and saved

    private func linkedFixture() throws -> TemporaryFixture {
        let fixture = try TemporaryFixture(build: false)
        let fm = FileManager.default
        for folder in ["A", "B"] { try fm.createDirectory(atPath: fixture.path(folder), withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: fixture.path("A/single.txt")))
        try Data(repeating: 2, count: 64 * 1024).write(to: URL(fileURLWithPath: fixture.path("A/x")))
        try fm.linkItem(atPath: fixture.path("A/x"), toPath: fixture.path("B/y"))
        return fixture
    }

    /// The scanner records the inode of every multiply-linked file and only those.
    @Test func theScannerRecordsTheInodeOfMultiplyLinkedFilesOnly() throws {
        let fixture = try linkedFixture()
        let tree = try fixture.scan().tree
        let x = try #require(tree.id("A/x")), y = try #require(tree.id("B/y")), single = try #require(tree.id("A/single.txt"))
        #expect(tree.linkInodes.count == 2)
        #expect(tree.linkInodes[x] == FileIdentity.ofEntry(atPath: fixture.path("A/x"))?.inode)
        #expect(tree.linkInodes[x] == tree.linkInodes[y])
        #expect(tree.linkInodes[single] == nil)
    }

    /// The codec and a folder rescan keep every recorded inode on the node it belongs to, so a
    /// restored snapshot settles links as the one that was scanned.
    @Test func linkInodesSurviveTheCodecAndAFolderRescan() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        let inode = try #require(FileIdentity.ofEntry(atPath: fixture.path("A/x"))?.inode)

        let decoded = try TreeCodec.decode(TreeCodec.encode(full.tree))
        #expect(decoded.linkInodes[try #require(decoded.id("B/y"))] == inode)
        #expect(decoded.linkInodes[try #require(decoded.id("A/x"))] == inode)

        for folder in ["A", "B"] {
            let updated = try await SubtreeRescan.run(full, folder: fixture.path(folder))
            #expect(updated.tree.linkInodes.count == 2, "after rescanning \(folder)")
            #expect(updated.tree.linkInodes[try #require(updated.tree.id("A/x"))] == inode)
            #expect(updated.tree.linkInodes[try #require(updated.tree.id("B/y"))] == inode)
        }
    }

    /// The F3 direction still holds with the stricter rule: the counted link was inside the
    /// rescanned folder and was deleted, so the duplicate outside takes the count.
    @Test func theDuplicateOutsideIsCountedWhenItsCountedLinkWasInsideTheFolder() async throws {
        let fixture = try linkedFixture()
        let full = try snapshot(of: fixture.scan())
        #expect(full.tree.node(at: "A/x")?.flags.contains(.hardLinkDuplicate) == false)
        #expect(full.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == true)
        try FileManager.default.removeItem(atPath: fixture.path("A/x"))

        let updated = try await SubtreeRescan.run(full, folder: fixture.path("A"))
        let fresh = try fixture.scan()
        #expect(updated.tree.node(at: "B/y")?.flags.contains(.hardLinkDuplicate) == false)
        #expect(updated.tree.root.allocatedSize == fresh.tree.root.allocatedSize)
        #expect(updated.tree.root.itemCount == fresh.tree.root.itemCount)
    }

    /// A damaged inode list throws instead of naming a folder, a node twice or a node past the end.
    @Test func aDamagedLinkInodeListIsRejected() throws {
        let tree = makeTree([("d/", 0, 0), ("d/f", 10, 4096), ("g", 10, 4096)])
        let file = try #require(tree.nodeID(forPath: "/fixture/d/f"))
        let folder = try #require(tree.nodeID(forPath: "/fixture/d"))
        for bad: [NodeID: UInt64] in [[folder: 7], [FileTree.rootID: 7], [NodeID(tree.count): 7]] {
            let edited = FileTree(rootPath: tree.rootPath, nodes: tree.nodes, childIndex: tree.childIndex, linkInodes: bad)
            #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(TreeCodec.encode(edited)) }
        }
        // Same id twice: patch the second entry's id to the first one's in the encoded bytes.
        let other = try #require(tree.nodeID(forPath: "/fixture/g"))
        let both = FileTree(rootPath: tree.rootPath, nodes: tree.nodes, childIndex: tree.childIndex,
                            linkInodes: [min(file, other): 1, max(file, other): 2])
        var data = TreeCodec.encode(both)
        let first = min(file, other).littleEndian
        withUnsafeBytes(of: first) { data.replaceSubrange((data.count - 12)..<(data.count - 8), with: $0) }
        #expect(throws: TreeCodec.DecodeError.self) { try TreeCodec.decode(data) }
        // And the valid list round-trips.
        #expect(try TreeCodec.decode(TreeCodec.encode(both)).linkInodes == both.linkInodes)
    }
}
