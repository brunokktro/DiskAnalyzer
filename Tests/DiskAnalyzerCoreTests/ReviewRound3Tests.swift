import Foundation
import Testing
@testable import DiskAnalyzerCore

/// Review round 3 (fariseu-qa). The app builds its policy as `TrashPolicy(scanRoot:)`, so the
/// protected lists come from the defaults for the REAL account home. The fix tests use a fake
/// home; these feed the defaults the app actually uses into the policy. Text checks only
/// (`validatePath`): nothing on disk is read, so no cloud placeholder is ever downloaded.
@Suite("Review round 3: defaults the app really uses")
struct ReviewRound3DefaultsTests {
    private let home = PathUtilities.standardize(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))

    @Test func realHomeCloudDomainsAreRefusedAndTheirContentsAreNot() {
        let policy = TrashPolicy(scanRoot: home)
        for root in [home + "/Library/CloudStorage", home + "/Library/Mobile Documents"] {
            let domain = root + "/Example-Domain"
            #expect(policy.validatePath(root) != nil, "cloud root \(root) must be refused")
            #expect(policy.validatePath(domain) != nil, "cloud domain \(domain) must be refused")
            // Control: content below a domain stays movable, as in Finder.
            #expect(policy.validatePath(domain + "/Reports") == nil, "content of \(domain) must stay movable")
        }
    }

    @Test func realHomeMediaFoldersAreRefusedAndTheirContentsAreNot() {
        let policy = TrashPolicy(scanRoot: home)
        for name in ["Pictures", "Music", "Movies", "Public", "Desktop", "Documents", "Downloads"] {
            #expect(policy.validatePath(home + "/" + name) != nil, "~/\(name) must be refused")
            #expect(policy.validatePath(home + "/" + name + "/old-export") == nil, "~/\(name)/old-export must stay movable")
        }
        // The ancestor rule must not swallow ordinary home content.
        #expect(policy.validatePath(home + "/Projects") == nil)
    }

    @Test func dataVolumeTwinOfTheRealHomeIsProtectedToo() {
        let data = "/System/Volumes/Data" + home
        let policy = TrashPolicy(scanRoot: "/System/Volumes/Data")
        #expect(policy.validatePath(data) != nil)
        #expect(policy.validatePath(data + "/Library/CloudStorage/Example-Domain") != nil)
        #expect(policy.validatePath(data + "/Library/CloudStorage/Example-Domain/file.pdf") == nil)
    }

    @Test func everyStartupDiskEntryPointLandsOnTheSameRoot() {
        // Sidebar (volume list) and Open panel / startScan must agree on where "/" is scanned.
        #expect(VolumeLocator.preferredScanRoot(for: "/") == VolumeLocator.dataVolumePath(forMount: "/"))
        #expect(VolumeLocator.preferredScanRoot(for: "/Users") == "/Users")
    }
}
