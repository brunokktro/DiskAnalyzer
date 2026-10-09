import Darwin
import Foundation

/// Names a scan root by what it is, not only by where it is: the volume UUID plus the
/// file ID (`st_ino`) of the folder. A path alone is not an identity, because another
/// volume can be mounted at the same path and a folder can be replaced by a new one.
public struct RootIdentity: Sendable, Hashable, Codable {
    /// Standardized path the scan started from.
    public let path: String
    /// `URLResourceKey.volumeUUIDStringKey` of the volume holding the root. `nil` on file
    /// systems that do not report one (some FAT and network volumes); those are matched by
    /// mount path and file ID instead.
    public let volumeUUID: String?
    public let mountPath: String
    public let fileSystemType: String
    /// `st_ino` of the root folder, from `stat(2)` (a symlinked root is followed, as the scan does).
    public let fileID: UInt64

    public init(path: String, volumeUUID: String?, mountPath: String, fileSystemType: String, fileID: UInt64) {
        self.path = PathUtilities.standardize(path)
        self.volumeUUID = volumeUUID
        self.mountPath = mountPath
        self.fileSystemType = fileSystemType
        self.fileID = fileID
    }

    /// Stable key: one saved snapshot per key. A renamed root keeps its key.
    public var key: String { "\(volumeUUID ?? "mount:" + mountPath)#\(fileID)" }

    /// Reads the identity of the folder at `path` now, or `nil` if it does not exist.
    public static func capture(path: String) -> RootIdentity? {
        let standardized = PathUtilities.standardize(path)
        var info = stat()
        guard stat(standardized, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let (mount, type) = VolumeLocator.mountPoint(of: standardized) else { return nil }
        let url = URL(fileURLWithPath: standardized, isDirectory: true)
        let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return RootIdentity(path: standardized, volumeUUID: uuid, mountPath: mount, fileSystemType: type, fileID: info.st_ino)
    }

    /// Whether this root can be shown again as the snapshot describes it.
    public func availability(probe: RootProbe = .system) -> RootAvailability {
        if let uuid = volumeUUID, !probe.mountedVolumeUUIDs().contains(uuid) { return .volumeUnavailable }
        guard let current = probe.identity(path) else {
            if volumeUUID == nil, !probe.isMountPoint(mountPath) { return .volumeUnavailable }
            return .rootMissing
        }
        if volumeUUID != nil || current.volumeUUID != nil {
            if current.volumeUUID != volumeUUID { return .differentVolume }
        } else if current.mountPath != mountPath {
            return .differentVolume
        }
        return current.fileID == fileID ? .available : .differentFolder
    }
}

/// Result of checking a saved root against the disk as it is now.
public enum RootAvailability: String, Sendable, Hashable, Codable {
    /// Same volume, same folder: the snapshot can be shown.
    case available
    /// The volume that held the root is not mounted.
    case volumeUnavailable
    /// The volume is mounted but nothing is at the saved path (renamed, moved or deleted).
    case rootMissing
    /// Something is at the saved path, but on another volume (for example another disk
    /// mounted at the same place).
    case differentVolume
    /// The saved path now names a different folder on the same volume (replaced or recreated).
    case differentFolder

    public var isRestorable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: "Available"
        case .volumeUnavailable: "Volume not connected"
        case .rootMissing: "Folder not found"
        case .differentVolume: "Different volume at this path"
        case .differentFolder: "Folder was replaced"
        }
    }

    public var explanation: String {
        switch self {
        case .available: "The folder is the same one that was scanned."
        case .volumeUnavailable: "Connect the volume that held this folder to open the saved scan."
        case .rootMissing: "Nothing is at the saved path any more. It may have been renamed, moved or deleted. Scan it again at its new location."
        case .differentVolume: "Another volume is mounted at the saved path, so the saved results describe different data."
        case .differentFolder: "The saved path now names a different folder, so the saved results describe different data."
        }
    }

    public var symbolName: String {
        switch self {
        case .available: "checkmark.circle"
        case .volumeUnavailable: "externaldrive.badge.xmark"
        case .rootMissing: "questionmark.folder"
        case .differentVolume, .differentFolder: "exclamationmark.triangle"
        }
    }
}

/// The file system facts ``RootIdentity/availability(probe:)`` needs. Injectable so the
/// decision logic can be tested exhaustively; ``system`` reads the real disk.
public struct RootProbe: Sendable {
    public var identity: @Sendable (String) -> RootIdentity?
    public var mountedVolumeUUIDs: @Sendable () -> Set<String>
    public var isMountPoint: @Sendable (String) -> Bool

    public init(identity: @escaping @Sendable (String) -> RootIdentity?,
                mountedVolumeUUIDs: @escaping @Sendable () -> Set<String>,
                isMountPoint: @escaping @Sendable (String) -> Bool) {
        self.identity = identity
        self.mountedVolumeUUIDs = mountedVolumeUUIDs
        self.isMountPoint = isMountPoint
    }

    public static let system = RootProbe(
        identity: { RootIdentity.capture(path: $0) },
        mountedVolumeUUIDs: {
            // Hidden volumes included: the APFS Data volume is one of them.
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
            return Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
        },
        isMountPoint: { path in VolumeLocator.mountPoint(of: path)?.mountPath == path }
    )
}

/// Space figures of one volume at one moment, as the file system reports them.
public struct VolumeBaseline: Sendable, Hashable, Codable {
    public let capturedAt: Date
    public let volumeUUID: String?
    public let mountPath: String
    public let volumeName: String?
    /// `volumeTotalCapacityKey`. On APFS this is the size of the container shared by its volumes.
    public let totalCapacity: Int64?
    /// `volumeAvailableCapacityKey`: free space right now, without purgeable space.
    public let availableCapacity: Int64?
    /// `volumeAvailableCapacityForImportantUsageKey`: what macOS would make available for
    /// important data, including purgeable space it can reclaim.
    public let availableForImportantUsage: Int64?

    public init(capturedAt: Date, volumeUUID: String?, mountPath: String, volumeName: String?,
                totalCapacity: Int64?, availableCapacity: Int64?, availableForImportantUsage: Int64?) {
        self.capturedAt = capturedAt
        self.volumeUUID = volumeUUID
        self.mountPath = mountPath
        self.volumeName = volumeName
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
    }

    /// Used space as the file system reports it: capacity minus available. `nil` when either
    /// figure is missing or inconsistent, never guessed.
    public var used: Int64? {
        guard let total = totalCapacity, let free = availableCapacity, total >= 0, free >= 0, free <= total else { return nil }
        return total - free
    }

    /// Reads the volume holding `path` now. Each call uses a new `URL`, so no cached
    /// resource value is reused.
    public static func capture(forPath path: String, at date: Date = Date()) -> VolumeBaseline? {
        guard let (mount, _) = VolumeLocator.mountPoint(of: path) else { return nil }
        var url = URL(fileURLWithPath: mount, isDirectory: true)
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeBaseline(
            capturedAt: date, volumeUUID: values.volumeUUIDString, mountPath: mount, volumeName: values.volumeLocalizedName,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init), availableCapacity: values.volumeAvailableCapacity.map(Int64.init),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage
        )
    }

    /// `true` when both baselines describe the same volume, so their figures can be compared.
    public func isSameVolume(as other: VolumeBaseline) -> Bool {
        if volumeUUID != nil || other.volumeUUID != nil { return volumeUUID == other.volumeUUID }
        return mountPath == other.mountPath
    }
}
