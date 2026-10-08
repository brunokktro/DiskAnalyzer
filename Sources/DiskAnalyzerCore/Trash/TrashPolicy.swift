import Foundation

/// Decides whether a path may be moved to the Trash. Disk Analyzer never deletes
/// permanently; this policy is the last gate before `FileManager.trashItem`.
public struct TrashPolicy: Sendable {
    public enum Refusal: Error, Equatable, Sendable, LocalizedError {
        case protectedLocation(String)
        case scanRoot
        case outsideScanRoot
        case missing
        case changedType
        case volumeRoot
        /// The path now leads to a different object than the one that was collected.
        case replaced
        /// The scan could not look inside the item, so its real size is unknown.
        case notMeasured

        public var errorDescription: String? {
            switch self {
            case .protectedLocation(let path): "“\(path)” is a system or account folder and is protected."
            case .scanRoot: "The scanned folder itself cannot be moved to the Trash from here."
            case .outsideScanRoot: "The item is outside the scanned folder (a folder on its path may now be an alias). Rescan first."
            case .missing: "The item no longer exists at this path."
            case .changedType: "The item changed since the scan (file vs. folder). Rescan first."
            case .volumeRoot: "Volume roots cannot be moved to the Trash."
            case .replaced: "A different item now exists at this path. Rescan first."
            case .notMeasured: "The scan could not look inside this item, so its size is unknown. Open it in Finder instead."
            }
        }
    }

    public let scanRoot: String
    /// Folders that are refused, together with every folder that contains one of them.
    public let protectedPaths: Set<String>
    /// Folders whose direct children are also refused: the cloud storage roots. A child is a
    /// File Provider domain or an iCloud container, and moving it to the Trash removes the
    /// whole synced tree, also in the cloud. Items further down stay movable.
    public let protectedContainers: Set<String>
    /// `protectedPaths` with symbolic links resolved, so an alias of a protected folder is still protected.
    private let resolvedProtectedPaths: Set<String>
    private let resolvedProtectedContainers: Set<String>
    /// Identities of the protected folders that exist, which also covers firmlinks and hard-linked aliases.
    private let protectedIdentities: Set<FileIdentity>

    public init(scanRoot: String,
                protectedPaths: Set<String> = TrashPolicy.defaultProtectedPaths(),
                protectedContainers: Set<String> = TrashPolicy.defaultProtectedContainers()) {
        self.scanRoot = PathUtilities.standardize(scanRoot)
        let lexical = Set(protectedPaths.map(PathUtilities.standardize))
        self.protectedPaths = lexical
        resolvedProtectedPaths = Set(lexical.compactMap(PathUtilities.resolved))
        protectedIdentities = Set(lexical.compactMap(FileIdentity.ofTarget(atPath:)))
        let containers = Set(protectedContainers.map(PathUtilities.standardize))
        self.protectedContainers = containers
        resolvedProtectedContainers = Set(containers.compactMap(PathUtilities.resolved))
    }

    /// Cloud storage roots of the current account: `~/Library/CloudStorage` (File Provider
    /// domains such as OneDrive, Google Drive, Dropbox) and `~/Library/Mobile Documents`
    /// (iCloud Drive and app containers).
    public static func defaultProtectedContainers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        let homePath = PathUtilities.standardize(home.path(percentEncoded: false))
        let containers = [homePath + "/Library/CloudStorage", homePath + "/Library/Mobile Documents"]
        return Set(containers + containers.map { "/System/Volumes/Data" + $0 })
    }

    /// System locations plus the current account's home and Library, resolved at runtime.
    /// Paths are listed both as seen through firmlinks and on the Data volume.
    public static func defaultProtectedPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        let system = [
            "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/usr", "/bin",
            "/sbin", "/etc", "/var", "/tmp", "/opt", "/cores", "/dev", "/Network",
            "/System/Volumes", "/System/Volumes/Data", "/Users/Shared",
        ]
        let homePath = PathUtilities.standardize(home.path(percentEncoded: false))
        let account = [homePath, homePath + "/Library", homePath + "/.Trash"]
            + ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Public"].map { homePath + "/" + $0 }
            + [homePath + "/Library/CloudStorage", homePath + "/Library/Mobile Documents"]
        var result = Set(system + account)
        for path in Array(result) where path != "/" && !path.hasPrefix("/System/Volumes") {
            result.insert("/System/Volumes/Data" + path)
        }
        let bundle = PathUtilities.standardize(Bundle.main.bundleURL.path(percentEncoded: false))
        if bundle.hasSuffix(".app") { result.insert(bundle) }
        return result
    }

    /// Static checks that need no file system access. They compare text only, so
    /// ``validate(path:expectedDirectory:expectedIdentity:)`` repeats them on the resolved path.
    public func validatePath(_ rawPath: String) -> Refusal? {
        let path = PathUtilities.standardize(rawPath)
        if path == scanRoot { return .scanRoot }
        if !PathUtilities.isSameOrDescendant(path, of: scanRoot) { return .outsideScanRoot }
        return protectionRefusal(path, protected: protectedPaths, containers: protectedContainers)
    }

    /// Full check right before moving:
    /// 1. the static rules on the path as written;
    /// 2. the item still exists, with the same type and (when known) the same identity;
    /// 3. with every symbolic link on the way resolved (`realpath(3)` of the parent folder),
    ///    the item is still strictly inside the resolved scan root and is not a protected folder;
    /// 4. it is not the root of another volume.
    ///
    /// The item itself is never resolved: a symbolic link is validated, and moved, as itself.
    public func validate(path rawPath: String, expectedDirectory: Bool, expectedIdentity: FileIdentity? = nil) -> Refusal? {
        if let refusal = validatePath(rawPath) { return refusal }
        let path = PathUtilities.standardize(rawPath)
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if isDirectory != expectedDirectory { return .changedType }
        let identity = FileIdentity(info)
        if let expectedIdentity, expectedIdentity != identity { return .replaced }

        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedRoot = PathUtilities.resolved(scanRoot), let resolvedParent = PathUtilities.resolved(parent) else {
            return .outsideScanRoot
        }
        let name = (path as NSString).lastPathComponent
        let resolvedPath = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        if resolvedPath == resolvedRoot { return .scanRoot }
        if !PathUtilities.isSameOrDescendant(resolvedPath, of: resolvedRoot) { return .outsideScanRoot }
        if protectedIdentities.contains(identity)
            || protectionRefusal(resolvedPath, protected: resolvedProtectedPaths, containers: resolvedProtectedContainers) != nil {
            return .protectedLocation(path)
        }

        if isDirectory {
            var parentInfo = stat()
            if lstat(parent, &parentInfo) == 0, parentInfo.st_dev != info.st_dev { return .volumeRoot }
        }
        return nil
    }

    /// Refuses a protected folder, any folder that CONTAINS one (moving it would take the
    /// protected folder along), a direct child of a cloud storage root, and the sealed system.
    private func protectionRefusal(_ path: String, protected: Set<String>, containers: Set<String>) -> Refusal? {
        if protected.contains(where: { PathUtilities.isSameOrDescendant($0, of: path) }) { return .protectedLocation(path) }
        if containers.contains((path as NSString).deletingLastPathComponent) { return .protectedLocation(path) }
        let isSealedSystem = PathUtilities.isSameOrDescendant(path, of: "/System")
            && !PathUtilities.isSameOrDescendant(path, of: "/System/Volumes/Data")
        return isSealedSystem ? .protectedLocation(path) : nil
    }
}

/// Abstraction over the system Trash so tests never touch the real one.
public protocol TrashMover: Sendable {
    /// Moves the item to the Trash and returns its new location when the system reports it.
    func moveToTrash(_ url: URL) throws -> URL?
}

/// Uses `FileManager.trashItem(at:resultingItemURL:)`, the same operation as Finder's
/// "Move to Trash". It is reversible from the Trash; nothing is erased.
public struct SystemTrashMover: TrashMover {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

public struct TrashOutcome: Sendable, Identifiable {
    public enum Status: Sendable {
        case moved(to: URL?)
        case refused(TrashPolicy.Refusal)
        case failed(String)
    }

    public var id: String { path }
    public let path: String
    public let status: Status

    public var succeeded: Bool {
        if case .moved = status { return true }
        return false
    }
}

public enum TrashOperation {
    /// Validates and moves each item independently: one failure never stops the batch.
    /// Items the scan could not measure are refused before the disk is even checked.
    public static func run(_ items: [Collector.Item], policy: TrashPolicy, mover: some TrashMover) -> [TrashOutcome] {
        items.map { item in
            if !item.isTrashable {
                return TrashOutcome(path: item.path, status: .refused(.notMeasured))
            }
            if let refusal = policy.validate(path: item.path, expectedDirectory: item.isDirectory, expectedIdentity: item.identity) {
                return TrashOutcome(path: item.path, status: .refused(refusal))
            }
            do {
                let destination = try mover.moveToTrash(URL(fileURLWithPath: item.path, isDirectory: item.isDirectory))
                return TrashOutcome(path: item.path, status: .moved(to: destination))
            } catch {
                return TrashOutcome(path: item.path, status: .failed(error.localizedDescription))
            }
        }
    }
}
