import Foundation

/// What a scan covered, which decides whether it may be compared with the volume's used space.
public enum CoverageScope: String, Sendable, Hashable, Codable {
    /// The scan started at the volume's own scan root (its mount point, or the Data volume of
    /// the startup disk) and stayed on that volume.
    case volume
    /// Any other scan: one folder, or a scan that crossed into other volumes. Never compared
    /// with the whole volume's used space.
    case folder

    public var title: String { self == .volume ? "Whole volume" : "Folder only" }

    /// `.volume` only when `rootPath` is where a scan of its volume starts and the scan stays
    /// on that volume, so its measured total and the volume's used space describe the same thing.
    public static func determine(rootPath: String, staysOnVolume: Bool) -> CoverageScope {
        let root = PathUtilities.standardize(rootPath)
        guard staysOnVolume, let (mount, _) = VolumeLocator.mountPoint(of: root) else { return .folder }
        // `standardize` turns /private/var into /var, while statfs reports the real path.
        let resolved = PathUtilities.physicalPath(root) ?? root
        return [root, resolved].contains { $0 == mount || $0 == VolumeLocator.dataVolumePath(forMount: mount) } ? .volume : .folder
    }
}

/// A finished scan plus what is needed to judge it later: the root identity, the scope and
/// the volume baselines around it. This is what ``SnapshotStore`` saves and restores.
public struct ScanSnapshot: Sendable {
    public var result: ScanResult
    public let root: RootIdentity
    public let scope: CoverageScope
    /// Volume figures when the full scan started.
    public let startBaseline: VolumeBaseline?
    /// Volume figures when the full scan finished. A folder rescan never replaces them: the
    /// rest of the tree is still as old as this.
    public let endBaseline: VolumeBaseline?
    /// Folders rescanned on their own since the full scan, oldest first.
    public var rescannedFolders: [String]
    /// What the folder rescans changed in the measured allocation (bytes, signed). The
    /// reconciliation buckets and freshness use `endBaseline.used + rescanAllocatedChange`
    /// (``SpaceReconciliation/accountedUsed``): the used space the results account for.
    public var rescanAllocatedChange: Int64

    public init(result: ScanResult, root: RootIdentity, scope: CoverageScope,
                startBaseline: VolumeBaseline?, endBaseline: VolumeBaseline?, rescannedFolders: [String] = [],
                rescanAllocatedChange: Int64 = 0) {
        self.result = result
        self.root = root
        self.scope = scope
        self.startBaseline = startBaseline
        self.endBaseline = endBaseline
        self.rescannedFolders = rescannedFolders
        self.rescanAllocatedChange = rescanAllocatedChange
    }

    public var tree: FileTree { result.tree }
}

/// One row of the saved-scans list, read without decoding the tree.
public struct SnapshotSummary: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let root: RootIdentity
    public let scope: CoverageScope
    public let finishedAt: Date
    public let savedAt: Date
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let itemCount: Int64
    public let failureCount: Int
    public let formatVersion: Int

    /// Written in a tree format this build can read.
    public var isCompatible: Bool { TreeCodec.isSupported(formatVersion) }
    public var isPartial: Bool { failureCount > 0 }
}

/// A saved scan as the sidebar lists it.
public struct RecentScan: Sendable, Hashable, Identifiable {
    public let summary: SnapshotSummary
    public let availability: RootAvailability
    public var id: Int64 { summary.id }

    public init(summary: SnapshotSummary, availability: RootAvailability) {
        self.summary = summary
        self.availability = availability
    }

    /// Can be opened: compatible format and the same root on disk.
    public var canOpen: Bool { summary.isCompatible && availability.isRestorable }
}
