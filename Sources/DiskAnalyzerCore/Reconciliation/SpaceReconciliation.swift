import Foundation

/// How far the volume may move before a scan counts as changed or stale. Each threshold
/// is the larger of a floor and a fraction (1/divisor) of the volume capacity.
public struct FreshnessPolicy: Sendable, Hashable {
    public var toleranceFloor: Int64
    public var toleranceDivisor: Int64
    public var staleFloor: Int64
    public var staleDivisor: Int64

    public init(toleranceFloor: Int64, toleranceDivisor: Int64, staleFloor: Int64, staleDivisor: Int64) {
        self.toleranceFloor = toleranceFloor
        self.toleranceDivisor = max(1, toleranceDivisor)
        self.staleFloor = staleFloor
        self.staleDivisor = max(1, staleDivisor)
    }

    /// Unchanged up to max(100 MB, 0.1% of capacity); stale from max(1 GB, 1% of capacity).
    public static let standard = FreshnessPolicy(toleranceFloor: 100_000_000, toleranceDivisor: 1_000,
                                                 staleFloor: 1_000_000_000, staleDivisor: 100)

    public func changeTolerance(capacity: Int64) -> Int64 { max(toleranceFloor, max(0, capacity) / toleranceDivisor) }
    public func staleThreshold(capacity: Int64) -> Int64 { max(staleFloor, max(0, capacity) / staleDivisor) }
}

public enum Freshness: Sendable, Hashable {
    /// Used space is within ``FreshnessPolicy/changeTolerance`` of the scan-end baseline.
    case unchanged(delta: Int64)
    /// Used space moved by more than the tolerance since the scan finished.
    case changedSinceScan(delta: Int64)
    /// Used space moved by at least ``FreshnessPolicy/staleThreshold``.
    case stale(delta: Int64)
    /// No comparable baseline: the volume is not mounted, did not report its space, or
    /// the baseline belongs to another volume.
    case unknown

    public var delta: Int64? {
        switch self {
        case .unchanged(let delta), .changedSinceScan(let delta), .stale(let delta): delta
        case .unknown: nil
        }
    }
}

public enum Completeness: Sendable, Hashable {
    case complete
    /// The scan could not read some folders or entries; measured totals are a lower bound.
    case partial(failures: Int)
}

/// Explains a volume's used space with what a scan measured, without forcing the numbers
/// to agree. Two identities always hold, with every bucket zero or positive:
///
/// - `attributed + unattributed == accountedUsed`
/// - `attributed + measuredBeyondUsed == measuredAllocated`
///
/// `accountedUsed` is the used space the results stand for: used at the end of the full scan
/// plus what folder rescans measured. Without folder rescans it equals `used`.
///
/// `measuredBeyondUsed` is how much the scan measured on top of the volume's used space
/// (clones and shared blocks report their full allocation per file). It is shown, never
/// clamped away. A folder-only scan is never compared with the volume: its volume buckets are `nil`.
public struct SpaceReconciliation: Sendable, Hashable {
    public let scope: CoverageScope
    public let volumeName: String?
    public let mountPath: String?
    public let baselineDate: Date?
    public let capacity: Int64?
    /// Used space at the end of the scan: capacity minus available.
    public let used: Int64?
    public let available: Int64?
    /// Used space the results stand for: ``used`` plus ``rescanAllocatedChange``, never below
    /// zero. The volume buckets and freshness are computed against it.
    public let accountedUsed: Int64?
    public let availableForImportantUsage: Int64?
    /// `availableForImportantUsage - available` when it is not negative: space macOS reports
    /// it can reclaim (caches, local snapshots) for important data. An estimate.
    public let purgeableEstimate: Int64?
    /// Allocated total of the scan, unchanged.
    public let measuredAllocated: Int64
    /// Folders and entries the scan could not read (sizes unknown).
    public let inaccessible: Int
    /// Folders not entered on purpose: other volumes, exclusions, already counted at another path.
    public let skipped: Int
    // Volume scope only.
    public let attributed: Int64?
    public let unattributed: Int64?
    public let measuredBeyondUsed: Int64?
    /// Used space at scan end minus at scan start (the full scan; folder rescans never change it).
    public let changeDuringScan: Int64?
    /// What folder rescans changed in the measured allocation since the full scan.
    public let rescanAllocatedChange: Int64
    /// Used space now minus ``accountedUsed``. Space that changed outside rescanned folders
    /// after the full scan shows up here.
    public let changeSinceScan: Int64?
    public let currentBaselineDate: Date?
    public let freshness: Freshness
    public let completeness: Completeness

    public init(snapshot: ScanSnapshot, current: VolumeBaseline?, policy: FreshnessPolicy = .standard) {
        let result = snapshot.result
        let end = snapshot.endBaseline
        scope = snapshot.scope
        volumeName = end?.volumeName
        mountPath = end?.mountPath
        baselineDate = end?.capturedAt
        capacity = end?.totalCapacity
        used = end?.used
        available = end?.availableCapacity
        availableForImportantUsage = end?.availableForImportantUsage
        if let important = end?.availableForImportantUsage, let free = end?.availableCapacity, free >= 0, important >= free {
            purgeableEstimate = SafeArithmetic.difference(important, free)
        } else {
            purgeableEstimate = nil
        }
        measuredAllocated = result.tree.root.allocatedSize
        inaccessible = result.failureCount
        skipped = result.totalIssueCount - result.failureCount
        completeness = result.failureCount == 0 ? .complete : .partial(failures: result.failureCount)
        rescanAllocatedChange = snapshot.rescanAllocatedChange
        let accounted = end?.used.map { max(0, SafeArithmetic.saturatingSum($0, snapshot.rescanAllocatedChange)) }
        accountedUsed = accounted

        if snapshot.scope == .volume, let accounted, measuredAllocated >= 0 {
            attributed = min(measuredAllocated, accounted)
            unattributed = max(0, accounted - measuredAllocated)
            measuredBeyondUsed = max(0, measuredAllocated - accounted)
        } else {
            attributed = nil
            unattributed = nil
            measuredBeyondUsed = nil
        }

        if let start = snapshot.startBaseline, let end, start.isSameVolume(as: end), let a = start.used, let b = end.used {
            changeDuringScan = SafeArithmetic.difference(b, a)
        } else {
            changeDuringScan = nil
        }

        if let current, let end, current.isSameVolume(as: end), let now = current.used, let accounted,
           let delta = SafeArithmetic.difference(now, accounted) {
            let capacity = current.totalCapacity ?? end.totalCapacity ?? 0
            changeSinceScan = delta
            currentBaselineDate = current.capturedAt
            if delta.magnitude >= UInt64(policy.staleThreshold(capacity: capacity)) {
                freshness = .stale(delta: delta)
            } else if delta.magnitude > UInt64(policy.changeTolerance(capacity: capacity)) {
                freshness = .changedSinceScan(delta: delta)
            } else {
                freshness = .unchanged(delta: delta)
            }
        } else {
            changeSinceScan = nil
            currentBaselineDate = nil
            freshness = .unknown
        }
    }

    /// `true` only for whole-volume scans with a used figure. Folder scans never are.
    public var comparesWithVolume: Bool { scope == .volume && used != nil }
}

/// Short labels shown next to a scan. Each pairs a symbol with text, never color alone.
public enum ScanLabel: Sendable, Hashable {
    case complete
    case partial(failures: Int)
    case wholeVolume
    case folderOnly
    case changedSinceScan(delta: Int64)
    case stale(delta: Int64)
    case freshnessUnknown
    case restored(savedAt: Date)

    public var title: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        case .wholeVolume: "Whole volume"
        case .folderOnly: "Folder only"
        case .changedSinceScan: "Changed since scan"
        case .stale: "Stale"
        case .freshnessUnknown: "Cannot compare with the volume now"
        case .restored: "Restored"
        }
    }

    public var detail: String {
        switch self {
        case .complete: "Every folder in the scan was read."
        case .partial(let failures): "\(failures) \(failures == 1 ? "item" : "items") could not be read, so totals are a lower bound."
        case .wholeVolume: "The scan covers the whole volume and is compared with its used space."
        case .folderOnly: "The scan covers one folder. It is never compared with the volume's used space."
        case .changedSinceScan(let delta): "The volume's used space moved by \(SizeFormatting.signed(delta)) more than the results account for."
        case .stale(let delta): "The volume's used space moved by \(SizeFormatting.signed(delta)) more than the results account for. Rescan for current results."
        case .freshnessUnknown: "The volume's current space could not be compared with the scan."
        case .restored(let date): "Restored from a scan saved \(date.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    public var symbolName: String {
        switch self {
        case .complete: "checkmark.seal"
        case .partial: "exclamationmark.triangle"
        case .wholeVolume: "internaldrive"
        case .folderOnly: "folder"
        case .changedSinceScan: "arrow.triangle.2.circlepath"
        case .stale: "clock.badge.exclamationmark"
        case .freshnessUnknown: "questionmark.circle"
        case .restored: "clock.arrow.circlepath"
        }
    }

    /// Labels for a scan: completeness, coverage, freshness (only when it is not unchanged),
    /// and where the results came from.
    public static func labels(for reconciliation: SpaceReconciliation, restoredAt: Date?) -> [ScanLabel] {
        var labels: [ScanLabel] = []
        switch reconciliation.completeness {
        case .complete: labels.append(.complete)
        case .partial(let failures): labels.append(.partial(failures: failures))
        }
        labels.append(reconciliation.scope == .volume ? .wholeVolume : .folderOnly)
        switch reconciliation.freshness {
        case .unchanged: break
        case .changedSinceScan(let delta): labels.append(.changedSinceScan(delta: delta))
        case .stale(let delta): labels.append(.stale(delta: delta))
        case .unknown: labels.append(.freshnessUnknown)
        }
        if let restoredAt { labels.append(.restored(savedAt: restoredAt)) }
        return labels
    }
}

extension SizeFormatting {
    /// `+1.2 GB`, `−300 MB` or `0 bytes`.
    public static func signed(_ bytes: Int64) -> String {
        if bytes == 0 { return string(0) }
        return (bytes > 0 ? "+" : "−") + string(bytes == .min ? .max : Swift.abs(bytes))
    }
}
