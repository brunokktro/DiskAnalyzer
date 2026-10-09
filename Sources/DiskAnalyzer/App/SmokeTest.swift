import AppKit
import DiskAnalyzerCore
import Foundation

/// End-to-end check of the real GUI app, used by `scripts/smoke-test.sh`:
///
///     DiskAnalyzer --smoke-test <folder> --smoke-report <out.json> [--smoke-store <db>] [--smoke-snapshot <out.png>]
///     DiskAnalyzer --smoke-restore <first-report.json> --smoke-report <out.json> --smoke-store <db>
///
/// The second form is a relaunch: it checks that the app restored the scan saved by the first
/// run, matching its final totals, without starting any scan. Saved scans go to `--smoke-store`
/// (default: next to the report), never to the user's store. System Settings is never opened.
///
/// It scans `<folder>` through the same ``AppModel`` the window uses, waits for the
/// window to render, exercises navigation, filters, the treemap and the Collector,
/// then writes a JSON report and quits. With `--smoke-snapshot base.png` it also saves
/// `base-explore.png`, `base-folders.png`, `base-files.png`, `base-trash.png` and
/// `base-collector.png` window captures. The Trash step uses ``RecordingTrashMover``,
/// so nothing is moved. Exit codes: 0 pass, 1 an assertion failed, 2 timeout.
struct SmokeTest: Equatable {
    /// Folder to scan, in the first form.
    let folder: URL?
    /// Report of the first run, in the relaunch form.
    let restoreExpectation: URL?
    let report: URL
    let snapshot: URL?
    let store: URL

    static func parse(_ arguments: [String]) -> SmokeTest? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let report = value(after: "--smoke-report") else { return nil }
        let folder = value(after: "--smoke-test").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let expectation = value(after: "--smoke-restore").map { URL(fileURLWithPath: $0) }
        guard (folder == nil) != (expectation == nil) else { return nil }
        let reportURL = URL(fileURLWithPath: report)
        return SmokeTest(folder: folder, restoreExpectation: expectation, report: reportURL,
                         snapshot: value(after: "--smoke-snapshot").map { URL(fileURLWithPath: $0) },
                         store: value(after: "--smoke-store").map { URL(fileURLWithPath: $0) }
                            ?? reportURL.deletingLastPathComponent().appending(path: "smoke-store.sqlite"))
    }

    @MainActor
    func run(model: AppModel) async {
        if let restoreExpectation { return await runRestoreCheck(model: model, expectation: restoreExpectation) }
        guard let folder else { exit(1) }
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(120))
            FileHandle.standardError.write(Data("smoke test timed out\n".utf8))
            exit(2)
        }
        var checks: [String: Bool] = [:]
        var facts: [String: Any] = [:]

        try? await Task.sleep(for: .milliseconds(500))
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        checks["window_visible"] = window != nil
        facts["window_title_before_scan"] = window?.title ?? ""

        model.startScan(folder)
        checks["scanning_state_entered"] = model.isScanning
        await model.waitForScan()
        checks["scan_ready"] = model.tree != nil && !model.isScanning

        if let tree = model.tree, let result = model.lastResult {
            facts["root_path"] = tree.rootPath
            facts["allocated_bytes"] = tree.root.allocatedSize
            facts["logical_bytes"] = tree.root.logicalSize
            facts["items"] = tree.root.itemCount
            facts["issues"] = Dictionary(uniqueKeysWithValues: result.issueCounts.map { ($0.key.rawValue, $0.value) })
            facts["scan_ms"] = Double(result.statistics.duration.components.attoseconds) / 1e15 + Double(result.statistics.duration.components.seconds) * 1000

            let rows = model.rows
            facts["top_level_rows"] = rows.map(\.name)
            checks["rows_sorted_by_size"] = rows.map(\.allocated) == rows.map(\.allocated).sorted(by: >)

            let tiles = model.tiles(for: CGSize(width: 800, height: 600))
            facts["treemap_tiles"] = tiles.count
            checks["treemap_has_tiles"] = !tiles.isEmpty

            await capture("explore", window: window, facts: &facts)

            model.mode = .folders
            let biggestFolders = model.largestFolderRows
            facts["biggest_folders_top5"] = biggestFolders.prefix(5).map(\.name)
            checks["biggest_folders_listed"] = !biggestFolders.isEmpty
            checks["biggest_folders_only_folders"] = biggestFolders.allSatisfy(\.isDirectory)
            checks["biggest_folders_sorted_by_size"] = biggestFolders.map(\.allocated) == biggestFolders.map(\.allocated).sorted(by: >)
            checks["space_hogs_are_top_level"] = model.spaceHogRows.allSatisfy { tree[$0.id].parent == FileTree.rootID }
            await capture("folders", window: window, facts: &facts)

            model.mode = .files
            let largest = model.largestRows
            await capture("files", window: window, facts: &facts)
            facts["biggest_files_top5"] = largest.prefix(5).map(\.name)
            checks["biggest_files_listed"] = !largest.isEmpty

            let trash = model.trashInsight
            facts["trash_allocated_bytes"] = trash.allocated
            facts["trash_logical_bytes"] = trash.logical
            facts["trash_items"] = trash.items
            checks["trash_measured_explicitly"] = trash.coverage == .measured && trash.allocated > 0 && trash.items > 0
            checks["trash_can_be_opened"] = trash.primaryFolderID != nil
            model.showTrash()
            checks["trash_navigation"] = trash.primaryFolderID == model.focus
            await capture("trash", window: window, facts: &facts)
            model.focus(on: FileTree.rootID)
            model.mode = .explore

            if let folderRow = rows.first(where: \.isDirectory) {
                model.focus(on: folderRow.id)
                checks["drill_down"] = model.focus == folderRow.id && model.canGoUp
                model.goUp()
                checks["go_up"] = model.focus == FileTree.rootID
            }

            model.filter.nameContains = "movie"
            let filtered = model.largestRows.map(\.name)
            facts["filtered_largest"] = filtered
            let expectsMatch = largest.contains { $0.name.localizedCaseInsensitiveContains("movie") }
            checks["filter_applied"] = filtered.allSatisfy { $0.localizedCaseInsensitiveContains("movie") }
                && filtered.count <= largest.count && (!expectsMatch || !filtered.isEmpty)
            model.filter = FileFilter()

            // A folder the scan could not list must not be offered to the Trash.
            if let unmeasured = (0..<tree.count).map(NodeID.init).first(where: { $0 != FileTree.rootID && tree[$0].isDirectory && tree[$0].flags.contains(.unreadable) }) {
                facts["unmeasured_folder"] = tree.path(of: unmeasured)
                checks["unmeasured_folder_not_collectable"] = !model.canCollect(unmeasured)
            }

            if let first = largest.first {
                model.collect([first.id])
                checks["collector_add"] = model.collector.count == 1 && model.isCollectorPresented
                await capture("collector", window: window, facts: &facts)
                let before = tree.root.allocatedSize
                model.performTrash()
                let recorded = (model.trashMoverForTesting as? RecordingTrashMover)?.paths ?? []
                checks["trash_validated_and_requested"] = recorded == [tree.path(of: first.id)]
                checks["trash_marked_changed_after_move"] = model.trashInsight.coverage == .changedSinceScan
                checks["tree_updated_after_trash"] = (model.tree?.root.allocatedSize ?? before) == before - first.allocated
                checks["collector_emptied"] = model.collector.isEmpty
                checks["file_still_on_disk"] = FileManager.default.fileExists(atPath: tree.path(of: first.id))
            }
            model.trashSummary = nil
            model.mode = .explore

            // Saved scan and labels. The fixture is a folder, so it must never be compared with the volume.
            await model.waitForPersistence()
            checks["snapshot_saved"] = model.recentScans.count == 1 && model.recentScans.first?.availability == .available
                && model.persistenceProblem == nil
            let labels = model.scanLabels
            facts["scan_labels"] = labels.map(\.title)
            checks["folder_scan_labelled_folder_only"] = labels.contains(.folderOnly) && !labels.contains(.wholeVolume)
            if let reconciliation = model.reconciliation {
                checks["folder_scan_not_compared_with_volume"] = !reconciliation.comparesWithVolume
                    && reconciliation.attributed == nil && reconciliation.unattributed == nil && reconciliation.measuredBeyondUsed == nil
                checks["reconciliation_measured_matches_tree"] = reconciliation.measuredAllocated == model.tree?.root.allocatedSize
                checks["partial_label_matches_failures"] = labels.contains(.partial(failures: result.failureCount)) == (result.failureCount > 0)
            } else {
                checks["folder_scan_not_compared_with_volume"] = false
            }

            // Rescan This Folder: a finished rescan replaces the subtree; a cancelled one changes nothing.
            let folders = (model.tree.map { tree in tree.children(of: FileTree.rootID).filter { model.canRescanFolder($0) } }) ?? []
            if let first = folders.first, let tree = model.tree {
                let path = tree.path(of: first)
                let startsBefore = model.scanStartCount
                let duplicatesBefore = model.lastResult?.statistics.hardLinkDuplicates
                model.rescanFolder(first)
                checks["folder_rescan_started"] = model.isScanning && model.rescanningFolder == path
                await model.waitForScan()
                checks["folder_rescan_replaced_subtree"] = !model.isScanning && model.context?.rescannedFolders.last == path
                    && model.tree?.nodeID(forPath: path) != nil && model.scanStartCount == startsBefore + 1
                // The fixture's hard link spans two top-level folders: it must stay counted once.
                checks["folder_rescan_keeps_hard_link_counted_once"] = duplicatesBefore != nil
                    && model.lastResult?.statistics.hardLinkDuplicates == duplicatesBefore
                await model.waitForPersistence()

                let versionBefore = model.treeVersion
                let totalsBefore = model.tree.map { [$0.root.allocatedSize, $0.root.logicalSize, $0.root.itemCount] }
                let rescannedBefore = model.context?.rescannedFolders
                let savedBefore = model.recentScans.first?.summary.savedAt
                model.rescanFolder(folders.last ?? first)
                model.cancelScan()
                await model.waitForScan()
                await model.waitForPersistence()
                checks["cancelled_folder_rescan_keeps_results"] = !model.isScanning && model.treeVersion == versionBefore
                    && model.tree.map { [$0.root.allocatedSize, $0.root.logicalSize, $0.root.itemCount] } == totalsBefore
                    && model.context?.rescannedFolders == rescannedBefore
                let savedAfter = await model.store?.summaries().first?.savedAt
                checks["cancelled_folder_rescan_keeps_saved_snapshot"] = savedBefore != nil && savedAfter == savedBefore
                facts["rescanned_folders"] = model.context?.rescannedFolders ?? []
            }

            // Storage Settings: the recording opener checks that macOS handles the pane URL,
            // records the request and opens nothing.
            model.openStorageSettings()
            let opener = model.settingsOpenerForTesting as? RecordingSettingsOpener
            checks["storage_settings_pane_requested"] = model.lastStorageSettingsOutcome == .openedStoragePane
                && opener?.opened == [StorageSettings.paneURL.absoluteString]
            model.alertMessage = nil

            await model.waitForPersistence()
            if let tree = model.tree {
                facts["final_root"] = tree.rootPath
                facts["final_allocated_bytes"] = tree.root.allocatedSize
                facts["final_logical_bytes"] = tree.root.logicalSize
                facts["final_items"] = tree.root.itemCount
            }
        }

        // "Macintosh HD" from the Open panel arrives as "/": the model must start on the Data
        // volume, like the sidebar. The scan is cancelled at once; only the chosen root matters.
        model.startScan(URL(fileURLWithPath: "/", isDirectory: true))
        let startupRoot = model.scanRoot?.path(percentEncoded: false) ?? ""
        model.cancelScan()
        await model.waitForScan()
        facts["startup_disk_scan_root"] = startupRoot
        checks["startup_disk_scans_data_volume"] = PathUtilities.standardize(startupRoot) == VolumeLocator.preferredScanRoot(for: "/")

        facts["window_title_after_scan"] = window?.title ?? ""

        let passed = checks.values.allSatisfy { $0 }
        let payload: [String: Any] = ["passed": passed, "checks": checks, "facts": facts]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report)
        }
        watchdog.cancel()
        exit(passed ? 0 : 1)
    }

    /// Relaunch check: the scan saved by the first run is on screen, with its final totals,
    /// and no scan was started, not at launch and not after a quiet second.
    @MainActor
    private func runRestoreCheck(model: AppModel, expectation: URL) async {
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(60))
            FileHandle.standardError.write(Data("smoke restore check timed out\n".utf8))
            exit(2)
        }
        var checks: [String: Bool] = [:]
        var facts: [String: Any] = [:]
        let expected = (try? Data(contentsOf: expectation))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["facts"] as? [String: Any] ?? [:]

        await model.waitForRestore()
        try? await Task.sleep(for: .milliseconds(500))
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        checks["window_visible"] = window != nil
        checks["restored_at_launch"] = model.tree != nil && model.context?.restoredAt != nil && !model.isScanning
        checks["no_scan_started_at_launch"] = model.scanStartCount == 0
        if let tree = model.tree {
            facts["root_path"] = tree.rootPath
            facts["allocated_bytes"] = tree.root.allocatedSize
            facts["logical_bytes"] = tree.root.logicalSize
            facts["items"] = tree.root.itemCount
            checks["restored_root_matches"] = tree.rootPath == expected["final_root"] as? String
            checks["restored_totals_match"] = tree.root.allocatedSize == (expected["final_allocated_bytes"] as? NSNumber)?.int64Value
                && tree.root.logicalSize == (expected["final_logical_bytes"] as? NSNumber)?.int64Value
                && tree.root.itemCount == (expected["final_items"] as? NSNumber)?.int64Value
        }
        checks["restored_rescanned_folders"] = (model.context?.rescannedFolders ?? []) == (expected["rescanned_folders"] as? [String] ?? [])
        checks["recent_scans_listed"] = model.recentScans.count == 1
        facts["scan_labels"] = model.scanLabels.map(\.title)
        checks["restored_label_shown"] = model.scanLabels.contains { if case .restored = $0 { true } else { false } }
        await capture("restored", window: window, facts: &facts)

        try? await Task.sleep(for: .seconds(1))
        checks["still_no_scan_after_idle"] = model.scanStartCount == 0 && !model.isScanning
        facts["scan_start_count"] = model.scanStartCount

        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let payload: [String: Any] = ["passed": passed, "checks": checks, "facts": facts]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report)
        }
        watchdog.cancel()
        exit(passed ? 0 : 1)
    }

    /// Lets SwiftUI render the current state, then saves the window next to `snapshot`.
    @MainActor
    private func capture(_ name: String, window: NSWindow?, facts: inout [String: Any]) async {
        guard let snapshot else { return }
        try? await Task.sleep(for: .milliseconds(700))
        let base = snapshot.deletingPathExtension()
        let target = base.deletingLastPathComponent().appending(path: base.lastPathComponent + "-\(name).png")
        guard let view = window?.contentView, let image = Self.render(view) else {
            facts["snapshot_error_\(name)"] = "could not render the window"
            return
        }
        do {
            try image.write(to: target)
            facts["snapshot_\(name)"] = target.path(percentEncoded: false)
        } catch {
            facts["snapshot_error_\(name)"] = error.localizedDescription
        }
    }

    @MainActor
    private static func render(_ view: NSView) -> Data? {
        guard let sourceRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: sourceRep)
        guard let source = sourceRep.cgImage else { return nil }
        let width = source.width, height = source.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: opaque).representation(using: .png, properties: [:])
    }
}

/// Trash stand-in for the smoke test: validates through ``TrashPolicy`` like the real
/// flow, records the request and leaves the file where it is.
final class RecordingTrashMover: TrashMover, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] { lock.withLock { recorded } }

    func moveToTrash(_ url: URL) throws -> URL? {
        lock.withLock { recorded.append(PathUtilities.standardize(url.path(percentEncoded: false))) }
        return nil
    }
}

/// System Settings stand-in for the smoke test: asks macOS whether the URL has a handler,
/// records the request and opens nothing.
final class RecordingSettingsOpener: SettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var opened: [String] { lock.withLock { recorded } }

    func canOpen(_ url: URL) -> Bool { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }

    func open(_ url: URL) -> Bool {
        lock.withLock { recorded.append(url.absoluteString) }
        return true
    }

    func openApplication(bundleIdentifier: String) -> Bool {
        lock.withLock { recorded.append(bundleIdentifier) }
        return true
    }
}
