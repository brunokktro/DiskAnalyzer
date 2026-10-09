import Foundation

/// What to scan and how. Every path is resolved at runtime; nothing is user-specific.
public struct ScanOptions: Sendable, Hashable {
    /// Directory to scan. Symlinks are followed for the root only.
    public var root: URL
    /// Do not descend into directories that live on a different device than the root
    /// (other volumes, network mounts, disk images). Matches `du -x`.
    public var staysOnVolume: Bool
    /// Absolute paths whose subtree is skipped. Standardized on use.
    public var excludedPaths: Set<String>
    /// How File Provider placeholders are handled. Local-only is the safe default.
    public var cloudScanMode: CloudScanMode
    /// Ask Launch Services whether directories with an extension are packages.
    public var detectsPackages: Bool
    /// Upper bound of individual issues kept in memory. Counters keep counting past it.
    public var maxRecordedIssues: Int
    /// Minimum time between two progress callbacks.
    public var progressInterval: Duration

    public init(
        root: URL,
        staysOnVolume: Bool = true,
        excludedPaths: Set<String> = [],
        cloudScanMode: CloudScanMode = .localOnly,
        detectsPackages: Bool = true,
        maxRecordedIssues: Int = 5_000,
        progressInterval: Duration = .milliseconds(100)
    ) {
        self.root = root
        self.staysOnVolume = staysOnVolume
        self.excludedPaths = excludedPaths
        self.cloudScanMode = cloudScanMode
        self.detectsPackages = detectsPackages
        self.maxRecordedIssues = maxRecordedIssues
        self.progressInterval = progressInterval
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var entriesVisited: Int
    public var directoriesVisited: Int
    public var allocatedBytes: Int64
    public var logicalBytes: Int64
    public var issueCount: Int
    /// Directory currently being listed.
    public var currentPath: String
    public var elapsed: Duration
}

/// Something the scan could not measure, or chose not to enter.
public struct ScanIssue: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Hashable {
        /// `EACCES`: POSIX permissions deny listing or reading metadata.
        case permissionDenied
        /// `EPERM`: usually macOS privacy protection (TCC). Full Disk Access may be required.
        case notPermitted
        /// Any other error while listing a directory or reading metadata.
        case unreadable
        /// A directory that is its own ancestor (hard-linked directories).
        case cycle
        /// Mount point of another volume, not entered because the scan stays on one volume.
        case otherVolume
        /// Skipped because it matched an exclusion.
        case excluded
        /// File name is not valid UTF-8; shown with replacement characters and not actionable.
        case invalidName
        /// A File Provider placeholder that local-only mode deliberately did not materialize.
        case cloudPlaceholder
        /// Folder already reached through another path (APFS firmlink or hard-linked folder).
        /// Counted once, where it was first found, and not entered again.
        case alreadyCounted

        public var title: String {
            switch self {
            case .permissionDenied: "Permission denied"
            case .notPermitted: "Blocked by macOS privacy protection"
            case .unreadable: "Could not be read"
            case .cycle: "Directory cycle"
            case .otherVolume: "Other volume (not entered)"
            case .excluded: "Excluded"
            case .invalidName: "Invalid file name encoding"
            case .cloudPlaceholder: "Cloud placeholder not downloaded"
            case .alreadyCounted: "Already counted at another path"
            }
        }

        /// Issues that mean data went unmeasured, as opposed to deliberate skips.
        public var isFailure: Bool {
            switch self {
            case .permissionDenied, .notPermitted, .unreadable, .cycle, .invalidName: true
            case .otherVolume, .excluded, .cloudPlaceholder, .alreadyCounted: false
            }
        }

        static func from(errno code: Int32) -> Kind {
            switch code {
            case EACCES: .permissionDenied
            case EPERM: .notPermitted
            default: .unreadable
            }
        }
    }

    public let id: Int
    public let path: String
    public let kind: Kind
    /// POSIX `errno`, or 0 when the issue is not an error.
    public let errorCode: Int32

    public var message: String {
        errorCode == 0 ? kind.title : String(cString: strerror(errorCode))
    }
}

public struct ScanStatistics: Sendable, Hashable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var otherEntries = 0
    /// Files reached again through another hard link. Shown, not summed.
    public var hardLinkDuplicates = 0
    /// Folders reached again through a firmlink or a folder hard link. Not entered, not summed.
    public var foldersAlreadyCounted = 0
    public var duration: Duration = .zero
}

public struct ScanResult: Sendable {
    public var tree: FileTree
    public let options: ScanOptions
    /// Up to ``ScanOptions/maxRecordedIssues`` issues, in the order they were found.
    public let issues: [ScanIssue]
    /// Exact count per kind, including issues not kept in ``issues``.
    public let issueCounts: [ScanIssue.Kind: Int]
    public let statistics: ScanStatistics
    public let finishedAt: Date

    public var totalIssueCount: Int { issueCounts.values.reduce(0, +) }
    public var failureCount: Int {
        issueCounts.filter { $0.key.isFailure }.values.reduce(0, +)
    }
}

public enum ScanError: Error, Equatable, LocalizedError {
    case notADirectory(String)
    case cannotOpen(String, Int32)
    case cannotConfigureCloudPolicy(Int32)
    case tooManyItems

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "“\(path)” is not a folder."
        case .cannotOpen(let path, let code): "Could not open “\(path)”: \(String(cString: strerror(code)))."
        case .cannotConfigureCloudPolicy(let code): "Could not enforce the cloud-file safety policy: \(String(cString: strerror(code))). No scan was started."
        case .tooManyItems: "The folder holds more items than Disk Analyzer can index in one scan."
        }
    }
}
