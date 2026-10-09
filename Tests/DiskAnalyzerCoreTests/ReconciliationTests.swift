import AppKit
import Foundation
import Testing
@testable import DiskAnalyzerCore

private func baseline(total: Int64?, available: Int64?, important: Int64? = nil, uuid: String? = "VOL",
                      at seconds: Double = 1_700_000_000) -> VolumeBaseline {
    VolumeBaseline(capturedAt: Date(timeIntervalSince1970: seconds), volumeUUID: uuid, mountPath: "/Volumes/T",
                   volumeName: "T", totalCapacity: total, availableCapacity: available, availableForImportantUsage: important)
}

/// A volume-scope snapshot whose tree measures exactly `measured` allocated bytes.
private func volumeSnapshot(measured: Int64, start: VolumeBaseline?, end: VolumeBaseline?,
                            counts: [ScanIssue.Kind: Int] = [:], scope: CoverageScope = .volume) -> ScanSnapshot {
    syntheticSnapshot(makeTree([("f", measured, measured)]), counts: counts, scope: scope, start: start, end: end)
}

@Suite("Space reconciliation")
struct SpaceReconciliationTests {
    private static let gb: Int64 = 1_000_000_000

    @Test func partsAddUpAndNoBucketIsNegative() {
        // Deterministic sweep: measured below, equal to and above used.
        for measured in stride(from: Int64(0), through: 900 * Self.gb, by: Int(37 * Self.gb)) {
            for available in stride(from: Int64(0), through: 1_000 * Self.gb, by: Int(125 * Self.gb)) {
                let end = baseline(total: 1_000 * Self.gb, available: available, important: available + 7 * Self.gb)
                let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: measured, start: end, end: end), current: end)
                let used = 1_000 * Self.gb - available
                #expect(rec.used == used)
                #expect(rec.capacity == (rec.used ?? 0) + (rec.available ?? 0))
                #expect((rec.attributed ?? -1) + (rec.unattributed ?? -1) == used)
                #expect((rec.attributed ?? -1) + (rec.measuredBeyondUsed ?? -1) == measured)
                #expect(rec.measuredAllocated == measured)
                for bucket in [rec.attributed, rec.unattributed, rec.measuredBeyondUsed, rec.purgeableEstimate] {
                    #expect((bucket ?? 0) >= 0)
                }
            }
        }
    }

    @Test func measuredAboveUsedIsShownNotClamped() {
        let end = baseline(total: 500 * Self.gb, available: 400 * Self.gb)
        let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: 130 * Self.gb, start: end, end: end), current: end)
        #expect(rec.used == 100 * Self.gb)
        #expect(rec.measuredAllocated == 130 * Self.gb)
        #expect(rec.measuredBeyondUsed == 30 * Self.gb)
        #expect(rec.attributed == 100 * Self.gb)
        #expect(rec.unattributed == 0)
    }

    @Test func folderScansAreNeverComparedWithTheVolume() {
        let end = baseline(total: 500 * Self.gb, available: 100 * Self.gb)
        let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: 3 * Self.gb, start: end, end: end, scope: .folder), current: end)
        #expect(!rec.comparesWithVolume)
        #expect(rec.attributed == nil && rec.unattributed == nil && rec.measuredBeyondUsed == nil)
        #expect(rec.used == 400 * Self.gb) // the volume's figures are still shown, just not subtracted
        let labels = ScanLabel.labels(for: rec, restoredAt: nil)
        #expect(labels.contains(.folderOnly))
        #expect(!labels.contains(.wholeVolume))
    }

    @Test func purgeableIsTheImportantUsageMargin() {
        let end = baseline(total: 100 * Self.gb, available: 10 * Self.gb, important: 25 * Self.gb)
        #expect(SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: nil, end: end), current: nil).purgeableEstimate == 15 * Self.gb)
        let odd = baseline(total: 100 * Self.gb, available: 10 * Self.gb, important: 5 * Self.gb)
        #expect(SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: nil, end: odd), current: nil).purgeableEstimate == nil)
    }

    @Test func missingOrInconsistentFiguresAreNotGuessed() {
        for end in [baseline(total: nil, available: 1), baseline(total: 10, available: nil), baseline(total: 10, available: 20)] {
            let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: 5, start: end, end: end), current: end)
            #expect(rec.used == nil)
            #expect(rec.unattributed == nil)
            #expect(!rec.comparesWithVolume)
            #expect(rec.freshness == .unknown)
        }
        let noBaseline = SpaceReconciliation(snapshot: volumeSnapshot(measured: 5, start: nil, end: nil), current: nil)
        #expect(noBaseline.used == nil && noBaseline.freshness == .unknown)
    }

    @Test func changeDuringAndSinceTheScanAreSigned() {
        let start = baseline(total: 1_000 * Self.gb, available: 500 * Self.gb)
        let end = baseline(total: 1_000 * Self.gb, available: 498 * Self.gb)
        let now = baseline(total: 1_000 * Self.gb, available: 520 * Self.gb)
        let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: start, end: end), current: now)
        #expect(rec.changeDuringScan == 2 * Self.gb)
        #expect(rec.changeSinceScan == -22 * Self.gb)
    }

    @Test func freshnessComesFromTheCurrentBaseline() {
        let capacity = 1_000 * Self.gb // tolerance 1 GB, stale from 10 GB with the standard policy
        let end = baseline(total: capacity, available: 400 * Self.gb)
        func freshness(_ deltaUsed: Int64, uuid: String? = "VOL") -> Freshness {
            let now = baseline(total: capacity, available: 400 * Self.gb - deltaUsed, uuid: uuid)
            return SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end), current: now).freshness
        }
        #expect(freshness(0) == .unchanged(delta: 0))
        #expect(freshness(Self.gb) == .unchanged(delta: Self.gb))
        #expect(freshness(Self.gb + 1) == .changedSinceScan(delta: Self.gb + 1))
        #expect(freshness(-(Self.gb + 1)) == .changedSinceScan(delta: -(Self.gb + 1)))
        #expect(freshness(10 * Self.gb) == .stale(delta: 10 * Self.gb))
        #expect(freshness(-50 * Self.gb) == .stale(delta: -50 * Self.gb))
        #expect(freshness(0, uuid: "OTHER") == .unknown)

        let small = FreshnessPolicy.standard
        #expect(small.changeTolerance(capacity: 8 * Self.gb) == 100_000_000)
        #expect(small.staleThreshold(capacity: 8 * Self.gb) == Self.gb)
    }

    @Test func completenessFollowsTheFailures() {
        let end = baseline(total: 10 * Self.gb, available: 5 * Self.gb)
        let partial = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end,
                                                                   counts: [.notPermitted: 3, .otherVolume: 2]), current: end)
        #expect(partial.completeness == .partial(failures: 3))
        #expect(partial.inaccessible == 3)
        #expect(partial.skipped == 2)
        let complete = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end, counts: [.otherVolume: 2]), current: end)
        #expect(complete.completeness == .complete)
    }

    @Test func labelsDescribeTheState() {
        let end = baseline(total: 1_000 * Self.gb, available: 400 * Self.gb)
        let stale = baseline(total: 1_000 * Self.gb, available: 380 * Self.gb)
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end, counts: [.unreadable: 1]), current: stale)
        #expect(ScanLabel.labels(for: rec, restoredAt: saved) == [.partial(failures: 1), .wholeVolume, .stale(delta: 20 * Self.gb), .restored(savedAt: saved)])
        let fresh = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end), current: end)
        #expect(ScanLabel.labels(for: fresh, restoredAt: nil) == [.complete, .wholeVolume])
        let unknown = SpaceReconciliation(snapshot: volumeSnapshot(measured: 1, start: end, end: end), current: nil)
        #expect(ScanLabel.labels(for: unknown, restoredAt: nil).contains(.freshnessUnknown))
        for label in ScanLabel.labels(for: rec, restoredAt: saved) {
            #expect(!label.title.isEmpty && !label.detail.isEmpty && !label.symbolName.isEmpty)
        }
    }

    @Test func realBaselineReportsConsistentFigures() throws {
        let fixture = try TemporaryFixture(build: false)
        let now = try #require(VolumeBaseline.capture(forPath: fixture.rootPath))
        let total = try #require(now.totalCapacity), free = try #require(now.availableCapacity)
        #expect(now.used == total - free)
        #expect(now.volumeUUID != nil)
        #expect(now.isSameVolume(as: try #require(VolumeBaseline.capture(forPath: fixture.rootPath))))
    }

    @Test func scopeIsVolumeOnlyAtAVolumeRootThatStaysOnTheVolume() throws {
        let data = VolumeLocator.preferredScanRoot(for: "/")
        #expect(CoverageScope.determine(rootPath: data, staysOnVolume: true) == .volume)
        #expect(CoverageScope.determine(rootPath: data, staysOnVolume: false) == .folder)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #expect(CoverageScope.determine(rootPath: home, staysOnVolume: true) == .folder)
        let fixture = try TemporaryFixture(build: false)
        #expect(CoverageScope.determine(rootPath: fixture.rootPath, staysOnVolume: true) == .folder)
    }
}

@Suite("Storage Settings")
struct StorageSettingsTests {
    private final class Recorder: SettingsOpening {
        var handlesPane: Bool
        var paneOpens: Bool
        var appOpens: Bool
        var calls: [String] = []

        init(handlesPane: Bool, paneOpens: Bool, appOpens: Bool) {
            self.handlesPane = handlesPane
            self.paneOpens = paneOpens
            self.appOpens = appOpens
        }

        func canOpen(_ url: URL) -> Bool { calls.append("can:\(url.absoluteString)"); return handlesPane }
        func open(_ url: URL) -> Bool { calls.append("open:\(url.absoluteString)"); return paneOpens }
        func openApplication(bundleIdentifier: String) -> Bool { calls.append("app:\(bundleIdentifier)"); return appOpens }
    }

    @Test func opensThePaneWhenItIsHandled() {
        let recorder = Recorder(handlesPane: true, paneOpens: true, appOpens: true)
        #expect(StorageSettings.open(using: recorder) == .openedStoragePane)
        #expect(recorder.calls == ["can:\(StorageSettings.paneURL.absoluteString)", "open:\(StorageSettings.paneURL.absoluteString)"])
    }

    @Test func fallsBackToSystemSettingsThenToInstructions() {
        let unhandled = Recorder(handlesPane: false, paneOpens: true, appOpens: true)
        #expect(StorageSettings.open(using: unhandled) == .openedSystemSettings)
        #expect(!unhandled.calls.contains { $0.hasPrefix("open:") })
        let refused = Recorder(handlesPane: true, paneOpens: false, appOpens: true)
        #expect(StorageSettings.open(using: refused) == .openedSystemSettings)
        let nothing = Recorder(handlesPane: false, paneOpens: false, appOpens: false)
        #expect(StorageSettings.open(using: nothing) == .failed)
        #expect(StorageSettings.manualInstructions.contains("General > Storage"))
    }

    /// The pane URL names an extension that ships with this macOS, and System Settings
    /// handles the URL. Checked without opening anything.
    @Test func paneExistsOnThisMac() throws {
        #expect(NSWorkspace.shared.urlForApplication(toOpen: StorageSettings.paneURL) != nil)
        #expect(NSWorkspace.shared.urlForApplication(withBundleIdentifier: StorageSettings.systemSettingsBundleIdentifier) != nil)
        let plist = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/Storage.appex/Contents/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "com.apple.settings.Storage")
        #expect(StorageSettings.paneURL.absoluteString.hasSuffix("com.apple.settings.Storage"))
    }
}
