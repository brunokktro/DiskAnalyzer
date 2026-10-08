import Foundation
import Testing
import DiskAnalyzerFixtures
@testable import DiskAnalyzerCore

@Suite("Scanner on the fixture tree")
struct ScannerIntegrationTests {
    @Test func logicalTotalMatchesManifest() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let result = try fixture.scan()
        #expect(result.tree.root.logicalSize == manifest.expectedLogicalTotal)
        #expect(result.tree.root.itemCount == manifest.expectedCountedItems)
    }

    @Test func allocatedSizeOfEveryFileMatchesLstat() throws {
        let fixture = try TemporaryFixture()
        let result = try fixture.scan()
        var checked = 0
        result.tree.walkDescendants(of: FileTree.rootID) { id, node in
            if node.kind == .file {
                #expect(node.allocatedSize == allocatedBytes(result.tree.path(of: id)), "\(node.name)")
                checked += 1
            }
            return true
        }
        #expect(checked > 15)
    }

    /// `du -k` counts each hard-linked inode once and never follows links, like the scanner.
    @Test func allocatedTotalAgreesWithDu() throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let result = try fixture.scan()
        let output = try run("/usr/bin/du", ["-s", "-k", "-x", fixture.rootPath])
        let kilobytes = try #require(Int64(output.split(separator: "\t").first.map(String.init) ?? ""))
        // du rounds each entry up to 1 KiB blocks; allow that rounding per counted item.
        let tolerance = (result.tree.root.itemCount + Int64(result.statistics.directories)) * 1_024
        #expect(abs(result.tree.root.allocatedSize - kilobytes * 1_024) <= tolerance)
    }

    @Test func directoryTotalsAreSumOfChildren() throws {
        let fixture = try TemporaryFixture()
        let tree = try fixture.scan().tree
        for index in 0..<tree.count {
            let id = NodeID(index)
            let node = tree[id]
            guard node.isDirectory else { continue }
            let counted = tree.children(of: id).filter { !tree[$0].flags.contains(.hardLinkDuplicate) }
            let logical = counted.reduce(Int64(0)) { $0 + tree[$1].logicalSize }
            let items = counted.reduce(Int64(0)) { $0 + tree[$1].itemCount }
            #expect(node.logicalSize == logical, "\(node.name)")
            #expect(node.itemCount == items, "\(node.name)")
        }
    }

    @Test func sparseFileReportsLogicalAboveAllocated() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let node = try #require(try fixture.scan().tree.node(at: manifest.sparseFile))
        #expect(node.logicalSize == manifest.sparseLogicalSize)
        #expect(node.allocatedSize < node.logicalSize / 10)
    }

    @Test func hardLinkIsCountedOnce() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let tree = try fixture.scan().tree
        let links = manifest.hardLinkPaths.compactMap { tree.node(at: $0) }
        #expect(links.count == 2)
        #expect(links.filter { $0.flags.contains(.hardLinkDuplicate) }.count == 1)
        #expect(links.allSatisfy { $0.logicalSize == links[0].logicalSize })
    }

    @Test func symlinksAreListedButNotFollowed() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let result = try fixture.scan()
        for link in manifest.symlinkPaths {
            let node = try #require(result.tree.node(at: link), "\(link)")
            #expect(node.kind == .symlink)
            #expect(node.childCount == 0)
        }
        #expect(result.issueCounts[.cycle] == nil)
        #expect(result.tree.node(at: "Projects/loop/Projects") == nil)
    }

    @Test func unreadableFolderIsReportedNotFatal() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let locked = try #require(manifest.unreadablePath)
        let result = try fixture.scan()
        let node = try #require(result.tree.node(at: locked))
        #expect(node.flags.contains(.unreadable))
        #expect(node.childCount == 0)
        #expect(result.issueCounts[.permissionDenied] == 1)
        let issue = try #require(result.issues.first { $0.kind == .permissionDenied })
        #expect(issue.path == fixture.path(locked))
        #expect(issue.errorCode == EACCES)
        #expect(result.failureCount == 1)
    }

    @Test func hiddenEntriesAreFlagged() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let tree = try fixture.scan().tree
        for hidden in manifest.hiddenPaths {
            #expect(tree.node(at: hidden)?.flags.contains(.hidden) == true, "\(hidden)")
        }
        #expect(tree.node(at: "Media")?.flags.contains(.hidden) == false)
    }

    @Test func packagesAreDetected() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let tree = try fixture.scan().tree
        #expect(tree.node(at: manifest.packagePath)?.isPackage == true)
        #expect(tree.node(at: "Projects")?.isPackage == false)
    }

    @Test func unicodeNamesRoundTripToPaths() throws {
        let fixture = try TemporaryFixture()
        let tree = try fixture.scan().tree
        let id = try #require(tree.id("Résumé – final ✓.pdf"))
        #expect(FileManager.default.fileExists(atPath: tree.path(of: id)))
        #expect(tree[id].logicalSize == 50_000)
    }

    @Test func childrenAreSortedByAllocatedSize() throws {
        let fixture = try TemporaryFixture()
        let tree = try fixture.scan().tree
        for index in 0..<tree.count where tree[NodeID(index)].isDirectory {
            let sizes = tree.children(of: NodeID(index)).map { tree[$0].allocatedSize }
            #expect(sizes == sizes.sorted(by: >))
        }
    }

    @Test func exclusionSkipsSubtree() throws {
        let fixture = try TemporaryFixture()
        let full = try fixture.scan()
        let excludedPath = fixture.path("Media")
        let result = try fixture.scan { $0.excludedPaths = [excludedPath] }
        let media = try #require(result.tree.node(at: "Media"))
        #expect(media.flags.contains(.excluded))
        #expect(media.childCount == 0)
        #expect(result.issueCounts[.excluded] == 1)
        #expect(result.tree.root.logicalSize < full.tree.root.logicalSize)
    }

    @Test func modificationTimeIsRecorded() throws {
        let fixture = try TemporaryFixture()
        let manifest = try #require(fixture.manifest)
        let node = try #require(try fixture.scan().tree.node(at: manifest.oldFilePath))
        #expect(abs(node.modificationTime - FixtureBuilder.oldDate.timeIntervalSince1970) < 1)
    }

    @Test func rootThatIsAFileIsRejected() throws {
        let fixture = try TemporaryFixture()
        #expect(throws: ScanError.notADirectory(fixture.path("tiny.txt"))) {
            try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: fixture.path("tiny.txt"))))
        }
    }

    @Test func missingRootIsRejected() throws {
        let fixture = try TemporaryFixture(build: false)
        let missing = fixture.path("nope")
        #expect(throws: ScanError.cannotOpen(missing, ENOENT)) {
            try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: missing)))
        }
    }

    @Test func unreadableRootThrows() throws {
        let fixture = try TemporaryFixture()
        let locked = fixture.path("Locked")
        #expect(throws: ScanError.cannotOpen(locked, EACCES)) {
            try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: locked)))
        }
    }

    @Test func symlinkedRootIsFollowed() throws {
        let fixture = try TemporaryFixture()
        let link = fixture.rootPath + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.path("Projects"))
        defer { try? FileManager.default.removeItem(atPath: link) }
        let result = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: link)))
        #expect(result.tree.rootPath == link)
        #expect(result.tree.root.logicalSize > 0)
        #expect(result.tree.node(at: "Alpha/main.swift") != nil)
    }

    @Test func emptyFolderScansToZero() throws {
        let fixture = try TemporaryFixture(build: false)
        let result = try fixture.scan()
        #expect(result.tree.count == 1)
        #expect(result.tree.root.logicalSize == 0)
        #expect(result.totalIssueCount == 0)
    }

    @Test func issueListIsCappedButCountsAreExact() throws {
        let fixture = try TemporaryFixture(build: false)
        for index in 0..<5 {
            let path = fixture.path("locked-\(index)")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            chmod(path, 0)
        }
        defer {
            for index in 0..<5 { chmod(fixture.path("locked-\(index)"), 0o755) }
        }
        let result = try fixture.scan { $0.maxRecordedIssues = 2 }
        #expect(result.issues.count == 2)
        #expect(result.issueCounts[.permissionDenied] == 5)
    }

    @Test func filesWithoutReadPermissionAreStillMeasured() throws {
        // Metadata-only: lstat(2) needs search permission on the folder, never read
        // permission on the file. A mode-000 file is measured without any issue,
        // which would be impossible if the scanner opened file contents.
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let target = fixture.path("Media/movie.mov")
        #expect(chmod(target, 0) == 0)
        defer { chmod(target, 0o644) }
        #expect(open(target, O_RDONLY) == -1)
        let result = try fixture.scan()
        #expect(result.totalIssueCount == 0)
        #expect(result.tree.node(at: "Media/movie.mov")?.logicalSize == 2_500_000)
        #expect(result.tree.node(at: "Media/movie.mov")?.allocatedSize == allocatedBytes(target))
    }
}

@Suite("Scanner concurrency")
struct ScannerConcurrencyTests {
    @Test func asyncScanReportsProgress() async throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false, bulkFolders: 4, bulkFilesPerFolder: 400))
        let counter = ProgressCounter()
        let result = try await DiskScanner().scan(ScanOptions(root: fixture.root, progressInterval: .zero)) { progress in
            counter.record(progress)
        }
        #expect(counter.count > 0)
        #expect(counter.last?.entriesVisited == result.tree.count)
        #expect(counter.last?.logicalBytes == result.tree.root.logicalSize)
    }

    @Test func cancellationStopsTheScan() async throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false, bulkFolders: 5, bulkFilesPerFolder: 400))
        let gate = DispatchSemaphore(value: 0)
        let started = ProgressCounter()
        let task = Task {
            try await DiskScanner().scan(ScanOptions(root: fixture.root, progressInterval: .zero)) { progress in
                // Hold the walker inside its first callback until the test has cancelled.
                if started.count == 0 { started.record(progress); gate.wait() } else { started.record(progress) }
            }
        }
        while started.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.count == 1)
        #expect(try #require(started.last).entriesVisited < 2_000)
    }

    @Test func alreadyCancelledTaskThrowsImmediately() async throws {
        let fixture = try TemporaryFixture(options: .init(includesUnreadableFolder: false))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiskScanner().scan(ScanOptions(root: fixture.root))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanProgress] = []

    func record(_ progress: ScanProgress) {
        lock.withLock { values.append(progress) }
    }

    var count: Int { lock.withLock { values.count } }
    var last: ScanProgress? { lock.withLock { values.last } }
}
