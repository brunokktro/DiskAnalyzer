import Foundation
import Testing
@testable import DiskAnalyzerCore

@Suite("Root identity")
struct RootIdentityTests {
    private let saved = RootIdentity(path: "/Volumes/Data/Projects", volumeUUID: "AAAA", mountPath: "/Volumes/Data",
                                     fileSystemType: "apfs", fileID: 42)

    private func probe(at path: RootIdentity?, mounted: Set<String>, mountPoints: Set<String> = []) -> RootProbe {
        RootProbe(identity: { _ in path }, mountedVolumeUUIDs: { mounted }, isMountPoint: { mountPoints.contains($0) })
    }

    @Test func decisionTable() {
        let same = saved
        let otherFolder = RootIdentity(path: saved.path, volumeUUID: "AAAA", mountPath: "/Volumes/Data", fileSystemType: "apfs", fileID: 43)
        let otherVolume = RootIdentity(path: saved.path, volumeUUID: "BBBB", mountPath: "/Volumes/Data", fileSystemType: "apfs", fileID: 42)
        #expect(saved.availability(probe: probe(at: same, mounted: ["AAAA"])) == .available)
        #expect(saved.availability(probe: probe(at: otherFolder, mounted: ["AAAA"])) == .differentFolder)
        #expect(saved.availability(probe: probe(at: otherVolume, mounted: ["AAAA", "BBBB"])) == .differentVolume)
        #expect(saved.availability(probe: probe(at: nil, mounted: ["AAAA"])) == .rootMissing)
        // The volume is gone, even if an empty mount-point folder is left at the path.
        #expect(saved.availability(probe: probe(at: nil, mounted: ["BBBB"])) == .volumeUnavailable)
        #expect(saved.availability(probe: probe(at: otherVolume, mounted: ["BBBB"])) == .volumeUnavailable)
    }

    @Test func volumesWithoutUUIDAreMatchedByMountPathAndFileID() {
        let noUUID = RootIdentity(path: "/Volumes/USB/x", volumeUUID: nil, mountPath: "/Volumes/USB", fileSystemType: "msdos", fileID: 9)
        let sameAgain = noUUID
        let elsewhere = RootIdentity(path: "/Volumes/USB/x", volumeUUID: nil, mountPath: "/", fileSystemType: "apfs", fileID: 9)
        #expect(noUUID.availability(probe: probe(at: sameAgain, mounted: [])) == .available)
        #expect(noUUID.availability(probe: probe(at: elsewhere, mounted: [])) == .differentVolume)
        #expect(noUUID.availability(probe: probe(at: nil, mounted: [], mountPoints: ["/Volumes/USB"])) == .rootMissing)
        #expect(noUUID.availability(probe: probe(at: nil, mounted: [])) == .volumeUnavailable)
    }

    @Test func keyDoesNotDependOnThePath() {
        let renamed = RootIdentity(path: "/Volumes/Data/Renamed", volumeUUID: "AAAA", mountPath: "/Volumes/Data", fileSystemType: "apfs", fileID: 42)
        #expect(renamed.key == saved.key)
        let otherVolume = RootIdentity(path: saved.path, volumeUUID: "BBBB", mountPath: "/Volumes/Data", fileSystemType: "apfs", fileID: 42)
        #expect(otherVolume.key != saved.key)
    }

    @Test func realFolderIsAvailableThenMissingAfterRenameThenReplaced() throws {
        let fixture = try TemporaryFixture(build: false)
        let folder = fixture.path("root")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let identity = try #require(RootIdentity.capture(path: folder))
        #expect(identity.volumeUUID != nil)
        #expect(identity.availability() == .available)

        try FileManager.default.moveItem(atPath: folder, toPath: fixture.path("renamed"))
        #expect(identity.availability() == .rootMissing)
        // Same file ID at the new path: a rescan there keeps the same key.
        #expect(RootIdentity.capture(path: fixture.path("renamed"))?.key == identity.key)

        // Something new at the old path is not the scanned folder.
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(identity.availability() == .differentFolder)
    }

    @Test func homeFolderOnTheDataVolumeIsAvailable() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let identity = try #require(RootIdentity.capture(path: home))
        #expect(identity.availability() == .available)
    }

    /// Two real volumes mounted, one after the other, at the same path.
    @Test func samePathOnAnotherVolumeAndAnUnmountedVolume() throws {
        let fixture = try TemporaryFixture(build: false)
        let mount = fixture.path("mnt")
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        func makeImage(_ name: String) throws -> String {
            let image = fixture.path("\(name).dmg")
            _ = try run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "APFS", "-volname", name, "-quiet", image])
            return image
        }
        func attach(_ image: String) throws {
            _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-mountpoint", mount, "-quiet", image])
        }
        func detach() { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"]) }
        let first = try makeImage("DARootA"), second = try makeImage("DARootB")
        defer { detach() }

        try attach(first)
        // statfs reports /private/var where the standardized fixture path says /var.
        let resolvedMount = PathUtilities.physicalPath(mount)
        guard resolvedMount != nil, VolumeLocator.mountPoint(of: mount)?.mountPath == resolvedMount else {
            Issue.record("could not attach a disk image (hdiutil unavailable here)")
            return
        }
        try FileManager.default.createDirectory(atPath: mount + "/Projects", withIntermediateDirectories: true)
        let identity = try #require(RootIdentity.capture(path: mount + "/Projects"))
        #expect(identity.mountPath == resolvedMount)
        #expect(CoverageScope.determine(rootPath: mount, staysOnVolume: true) == .volume)
        #expect(CoverageScope.determine(rootPath: mount + "/Projects", staysOnVolume: true) == .folder)
        #expect(identity.availability() == .available)
        let baseline = try #require(VolumeBaseline.capture(forPath: mount + "/Projects"))
        #expect(baseline.volumeUUID == identity.volumeUUID)

        detach()
        #expect(identity.availability() == .volumeUnavailable)

        // Another volume at the same path, the scanned one still gone: not restorable, and the
        // advice is to connect the original volume.
        try attach(second)
        try FileManager.default.createDirectory(atPath: mount + "/Projects", withIntermediateDirectories: true)
        #expect(identity.availability() == .volumeUnavailable)
        let now = try #require(VolumeBaseline.capture(forPath: mount + "/Projects"))
        #expect(!now.isSameVolume(as: baseline))

        // The scanned volume is back, but elsewhere: the saved path names the other volume.
        let elsewhere = fixture.path("mnt-a")
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-mountpoint", elsewhere, "-quiet", first])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", elsewhere, "-force", "-quiet"]) }
        #expect(identity.availability() == .differentVolume)
        #expect(RootIdentity.capture(path: elsewhere + "/Projects")?.key == identity.key)
    }

    @Test func restoreSkipsRootsThatAreNoLongerTheSameFolder() async throws {
        let older = try TemporaryFixture()
        let newer = try TemporaryFixture()
        let temp = try TemporaryStore()
        let store = temp.open()
        let olderSnapshot = try snapshot(of: older.scan())
        try await store.save(olderSnapshot)
        try await Task.sleep(for: .milliseconds(20))
        try await store.save(snapshot(of: newer.scan()))

        // The newest root is renamed: it must not be restored, but stays listed with the reason.
        try FileManager.default.moveItem(at: newer.root, to: newer.root.deletingLastPathComponent().appending(path: newer.root.lastPathComponent + "-renamed"))
        defer { try? FileManager.default.moveItem(at: newer.root.deletingLastPathComponent().appending(path: newer.root.lastPathComponent + "-renamed"), to: newer.root) }
        let reader = temp.open()
        let restored = try #require(await reader.restorableSnapshot())
        #expect(restored.root == olderSnapshot.root)
        let recents = await reader.recentScans()
        #expect(recents.map(\.availability) == [.rootMissing, .available])
        #expect(recents.first?.canOpen == false)
    }
}
