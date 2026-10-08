import AppKit
import DiskAnalyzerCore
import Foundation

/// End-to-end check of the real GUI app, used by `scripts/smoke-test.sh`:
///
///     DiskAnalyzer --smoke-test <folder> --smoke-report <out.json> [--smoke-snapshot <out.png>]
///
/// It scans `<folder>` through the same ``AppModel`` the window uses, waits for the
/// window to render, exercises navigation, filters, the treemap and the Collector,
/// then writes a JSON report and quits. With `--smoke-snapshot base.png` it also saves
/// `base-explore.png`, `base-largest.png` and `base-collector.png` window captures. The Trash step uses ``RecordingTrashMover``,
/// so nothing is moved. Exit codes: 0 pass, 1 an assertion failed, 2 timeout.
struct SmokeTest: Equatable {
    let folder: URL
    let report: URL
    let snapshot: URL?

    static func parse(_ arguments: [String]) -> SmokeTest? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let folder = value(after: "--smoke-test"), let report = value(after: "--smoke-report") else { return nil }
        return SmokeTest(folder: URL(fileURLWithPath: folder, isDirectory: true),
                         report: URL(fileURLWithPath: report),
                         snapshot: value(after: "--smoke-snapshot").map { URL(fileURLWithPath: $0) })
    }

    @MainActor
    func run(model: AppModel) async {
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
            model.mode = .largest
            let largest = model.largestRows
            await capture("largest", window: window, facts: &facts)
            facts["largest_top5"] = largest.prefix(5).map(\.name)
            checks["largest_items_listed"] = !largest.isEmpty

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
                checks["tree_updated_after_trash"] = (model.tree?.root.allocatedSize ?? before) == before - first.allocated
                checks["collector_emptied"] = model.collector.isEmpty
                checks["file_still_on_disk"] = FileManager.default.fileExists(atPath: tree.path(of: first.id))
            }
            model.trashSummary = nil
            model.mode = .explore
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
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
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
