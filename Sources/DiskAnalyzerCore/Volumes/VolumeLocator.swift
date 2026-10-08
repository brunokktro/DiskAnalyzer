import Foundation

/// A mounted volume the user can pick as a scan root.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: String { scanPath }
    public let name: String
    /// Mount point as reported by the system.
    public let mountPath: String
    /// Where a scan should start. On the APFS system volume group this is the Data
    /// volume (`/System/Volumes/Data`), because the sealed system volume is read-only
    /// and scanning `/` would cross into it through firmlinks.
    public let scanPath: String
    public let fileSystemType: String
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?
    /// Capacity available for "important" data, which includes purgeable space (see
    /// `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`).
    public let availableForImportantUsage: Int64?
    public let isBootVolume: Bool
    public let isRemovable: Bool
}

public enum VolumeLocator {
    /// The volume that holds the current user's home folder.
    public static func homeVolume() -> VolumeInfo? {
        volume(containing: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
    }

    /// The mount point of the device holding `path`, via `statfs(2)`.
    public static func mountPoint(of path: String) -> (mountPath: String, fileSystemType: String)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let mount = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return (mount, type)
    }

    public static func volume(containing path: String) -> VolumeInfo? {
        guard let (mount, type) = mountPoint(of: path) else { return nil }
        return describe(mountPath: mount, fileSystemType: type)
    }

    /// User-visible volumes plus the volume that holds the home folder.
    public static func scannableVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        var seen: Set<String> = []
        let candidates = [homeVolume()] + urls.map { url -> VolumeInfo? in
            let path = url.path(percentEncoded: false)
            guard let (mount, type) = mountPoint(of: path) else { return nil }
            return describe(mountPath: mount, fileSystemType: type)
        }
        for case let volume? in candidates where seen.insert(volume.scanPath).inserted {
            result.append(volume)
        }
        return result
    }

    static func describe(mountPath: String, fileSystemType: String) -> VolumeInfo {
        let url = URL(fileURLWithPath: mountPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isBoot = values?.volumeIsRootFileSystem ?? (mountPath == "/")
        return VolumeInfo(
            name: values?.volumeLocalizedName ?? (mountPath as NSString).lastPathComponent,
            mountPath: mountPath,
            scanPath: dataVolumePath(forMount: mountPath),
            fileSystemType: fileSystemType,
            totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
            availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
            availableForImportantUsage: values?.volumeAvailableCapacityForImportantUsage,
            isBootVolume: isBoot,
            isRemovable: values?.volumeIsRemovable ?? false
        )
    }

    /// Where a scan of `path` should start. Choosing the startup disk ("Macintosh HD", `/`)
    /// in the Open panel scans its Data volume, exactly like the sidebar entry, so the
    /// firmlinked folders are listed at their real location. Any other path is unchanged.
    public static func preferredScanRoot(for path: String) -> String {
        let standardized = PathUtilities.standardize(path)
        return standardized == "/" ? dataVolumePath(forMount: "/") : standardized
    }

    /// Maps the read-only system root to its writable Data volume when that layout exists.
    static func dataVolumePath(forMount mountPath: String, fileManager: FileManager = .default) -> String {
        let data = "/System/Volumes/Data"
        guard mountPath == "/" else { return mountPath }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: data, isDirectory: &isDirectory), isDirectory.boolValue,
           let (dataMount, _) = mountPoint(of: data), dataMount == data {
            return data
        }
        return mountPath
    }
}
