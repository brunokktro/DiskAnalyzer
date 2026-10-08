import Foundation
import Testing
@testable import DiskAnalyzerCore

@Suite("Collector")
struct CollectorTests {
    private func item(_ path: String, _ size: Int64, directory: Bool = false) -> Collector.Item {
        Collector.Item(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                       allocatedSize: size, logicalSize: size * 2, itemCount: 1)
    }

    @Test func addingAncestorAbsorbsDescendants() {
        var collector = Collector()
        collector.add(item("/r/a/one", 10))
        collector.add(item("/r/a/two", 20))
        collector.add(item("/r/b", 5))
        let outcome = collector.add(item("/r/a", 100, directory: true))
        #expect(outcome == .added(absorbed: 2))
        #expect(collector.items.map(\.path).sorted() == ["/r/a", "/r/b"])
        #expect(collector.totalAllocated == 105)
        #expect(collector.total(.logical) == 210)
    }

    @Test func addingDescendantOfCollectedFolderIsNoop() {
        var collector = Collector()
        collector.add(item("/r/a", 100, directory: true))
        let inner = collector.add(item("/r/a/inner", 10))
        let again = collector.add(item("/r/a", 100, directory: true))
        #expect(inner == .alreadyCovered(by: "/r/a"))
        #expect(again == .alreadyCovered(by: "/r/a"))
        #expect(collector.count == 1)
    }

    @Test func siblingWithSharedPrefixIsNotCovered() {
        var collector = Collector()
        collector.add(item("/r/app", 1, directory: true))
        let outcome = collector.add(item("/r/apple", 2))
        #expect(outcome == .added(absorbed: 0))
        #expect(collector.count == 2)
    }

    @Test func removeAndSort() {
        var collector = Collector()
        collector.add(item("/r/small", 1))
        collector.add(item("/r/large", 9))
        #expect(collector.sorted(by: .allocated).map(\.name) == ["large", "small"])
        let first = collector.remove(path: "/r/large/")
        let second = collector.remove(path: "/r/large")
        #expect(first)
        #expect(!second)
        #expect(collector.contains(path: "/r/small"))
        collector.removeAll()
        #expect(collector.isEmpty)
    }

    @Test func itemFromTreeDetectsHardLinks() throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let tree = try fixture.scan().tree
        let linked = Collector.Item(tree: tree, id: try #require(tree.id("Projects/Beta/shared.bin")))
        let plain = Collector.Item(tree: tree, id: try #require(tree.id("Media/movie.mov")))
        #expect(linked.hasOtherHardLinks)
        #expect(!plain.hasOtherHardLinks)
        #expect(plain.allocatedSize == allocatedBytes(fixture.path("Media/movie.mov")))
    }
}

@Suite("Trash policy")
struct TrashPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    @Test func protectsSystemAndAccountFolders() {
        let policy = TrashPolicy(scanRoot: "/", protectedPaths: TrashPolicy.defaultProtectedPaths(home: home))
        for path in ["/System", "/Applications", "/Users", "/Users/example", "/Users/example/Library", "/Users/example/Documents",
                     "/System/Volumes/Data/Users/example", "/System/Library/Fonts", "/Library"] {
            #expect(policy.validatePath(path) != nil, "\(path)")
        }
        #expect(policy.validatePath("/Users/example/Documents/old.zip") == nil)
        #expect(policy.validatePath("/System/Volumes/Data/Users/example/Downloads/x.dmg") == nil)
        #expect(policy.validatePath("/") == .scanRoot)
    }

    @Test func refusesOutsideScanRootAndRootItself() {
        let policy = TrashPolicy(scanRoot: "/data/scan", protectedPaths: [])
        #expect(policy.validatePath("/data/scan") == .scanRoot)
        #expect(policy.validatePath("/data/scan/") == .scanRoot)
        #expect(policy.validatePath("/data/scanner/file") == .outsideScanRoot)
        #expect(policy.validatePath("/data/scan/../other") == .outsideScanRoot)
        #expect(policy.validatePath("/data/scan/sub/file") == nil)
    }

    @Test func liveValidationChecksExistenceAndType() throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: [])
        #expect(policy.validate(path: fixture.path("Media/movie.mov"), expectedDirectory: false) == nil)
        #expect(policy.validate(path: fixture.path("Media"), expectedDirectory: true) == nil)
        #expect(policy.validate(path: fixture.path("Media"), expectedDirectory: false) == .changedType)
        #expect(policy.validate(path: fixture.path("missing.bin"), expectedDirectory: false) == .missing)
        // A symlink is validated as itself, never through its target.
        #expect(policy.validate(path: fixture.path("dangling-link"), expectedDirectory: false) == nil)
    }

    @Test func operationRunsEachItemIndependently() throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let policy = TrashPolicy(scanRoot: fixture.rootPath, protectedPaths: [fixture.path("Projects")])
        let mover = RecordingMover(failing: [fixture.path("Archive.zip")])
        let items = [
            Collector.Item(path: fixture.path("Media/movie.mov"), name: "movie.mov", isDirectory: false, allocatedSize: 1, logicalSize: 1, itemCount: 1),
            Collector.Item(path: fixture.path("Projects"), name: "Projects", isDirectory: true, allocatedSize: 1, logicalSize: 1, itemCount: 1),
            Collector.Item(path: fixture.path("Archive.zip"), name: "Archive.zip", isDirectory: false, allocatedSize: 1, logicalSize: 1, itemCount: 1),
            Collector.Item(path: fixture.path("gone.bin"), name: "gone.bin", isDirectory: false, allocatedSize: 1, logicalSize: 1, itemCount: 1),
        ]
        let outcomes = TrashOperation.run(items, policy: policy, mover: mover)
        #expect(outcomes.map(\.succeeded) == [true, false, false, false])
        #expect(mover.moved == [fixture.path("Media/movie.mov"), fixture.path("Archive.zip")])
        guard case .refused(.protectedLocation) = outcomes[1].status else { Issue.record("expected refusal"); return }
        guard case .failed = outcomes[2].status else { Issue.record("expected failure"); return }
        guard case .refused(.missing) = outcomes[3].status else { Issue.record("expected missing"); return }
        // The fake mover never touches the disk.
        #expect(FileManager.default.fileExists(atPath: fixture.path("Media/movie.mov")))
    }

    @Test func refusalsHaveMessages() {
        let all: [TrashPolicy.Refusal] = [.protectedLocation("/x"), .scanRoot, .outsideScanRoot, .missing, .changedType, .volumeRoot, .replaced, .notMeasured]
        #expect(all.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }
}

final class RecordingMover: TrashMover, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    var moved: [String] { lock.withLock { paths } }

    func moveToTrash(_ url: URL) throws -> URL? {
        let path = PathUtilities.standardize(url.path(percentEncoded: false))
        lock.withLock { paths.append(path) }
        if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        return URL(fileURLWithPath: "/trash/" + url.lastPathComponent)
    }
}

@Suite("Volumes, formatting and export")
struct SupportTests {
    @Test func homeVolumeContainsHome() throws {
        let volume = try #require(VolumeLocator.homeVolume())
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let mount = try #require(VolumeLocator.mountPoint(of: home))
        #expect(volume.mountPath == mount.mountPath)
        #expect(!volume.name.isEmpty)
        #expect((volume.totalCapacity ?? 0) > 0)
        #expect(VolumeLocator.scannableVolumes().contains { $0.id == volume.id })
    }

    @Test func rootMapsToDataVolumeWhenPresent() {
        let mapped = VolumeLocator.dataVolumePath(forMount: "/")
        if VolumeLocator.mountPoint(of: "/System/Volumes/Data")?.mountPath == "/System/Volumes/Data" {
            #expect(mapped == "/System/Volumes/Data")
        } else {
            #expect(mapped == "/")
        }
        #expect(VolumeLocator.dataVolumePath(forMount: "/Volumes/External") == "/Volumes/External")
    }

    @Test func standardizePaths() {
        #expect(PathUtilities.standardize("/a/b/") == "/a/b")
        #expect(PathUtilities.standardize("/a//b/./c/..") == "/a/b")
        #expect(PathUtilities.standardize("/") == "/")
        #expect(PathUtilities.isSameOrDescendant("/a/b", of: "/a"))
        #expect(!PathUtilities.isSameOrDescendant("/ab", of: "/a"))
        #expect(PathUtilities.isSameOrDescendant("/x", of: "/"))
    }

    @Test func csvEscapesAndNeutralizesFormulas() {
        #expect(CSVExport.field("plain") == "plain")
        #expect(CSVExport.field("a,b") == "\"a,b\"")
        #expect(CSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExport.field("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(CSVExport.field("-1") == "'-1")
        #expect(CSVExport.field("line\nbreak") == "\"line\nbreak\"")
        let csv = CSVExport.render(header: ["a", "b"], rows: [["1", "2"]])
        #expect(csv == "a,b\r\n1,2\r\n")
    }

    @Test func csvExportsIssuesAndItems() throws {
        let fixture = try TemporaryFixture()
        let result = try fixture.scan()
        let issues = CSVExport.issues(result.issues)
        #expect(issues.hasPrefix("kind,path,errno,message\r\n"))
        #expect(issues.contains("permissionDenied"))
        let top = TreeQueries.largestItems(in: result.tree, query: LargestItemsQuery(limit: 3))
        let items = CSVExport.items(top, in: result.tree)
        #expect(items.split(separator: "\r\n").count == 4)
        #expect(items.contains("movie.mov"))
    }

    @Test func formatting() {
        #expect(SizeFormatting.percent(1, of: 0) == "-")
        #expect(SizeFormatting.percent(1, of: 10_000) == "<0.1%")
        #expect(SizeFormatting.percent(50, of: 100) == "50.0%")
        #expect(!SizeFormatting.string(1_500_000).isEmpty)
    }

    @Test func issueKindsClassifyErrno() {
        #expect(ScanIssue.Kind.from(errno: EACCES) == .permissionDenied)
        #expect(ScanIssue.Kind.from(errno: EPERM) == .notPermitted)
        #expect(ScanIssue.Kind.from(errno: EIO) == .unreadable)
        #expect(ScanIssue.Kind.allCases.filter(\.isFailure).count == 5)
    }
}
