import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

// Adversarial review, round 2 (fariseu-qa, 2026-10-08).
//
// Expectations come from a second source (lstat, a hand-written walker, the real
// `FileManager.trashItem` on a throwaway disk image), never from the code under test.
// Tests tagged `.reviewDefect` describe a contract the implementation does not meet yet:
// they are expected to FAIL until the defect is fixed. Do not weaken them to make them pass.

private func r2Write(_ path: String, bytes: Int) throws {
    try Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
}

private func r2Mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private final class R2RecordingMover: TrashMover, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var moved: [String] { lock.withLock { paths } }
    func moveToTrash(_ url: URL) throws -> URL? {
        lock.withLock { paths.append(url.path(percentEncoded: false)) }
        return nil
    }
}

@Suite("Review round 2: counting across firmlinks")
struct ReviewFirmlinkTests {
    /// Logical bytes below `root` with every object counted once by `(st_dev, st_ino)`,
    /// directories included, staying on `device` and skipping `excluded`. Independent of fts.
    private static func logicalOnce(_ root: String, device: dev_t, excluded: Set<String>) -> Int64 {
        var seen = Set<FileIdentity>()
        var total: Int64 = 0
        func visit(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, seen.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted else { return }
            if (info.st_mode & S_IFMT) != S_IFDIR { total += Int64(info.st_size); return }
            guard info.st_dev == device, !excluded.contains(path) else { return }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                visit(path == "/" ? "/" + name : path + "/" + name)
            }
        }
        visit(root)
        return total
    }

    /// Defect: on the APFS volume group (macOS 11+) the firmlinks `/Users`, `/Applications`,
    /// `/Library`... and `/System/Volumes/Data/...` are the SAME objects with the SAME `st_dev`,
    /// so "Stay on One Volume" does not separate them and a scan of `/` (what the Open panel
    /// returns for "Macintosh HD") counts the whole Data volume twice. The walk is cut down to
    /// `/Users/Shared` and its firmlinked twin with exclusions so the test stays small.
    @Test(.tags(.reviewDefect)) func scanningTheSystemRootCountsFirmlinkedDataOnce() throws {
        let data = "/System/Volumes/Data"
        var root = stat(), dataInfo = stat()
        guard lstat("/", &root) == 0, lstat(data, &dataInfo) == 0, root.st_dev == dataInfo.st_dev,
              let users = FileIdentity.ofEntry(atPath: "/Users"), users == FileIdentity.ofEntry(atPath: data + "/Users"),
              FileManager.default.fileExists(atPath: "/Users/Shared") else {
            return // Not the shared-device volume group layout; nothing to check on this Mac.
        }
        let keep: Set<String> = ["/System", "/System/Volumes", data, "/Users", data + "/Users", "/Users/Shared", data + "/Users/Shared"]
        var excluded = Set<String>()
        for dir in ["/", "/System", "/System/Volumes", data, "/Users", data + "/Users"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir == "/" ? "/" + name : dir + "/" + name
                if !keep.contains(path) { excluded.insert(path) }
            }
        }
        let result = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: "/"), staysOnVolume: true, excludedPaths: excluded))
        let tree = result.tree
        let expected = Self.logicalOnce("/", device: root.st_dev, excluded: excluded)
        let shared = tree.nodeID(forPath: "/Users/Shared").map { tree[$0].logicalSize } ?? -1
        let twin = tree.nodeID(forPath: data + "/Users/Shared").map { tree[$0].logicalSize } ?? -1
        #expect(tree.root.logicalSize == expected,
                "scan of / reports \(tree.root.logicalSize) logical bytes, each object once is \(expected) (/Users/Shared \(shared), its firmlinked twin \(twin))")
    }
}

@Suite("Review round 2: Trash policy containment")
struct ReviewTrashContainmentTests {
    /// Defect: only an exact protected path is refused. A folder that CONTAINS a protected
    /// folder passes, so moving it takes the protected folder with it. Real cases on a generic
    /// Mac: a relocated or network home (the account home lives below an unprotected folder),
    /// and the running app inside an unzipped release folder in Downloads.
    @Test(.tags(.reviewDefect)) func folderThatContainsAProtectedFolderIsRefused() throws {
        let fixture = try TemporaryFixture(build: false)
        try r2Mkdir(fixture.path("homes/alice/Documents"))
        try r2Mkdir(fixture.path("release/Disk Analyzer.app/Contents"))
        let home = URL(fileURLWithPath: fixture.path("homes/alice"), isDirectory: true)
        let protected = TrashPolicy.defaultProtectedPaths(home: home).union([fixture.path("release/Disk Analyzer.app")])
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: protected)

        // Controls: the protected folders themselves are refused, an unrelated folder is not.
        #expect(policy.validate(path: fixture.path("homes/alice"), expectedDirectory: true) != nil)
        #expect(policy.validate(path: fixture.path("release/Disk Analyzer.app"), expectedDirectory: true) != nil)
        try r2Mkdir(fixture.path("other"))
        #expect(policy.validate(path: fixture.path("other"), expectedDirectory: true) == nil)

        #expect(policy.validate(path: fixture.path("homes"), expectedDirectory: true) != nil,
                "moving 'homes' to the Trash moves the account home folder with it")
        #expect(policy.validate(path: fixture.path("release"), expectedDirectory: true) != nil,
                "moving 'release' to the Trash moves the running app with it")
    }
}

@Suite("Review round 2: real Trash on a throwaway disk image")
struct ReviewRealTrashTests {
    /// The policy validates a symbolic link as itself. This checks the other side of that
    /// contract with the REAL mover: `FileManager.trashItem` must move the link, never its target.
    /// Everything lives on a disk image, so the system puts it in that volume's `.Trashes`,
    /// not in the user's Trash, and detaching the image removes it.
    @Test func realTrashMovesLinksAndFilesAndNeverTheLinkTarget() throws {
        let fixture = try TemporaryFixture(build: false)
        let image = fixture.path("trash.dmg"), mount = fixture.path("mnt")
        try r2Mkdir(mount)
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "APFS", "-volname", "DAReviewTrash", "-quiet", image])
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-mountpoint", mount, "-quiet", image])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"]) }
        var parentInfo = stat(), mountInfo = stat()
        guard lstat(fixture.rootPath, &parentInfo) == 0, lstat(mount, &mountInfo) == 0, parentInfo.st_dev != mountInfo.st_dev else {
            Issue.record("could not attach a disk image (hdiutil unavailable here)")
            return
        }
        try r2Mkdir(mount + "/target")
        try r2Write(mount + "/target/keep.bin", bytes: 64 << 10)
        try r2Write(mount + "/plain.bin", bytes: 128 << 10)
        #expect(symlink(mount + "/target", mount + "/link-to-target") == 0)
        try r2Mkdir(mount + "/folder/sub")
        try r2Write(mount + "/folder/sub/x.bin", bytes: 32 << 10)

        let tree = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: mount, isDirectory: true))).tree
        let items = try ["link-to-target", "plain.bin", "folder"].map { name in
            Collector.Item(tree: tree, id: try #require(tree.nodeID(forPath: mount + "/" + name)))
        }
        let outcomes = TrashOperation.run(items, policy: TrashPolicy(scanRoot: mount), mover: SystemTrashMover())

        let volumeTrash = (PathUtilities.resolved(mount) ?? mount) + "/.Trashes/"
        for outcome in outcomes {
            #expect(outcome.succeeded, "\(outcome.path): \(outcome.status)")
            if case .moved(let destination?) = outcome.status {
                #expect(PathUtilities.standardize(destination.path(percentEncoded: false)).hasPrefix(volumeTrash),
                        "\(outcome.path) went to \(destination.path(percentEncoded: false)), not this volume's Trash")
            }
        }
        var info = stat()
        #expect(lstat(mount + "/link-to-target", &info) != 0, "the link was not moved")
        #expect(FileManager.default.fileExists(atPath: mount + "/target/keep.bin"), "the link TARGET was moved")
        #expect(!FileManager.default.fileExists(atPath: mount + "/plain.bin"))
        #expect(!FileManager.default.fileExists(atPath: mount + "/folder"))
    }

    /// A folder replaced by a link to a folder OUTSIDE the scan after collection is refused
    /// with the real mover too (control for the round-1 fix, end to end).
    @Test func realTrashRefusesAFolderSwappedForALinkAfterCollection() throws {
        let fixture = try TemporaryFixture(build: false)
        try r2Mkdir(fixture.path("scan/cache"))
        try r2Mkdir(fixture.path("outside/cache"))
        try r2Write(fixture.path("outside/cache/thesis.docx"), bytes: 4_096)
        let root = fixture.path("scan")
        let tree = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: root, isDirectory: true))).tree
        let item = Collector.Item(tree: tree, id: try #require(tree.nodeID(forPath: root + "/cache")))
        try FileManager.default.removeItem(atPath: root + "/cache")
        #expect(symlink(fixture.path("outside/cache"), root + "/cache") == 0)
        let mover = R2RecordingMover()
        let outcome = TrashOperation.run([item], policy: TrashPolicy(scanRoot: root, protectedPaths: []), mover: mover)
        #expect(!outcome[0].succeeded)
        #expect(mover.moved.isEmpty)
    }
}
