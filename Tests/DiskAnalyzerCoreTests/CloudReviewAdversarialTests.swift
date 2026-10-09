import Darwin
import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Adversarial review of 0.3.0 cloud modes (fariseu-qa, 2026-10-09).
/// These tests preserve the measured failure modes as permanent regression coverage.
@Suite("Review 0.3.0: cloud modes, adversarial")
struct CloudReviewAdversarialTests {
    private static let materialize = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)

    // MARK: - Gaps

    /// C2. A 0.2.0 snapshot has no `cloudScanMode`: it was taken with the process policy
    /// (materialization ON) and traversed whatever it met. Decoding it as `.localOnly` makes the UI
    /// show "Dataless cloud folders were protected from enumeration and download" about a scan
    /// that offered no such protection.
    @Test func legacySnapshotIsNotClaimedAsLocalOnly() throws {
        let fixture = try TemporaryFixture()
        let saved = try snapshot(of: try fixture.scan())
        let encoded = try SnapshotStore.encoder.encode(SnapshotDetails(saved))
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "cloudScanMode")
        let legacy = try SnapshotStore.decoder.decode(SnapshotDetails.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(legacy.cloudScanMode == nil)
        let restored = try legacy.snapshot(tree: saved.tree, root: saved.root, scope: saved.scope)
        #expect(restored.result.options.cloudScanMode == .legacyUnspecified)
    }

    /// C1. Real-world pair: scanner output on a real File Provider folder feeds the label text.
    /// Opt-in, metadata only: `DA_REVIEW_CLOUD_ROOT=<folder with dataless files>`. Run it under a
    /// process-level materialization OFF wrapper for a second layer of protection.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DA_REVIEW_CLOUD_ROOT"] != nil))
    func realPlaceholderFilesAreEnumeratedAndCountedAsLogicalBytes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DA_REVIEW_CLOUD_ROOT"])
        let result = try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: path, isDirectory: true)))
        let tree = result.tree
        var placeholderFiles = 0, placeholderLogical: Int64 = 0, placeholderAllocated: Int64 = 0
        for index in 0..<tree.count {
            let node = tree[NodeID(index)]
            guard node.kind == .file, node.flags.contains(.cloudPlaceholder) else { continue }
            placeholderFiles += 1
            placeholderLogical += node.logicalSize
            placeholderAllocated += node.allocatedSize
        }
        let counted = result.issueCounts[.cloudPlaceholder] ?? 0
        print("review: placeholderFiles=\(placeholderFiles) issues=\(counted) logical=\(placeholderLogical) allocated=\(placeholderAllocated)")
        #expect(placeholderFiles > 0, "the folder must contain dataless files for this attack")
        // Survives: allocated metric stays a local lower bound.
        #expect(placeholderAllocated == 0)
        // Survives: every placeholder issue is a file that IS in the tree.
        #expect(counted == placeholderFiles)
        let detail = ScanLabel.localFilesOnly(placeholders: counted).detail
        #expect(!detail.contains("not enumerated"))
        #expect(placeholderLogical == 0)
    }

    // MARK: - Attacks that should hold

    /// Both modes force OFF during the scan and restoration returns the thread to its prior value.
    @Test func policyRestoresANonDefaultPreviousThreadPolicy() throws {
        let original = getiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD)
        defer { _ = setiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD, original) }
        #expect(setiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD, Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)) == 0)
        let token = try DatalessMaterializationPolicy.apply(.cloudCatalog)
        #expect(getiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD) == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
        token.restore()
        #expect(getiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD) == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
    }

    /// The scanner restores the policy on the error path too (root is not a folder).
    @Test func scannerRestoresThePolicyWhenTheRootFails() throws {
        let fixture = try TemporaryFixture(build: false)
        let file = fixture.path("plain-file")
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let before = getiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD)
        #expect(throws: ScanError.self) {
            try DiskScanner.scanSynchronously(ScanOptions(root: URL(fileURLWithPath: file)))
        }
        #expect(getiopolicy_np(Self.materialize, IOPOL_SCOPE_THREAD) == before)
    }

    /// A future mode string must not crash the decoder; it fails as an unreadable snapshot.
    @Test func unknownFutureModeIsRejectedNotCrashed() throws {
        let fixture = try TemporaryFixture()
        let saved = try snapshot(of: try fixture.scan())
        let encoded = try SnapshotStore.encoder.encode(SnapshotDetails(saved))
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["cloudScanMode"] = "futureMode"
        let future = try SnapshotStore.decoder.decode(SnapshotDetails.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(throws: TreeCodec.DecodeError.self) {
            try future.snapshot(tree: saved.tree, root: saved.root, scope: saved.scope)
        }
    }

    @Test func versionTwoTreeBlobsRemainReadable() throws {
        let fixture = try TemporaryFixture()
        let original = try fixture.scan().tree
        var encoded = TreeCodec.encode(original)
        encoded[4] = 2
        encoded[5] = 0
        encoded[6] = 0
        encoded[7] = 0
        let decoded = try TreeCodec.decode(encoded)
        #expect(treesEqual(original, decoded))
        #expect(TreeCodec.formatVersion == 3)
        #expect(TreeCodec.isSupported(2))
    }
}
