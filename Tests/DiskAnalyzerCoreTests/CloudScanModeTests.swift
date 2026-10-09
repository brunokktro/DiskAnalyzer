import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

@Suite("Cloud-safe scan modes")
struct CloudScanModeTests {
    @Test func localOnlyIsTheDefault() {
        let options = ScanOptions(root: URL(fileURLWithPath: "/fixture"))
        #expect(options.cloudScanMode == .localOnly)
    }

    @Test func datalessFoldersAreSkippedOnlyInLocalMode() {
        let dataless = CloudTraversalPolicy.datalessFlag
        #expect(CloudTraversalPolicy.isDataless(dataless))
        #expect(!CloudTraversalPolicy.shouldEnterDirectory(flags: dataless, mode: .localOnly))
        #expect(CloudTraversalPolicy.shouldEnterDirectory(flags: dataless, mode: .cloudCatalog))
        #expect(CloudTraversalPolicy.shouldEnterDirectory(flags: 0, mode: .localOnly))
    }

    @Test func localPolicyIsAppliedAndRestoredOnTheCallingThread() throws {
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let before = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        #expect(before >= 0)
        let token = try DatalessMaterializationPolicy.apply(.localOnly)
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
        token.restore()
        #expect(getiopolicy_np(type, IOPOL_SCOPE_THREAD) == before)
    }

    @Test func largerUsedSpaceProducesALongerFirstScanRange() {
        let small = ScanDurationEstimate.make(estimatedBytes: 40 * 1_073_741_824, previous: nil,
                                              previousMode: nil, mode: .localOnly)
        let large = ScanDurationEstimate.make(estimatedBytes: 800 * 1_073_741_824, previous: nil,
                                              previousMode: nil, mode: .localOnly)
        #expect(small.basis == .usedBytes)
        #expect(large.lowerSeconds > small.lowerSeconds)
        #expect(large.upperSeconds > small.upperSeconds)
    }

    @Test func cloudCatalogShowsAWiderSlowerRange() {
        let bytes: Int64 = 400 * 1_073_741_824
        let local = ScanDurationEstimate.make(estimatedBytes: bytes, previous: nil, previousMode: nil, mode: .localOnly)
        let cloud = ScanDurationEstimate.make(estimatedBytes: bytes, previous: nil, previousMode: nil, mode: .cloudCatalog)
        #expect(cloud.lowerSeconds >= local.lowerSeconds)
        #expect(cloud.upperSeconds > local.upperSeconds)
    }

    @Test func previousScanCalibratesTheNextEstimate() {
        var statistics = ScanStatistics()
        statistics.duration = .seconds(100)
        let estimate = ScanDurationEstimate.make(estimatedBytes: nil, previous: statistics,
                                                 previousMode: .localOnly, mode: .localOnly)
        #expect(estimate.basis == .previousScan)
        #expect(estimate.lowerSeconds == 60)
        #expect(estimate.upperSeconds == 200)
    }

    @Test func cloudModeSurvivesSaveAndRestore() async throws {
        let fixture = try TemporaryFixture()
        let result = try fixture.scan { $0.cloudScanMode = .cloudCatalog }
        let temporary = try TemporaryStore()
        let store = SnapshotStore(url: temporary.url)
        try await store.save(snapshot(of: result))
        let restored = try #require(await store.restorableSnapshot())
        #expect(restored.result.options.cloudScanMode == .cloudCatalog)
    }
}
