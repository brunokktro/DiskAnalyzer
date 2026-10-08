import Darwin
import Foundation

/// The `(st_dev, st_ino)` pair that names one file system object, independent of the path
/// used to reach it. Two paths with the same identity are the same object (hard links,
/// firmlinks, or a folder reached through a symbolic link).
public struct FileIdentity: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(_ info: stat) {
        self.init(device: info.st_dev, inode: info.st_ino)
    }

    /// Identity of the entry itself; a symbolic link is NOT followed (`lstat(2)`).
    public static func ofEntry(atPath path: String) -> FileIdentity? {
        var info = stat()
        return lstat(path, &info) == 0 ? FileIdentity(info) : nil
    }

    /// Identity of what the path finally points at; symbolic links ARE followed (`stat(2)`).
    public static func ofTarget(atPath path: String) -> FileIdentity? {
        var info = stat()
        return stat(path, &info) == 0 ? FileIdentity(info) : nil
    }
}

public extension PathUtilities {
    /// Canonical absolute path with every symbolic link resolved, via `realpath(3)`.
    /// Returns `nil` when any component does not exist or cannot be searched.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return standardize(String(cString: pointer))
    }
}
