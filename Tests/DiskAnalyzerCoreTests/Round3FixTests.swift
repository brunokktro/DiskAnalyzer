import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

// Follow-up to review round 2: the rules added for R2-1 to R2-4 and for the cloud storage
// scope decision. Every refusal is paired with a positive control, so a fix that refuses
// everything cannot pass.

private func mkdir3(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func write3(_ path: String, bytes: Int) throws {
    try Data(repeating: 0x43, count: bytes).write(to: URL(fileURLWithPath: path))
}

/// True on the APFS volume group layout, where `/Users` is a firmlink to the Data volume.
private var hasFirmlinkedDataVolume: Bool {
    guard let users = FileIdentity.ofEntry(atPath: "/Users") else { return false }
    return users == FileIdentity.ofEntry(atPath: "/System/Volumes/Data/Users")
}

@Suite("Round 3: folders reached through two paths")
struct FolderAlreadyCountedTests {
    /// The same layout as the round 2 reproduction, checked from the other side: exactly one of
    /// the two paths is entered, the other is flagged, reported, and cannot be collected.
    @Test func firmlinkedTwinIsFlaggedReportedAndNotCollectable() throws {
        let data = "/System/Volumes/Data"
        guard hasFirmlinkedDataVolume, FileManager.default.fileExists(atPath: "/Users/Shared") else { return }
        let keep: Set<String> = ["/System", "/System/Volumes", data, "/Users", data + "/Users", "/Users/Shared", data + "/Users/Shared"]
        var excluded = Set<String>()
        for dir in ["/", "/System", "/System/Volumes", data, "/Users", data + "/Users"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir == "/" ? "/" + name : dir + "/" + name
                if !keep.contains(path) { excluded.insert(path) }
            }
        }
        let result = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: "/"), excludedPaths: excluded))
        let tree = result.tree
        let first = try #require(tree.nodeID(forPath: "/Users"))
        let second = try #require(tree.nodeID(forPath: data + "/Users"))
        let flagged = [first, second].filter { tree[$0].flags.contains(.alreadyCounted) }
        #expect(flagged.count == 1, "exactly one of the two paths to the same folder must be flagged")
        guard let twin = flagged.first else { return }
        let entered = twin == first ? second : first
        #expect(tree.children(of: twin).isEmpty, "the twin must not be entered")
        #expect(!tree.children(of: entered).isEmpty, "the first path must be entered")
        #expect(tree[twin].flags.contains(.hardLinkDuplicate))
        #expect(result.statistics.foldersAlreadyCounted >= 1)
        #expect((result.issueCounts[.alreadyCounted] ?? 0) >= 1)
        #expect(!ScanIssue.Kind.alreadyCounted.isFailure)
        #expect(Collector.Item.limitation(of: twin, in: tree) == .notMeasured)
        #expect(Collector.Item.limitation(of: entered, in: tree) == nil)
    }

    /// Ordinary trees have no repeated folder identity: nothing is flagged.
    @Test func ordinaryTreeFlagsNothing() throws {
        let fixture = try TemporaryFixture()
        let result = try fixture.scan()
        #expect(result.statistics.foldersAlreadyCounted == 0)
        #expect(result.issueCounts[.alreadyCounted] == nil)
        var flagged = 0
        result.tree.walkDescendants(of: FileTree.rootID) { _, node in
            if node.flags.contains(.alreadyCounted) { flagged += 1 }
            return true
        }
        #expect(flagged == 0)
    }

    @Test func startupDiskIsScannedThroughItsDataVolume() {
        if hasFirmlinkedDataVolume {
            #expect(VolumeLocator.preferredScanRoot(for: "/") == "/System/Volumes/Data")
            #expect(VolumeLocator.preferredScanRoot(for: "//") == "/System/Volumes/Data")
        } else {
            #expect(VolumeLocator.preferredScanRoot(for: "/") == "/")
        }
        #expect(VolumeLocator.preferredScanRoot(for: "/Users/") == "/Users")
        #expect(VolumeLocator.preferredScanRoot(for: "/System/Volumes/Data") == "/System/Volumes/Data")
    }
}

@Suite("Round 3: protected folders, their ancestors and cloud storage roots")
struct ProtectedScopeTests {
    private func policy(_ fixture: TemporaryFixture, home: String) -> TrashPolicy {
        let homeURL = URL(fileURLWithPath: fixture.path(home), isDirectory: true)
        return TrashPolicy(scanRoot: fixture.rootPath,
                           protectedPaths: TrashPolicy.defaultProtectedPaths(home: homeURL),
                           protectedContainers: TrashPolicy.defaultProtectedContainers(home: homeURL))
    }

    @Test func standardAccountFoldersAreProtectedButTheirContentsAreNot() throws {
        let fixture = try TemporaryFixture(build: false)
        for name in ["Pictures", "Music", "Movies", "Public"] {
            try mkdir3(fixture.path("home/\(name)/album"))
        }
        let policy = policy(fixture, home: "home")
        for name in ["Pictures", "Music", "Movies", "Public"] {
            #expect(policy.validate(path: fixture.path("home/\(name)"), expectedDirectory: true) != nil, "\(name) must be protected")
            #expect(policy.validate(path: fixture.path("home/\(name)/album"), expectedDirectory: true) == nil, "\(name)/album must stay movable")
        }
    }

    @Test func cloudStorageRootsAndTheirDomainsAreProtectedButSyncedFilesAreNot() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir3(fixture.path("home/Library/CloudStorage/OneDrive-Example/Reports"))
        try write3(fixture.path("home/Library/CloudStorage/OneDrive-Example/Reports/q3.pdf"), bytes: 1_000)
        try mkdir3(fixture.path("home/Library/Mobile Documents/com~apple~CloudDocs/Old"))
        let policy = policy(fixture, home: "home")
        let storage = fixture.path("home/Library/CloudStorage")
        let icloud = fixture.path("home/Library/Mobile Documents")

        #expect(policy.validate(path: storage, expectedDirectory: true) != nil)
        #expect(policy.validate(path: storage + "/OneDrive-Example", expectedDirectory: true) != nil,
                "a File Provider domain root must be protected: trashing it removes the synced tree in the cloud")
        #expect(policy.validate(path: icloud, expectedDirectory: true) != nil)
        #expect(policy.validate(path: icloud + "/com~apple~CloudDocs", expectedDirectory: true) != nil,
                "the iCloud Drive root must be protected")
        // Controls: content inside a domain is the user's to manage, as in Finder.
        #expect(policy.validate(path: storage + "/OneDrive-Example/Reports", expectedDirectory: true) == nil)
        #expect(policy.validate(path: storage + "/OneDrive-Example/Reports/q3.pdf", expectedDirectory: false) == nil)
        #expect(policy.validate(path: icloud + "/com~apple~CloudDocs/Old", expectedDirectory: true) == nil)
    }

    @Test func cloudDomainReachedThroughASymlinkedScanRootIsStillProtected() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir3(fixture.path("home/Library/CloudStorage/Dropbox/Photos"))
        let holder = try TemporaryFixture(build: false)
        let alias = holder.path("storage-alias")
        #expect(symlink(fixture.path("home/Library/CloudStorage"), alias) == 0)
        let homeURL = URL(fileURLWithPath: fixture.path("home"), isDirectory: true)
        let policy = TrashPolicy(scanRoot: alias,
                                 protectedPaths: TrashPolicy.defaultProtectedPaths(home: homeURL),
                                 protectedContainers: TrashPolicy.defaultProtectedContainers(home: homeURL))
        #expect(policy.validate(path: alias + "/Dropbox", expectedDirectory: true) != nil)
        #expect(policy.validate(path: alias + "/Dropbox/Photos", expectedDirectory: true) == nil)
    }

    /// R2-2 through an alias: the ancestor check also runs on the resolved path.
    @Test func ancestorOfAProtectedFolderReachedThroughAnAliasIsRefused() throws {
        let fixture = try TemporaryFixture(build: false)
        try mkdir3(fixture.path("real/homes/alice/Documents"))
        try mkdir3(fixture.path("real/scratch"))
        let holder = try TemporaryFixture(build: false)
        let alias = holder.path("disk-alias")
        #expect(symlink(fixture.path("real"), alias) == 0)
        let home = URL(fileURLWithPath: fixture.path("real/homes/alice"), isDirectory: true)
        let policy = TrashPolicy(scanRoot: alias, protectedPaths: TrashPolicy.defaultProtectedPaths(home: home))
        #expect(policy.validate(path: alias + "/homes", expectedDirectory: true) != nil)
        #expect(policy.validate(path: alias + "/scratch", expectedDirectory: true) == nil)
    }
}

@Suite("Round 3: paths built from repaired names")
struct ExactPathTests {
    private func node(_ name: String, parent: NodeID, kind: NodeKind, flags: NodeFlags = []) -> FileNode {
        FileNode(name: name, parent: parent, kind: kind, flags: flags, logicalSize: 1, allocatedSize: 1,
                 itemCount: kind == .directory ? 0 : 1, modificationTime: 0, childStart: 0, childCount: 0)
    }

    @Test func invalidNameMakesTheNodeAndItsDescendantsInexact() {
        var nodes = [
            node("/scan", parent: -1, kind: .directory),
            node("ok", parent: 0, kind: .directory),
            node("ok.txt", parent: 1, kind: .file),
            node("bad\u{FFFD}", parent: 0, kind: .directory, flags: .invalidName),
            node("inside.txt", parent: 3, kind: .file),
        ]
        let tree = FileTree.assemble(rootPath: "/scan", nodes: &nodes)
        #expect(tree.hasExactPath(FileTree.rootID))
        #expect(tree.hasExactPath(1))
        #expect(tree.hasExactPath(2))
        #expect(!tree.hasExactPath(3))
        #expect(!tree.hasExactPath(4), "a descendant of a repaired name inherits the repaired path")
        #expect(Collector.Item.limitation(of: 4, in: tree) == .invalidName)
        #expect(Collector.Item.limitation(of: 2, in: tree) == nil)
    }
}

@Suite("Round 3: packaging")
struct BuildNumberTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/package-app.sh").path(percentEncoded: false)

    private func buildNumber(_ version: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script, "--print-build-number"]
        process.environment = ["APP_VERSION": version, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func bundleVersionGrowsWithEveryReleaseOrder() throws {
        let ordered = ["0.1.0", "0.1.9", "0.1.10", "0.2.0", "0.11.0", "1.2.10", "1.21.0", "2.0.0"]
        var previous = -1
        for version in ordered {
            let result = try buildNumber(version)
            #expect(result.status == 0, "\(version): \(result.output)")
            let value = try #require(Int(result.output), "\(version) printed '\(result.output)'")
            #expect(value > previous, "\(version) -> \(value) does not grow past \(previous)")
            previous = value
        }
    }

    @Test func versionsThatCannotStayMonotonicAreRejected() throws {
        for version in ["1.100.0", "1.0.100", "1.0", "v1.0.0"] {
            #expect(try buildNumber(version).status != 0, "\(version) must be rejected")
        }
    }
}
