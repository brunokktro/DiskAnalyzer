import Darwin
import Foundation

/// How a scan treats File Provider placeholders such as OneDrive, WorkDocs and iCloud Drive.
public enum CloudScanMode: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    /// Snapshot written before cloud behavior was recorded. Never offered for a new scan.
    case legacyUnspecified
    /// Measure content already represented locally. Dataless folders are not enumerated.
    case localOnly
    /// Enumerate dataless cloud folders. File contents are still never opened or read.
    case cloudCatalog

    public static let selectableCases: [CloudScanMode] = [.localOnly, .cloudCatalog]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .legacyUnspecified: "Legacy, cloud behavior unknown"
        case .localOnly: "Local files only"
        case .cloudCatalog: "Include cloud catalog"
        }
    }

    public var shortDetail: String {
        switch self {
        case .legacyUnspecified: "This snapshot predates cloud-mode tracking. Run a new full scan for known coverage."
        case .localOnly: "Does not enumerate dataless cloud folders. Fastest, safest and a lower-bound local view."
        case .cloudCatalog: "Enumerates remote folder metadata. Provider cache and scan time may grow."
        }
    }
}

/// Decisions derived from `st_flags`. Kept separate so the safety boundary has deterministic tests.
public enum CloudTraversalPolicy {
    /// `SF_DATALESS` from the macOS SDK's `sys/stat.h`.
    public static let datalessFlag: UInt32 = 0x4000_0000

    public static func isDataless(_ flags: UInt32) -> Bool {
        flags & datalessFlag != 0
    }

    public static func shouldEnterDirectory(flags: UInt32, mode: CloudScanMode) -> Bool {
        mode == .cloudCatalog || !isDataless(flags)
    }
}

/// Applies the VFS materialization policy to the scanner thread and restores what was there before.
/// The synchronous walk stays on this worker thread, so unrelated app I/O keeps its own policy.
struct DatalessMaterializationPolicy {
    private let previous: Int32
    private let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)

    static func apply(_ mode: CloudScanMode) throws -> DatalessMaterializationPolicy {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        guard previous >= 0 else { throw ScanError.cannotConfigureCloudPolicy(errno) }
        let requested = Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        guard setiopolicy_np(type, IOPOL_SCOPE_THREAD, requested) == 0 else {
            throw ScanError.cannotConfigureCloudPolicy(errno)
        }
        guard getiopolicy_np(type, IOPOL_SCOPE_THREAD) == requested else {
            _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous)
            throw ScanError.cannotConfigureCloudPolicy(EIO)
        }
        return DatalessMaterializationPolicy(previous: previous)
    }

    func restore() {
        _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous)
    }
}

/// A deliberately broad pre-scan estimate. Directory scans are metadata-bound, so item count,
/// provider latency and permissions matter more than file bytes. The range communicates that.
public struct ScanDurationEstimate: Sendable, Hashable {
    public enum Basis: Sendable, Hashable {
        case previousScan
        case usedBytes
        case unknown
    }

    public let lowerSeconds: Int
    public let upperSeconds: Int
    public let basis: Basis

    public static func make(estimatedBytes: Int64?, previous: ScanStatistics?,
                            previousMode: CloudScanMode?, mode: CloudScanMode) -> ScanDurationEstimate {
        if let previous {
            let components = previous.duration.components
            let seconds = max(1, Double(components.seconds) + Double(components.attoseconds) / 1e18)
            let previousMode = previousMode ?? .legacyUnspecified
            let multipliers: (Double, Double)
            if mode == .cloudCatalog {
                multipliers = previousMode == .cloudCatalog ? (0.6, 2.0) : (1.2, 6.0)
            } else {
                multipliers = previousMode == .cloudCatalog ? (0.3, 1.2) : (0.6, 2.0)
            }
            return range(seconds * multipliers.0, seconds * multipliers.1, basis: .previousScan)
        }

        guard let bytes = estimatedBytes, bytes > 0 else {
            return mode == .localOnly
                ? ScanDurationEstimate(lowerSeconds: 30, upperSeconds: 1_200, basis: .unknown)
                : ScanDurationEstimate(lowerSeconds: 300, upperSeconds: 7_200, basis: .unknown)
        }
        let gib = Double(bytes) / 1_073_741_824
        let local: (Double, Double)
        switch gib {
        case ..<50: local = (15, 300)
        case ..<250: local = (60, 600)
        case ..<500: local = (180, 1_200)
        case ..<1_000: local = (480, 2_400)
        default: local = (1_200, 5_400)
        }
        if mode == .localOnly { return range(local.0, local.1, basis: .usedBytes) }
        return range(max(300, local.0 * 2), min(14_400, local.1 * 4), basis: .usedBytes)
    }

    private static func range(_ lower: Double, _ upper: Double, basis: Basis) -> ScanDurationEstimate {
        ScanDurationEstimate(lowerSeconds: max(1, Int(lower.rounded(.down))),
                             upperSeconds: max(1, Int(upper.rounded(.up))), basis: basis)
    }
}
