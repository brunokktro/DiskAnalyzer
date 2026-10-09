import AppKit
import Darwin
import DiskAnalyzerCore
import Foundation
import Observation

/// One row of the hierarchy list. A value type so `Table` can sort it with key paths.
struct EntryRow: Identifiable, Hashable {
    let id: NodeID
    let name: String
    let allocated: Int64
    let logical: Int64
    let items: Int64
    let modified: Date
    let kind: NodeKind
    let category: FileCategory
    let flags: NodeFlags
    let kindLabel: String

    init(tree: FileTree, id: NodeID) {
        let node = tree[id]
        self.id = id
        name = node.name
        allocated = node.allocatedSize
        logical = node.logicalSize
        items = node.itemCount
        modified = node.modificationDate
        kind = node.kind
        category = FileCategory.classify(node)
        flags = node.flags
        kindLabel = Self.label(node, category: category)
    }

    func size(_ metric: SizeMetric) -> Int64 { metric == .allocated ? allocated : logical }

    var isDirectory: Bool { kind == .directory }

    private static func label(_ node: FileNode, category: FileCategory) -> String {
        switch node.kind {
        case .directory: node.isPackage ? "Package" : "Folder"
        case .symlink: "Alias (symbolic link)"
        case .other: node.flags.contains(.unreadable) ? "Unreadable" : "Special file"
        case .file:
            category == .other ? ((node.name as NSString).pathExtension.uppercased().nilIfEmpty.map { "\($0) file" } ?? "File")
                : String(category.title.dropLast(category.title.hasSuffix("s") ? 1 : 0))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the treemap pointer is over. Kept separate from ``AppModel`` so mouse movement
/// only invalidates the views that draw the hover state.
@MainActor @Observable
final class HoverState {
    var tile: TreemapTile?
}

/// What the current results are about, beyond the tree: which root, which scope, the volume
/// baselines around the scan and, for results read back from disk, when they were saved.
struct SnapshotContext {
    var root: RootIdentity
    var scope: CoverageScope
    var startBaseline: VolumeBaseline?
    var endBaseline: VolumeBaseline?
    var rescannedFolders: [String]
    /// Measured allocation change of the folder rescans (see ``ScanSnapshot/rescanAllocatedChange``).
    var rescanAllocatedChange: Int64 = 0
    /// When the results were saved, if they were restored instead of scanned in this session.
    var restoredAt: Date?
}

/// Opens System Settings through `NSWorkspace`, the public AppKit API.
struct WorkspaceSettingsOpener: SettingsOpening {
    func canOpen(_ url: URL) -> Bool { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    func openApplication(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        return NSWorkspace.shared.open(app)
    }
}

struct TrashSummary: Identifiable {
    let id = UUID()
    let moved: Int
    let freedAllocated: Int64
    let problems: [TrashOutcome]
}

struct TrashInsight {
    enum Coverage: Equatable {
        case measured
        case partial
        case changedSinceScan
        case empty
        case notInScan

        var title: String {
            switch self {
            case .measured: "Measured"
            case .partial: "Partial or unreadable"
            case .changedSinceScan: "Changed, rescan required"
            case .empty: "Empty in this scan"
            case .notInScan: "Not in current scan"
            }
        }

        var symbol: String {
            switch self {
            case .measured: "checkmark.circle"
            case .partial: "exclamationmark.triangle"
            case .changedSinceScan: "arrow.clockwise.circle"
            case .empty: "trash"
            case .notInScan: "scope"
            }
        }
    }

    let coverage: Coverage
    let folderIDs: [NodeID]
    let allocated: Int64
    let logical: Int64
    let items: Int64

    var primaryFolderID: NodeID? { folderIDs.first }
}

@MainActor @Observable
final class AppModel {
    enum Phase {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case explore, folders, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .explore: "Explore"
            case .folders: "Biggest Folders"
            case .files: "Biggest Files"
            }
        }
        var symbol: String {
            switch self {
            case .explore: "square.grid.3x3.square"
            case .folders: "folder.fill.badge.plus"
            case .files: "doc.text.magnifyingglass"
            }
        }
    }

    // MARK: Scan state

    private(set) var phase: Phase = .idle
    private(set) var progress: ScanProgress?
    private(set) var scanRoot: URL?
    private(set) var tree: FileTree?
    private(set) var lastResult: ScanResult?
    /// Bumped whenever the tree changes after a scan (items moved to the Trash).
    private(set) var treeVersion = 0
    private(set) var volumes: [VolumeInfo] = []
    /// Root identity, scope and baselines of the current results.
    private(set) var context: SnapshotContext?
    /// Volume figures read when the results were shown or last refreshed.
    private(set) var currentBaseline: VolumeBaseline?
    /// Saved scans, most recently saved first.
    private(set) var recentScans: [RecentScan] = []
    /// Folder being rescanned on its own, while a folder rescan runs.
    private(set) var rescanningFolder: String?
    /// Why the last save failed, if it did.
    private(set) var persistenceProblem: String?
    /// Number of scans started in this session (full, folder or new root). Restoring saved
    /// results never starts one; the smoke test checks this stays 0 at launch.
    private(set) var scanStartCount = 0
    /// A successful move can add content to a Trash folder that the current snapshot already contains.
    /// The old total stays visible but is labelled stale until that folder or the full root is rescanned.
    private(set) var trashNeedsRescan = false
    private(set) var lastStorageSettingsOutcome: StorageSettings.Outcome?

    // MARK: Navigation and selection

    var mode: Mode = .explore
    private(set) var focus: NodeID = FileTree.rootID
    var listSelection: Set<NodeID> = []
    var listSortOrder: [KeyPathComparator<EntryRow>] = []
    var quickLookURL: URL?

    // MARK: Presentation

    var isCollectorPresented = false
    var isIssuesPresented = false
    var isTrashConfirmationPresented = false
    var isReconciliationPresented = false
    var trashSummary: TrashSummary?
    var alertMessage: String?

    // MARK: Options

    var metric: SizeMetric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric); listSortOrder = [] }
    }
    var staysOnVolume: Bool {
        didSet { defaults.set(staysOnVolume, forKey: Keys.staysOnVolume) }
    }
    var filter = FileFilter()

    private(set) var collector = Collector()
    let hover = HoverState()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cancelledScanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let trashMover: any TrashMover
    @ObservationIgnored let store: SnapshotStore?
    @ObservationIgnored private let settingsOpener: any SettingsOpening
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    var trashMoverForTesting: any TrashMover { trashMover }
    var settingsOpenerForTesting: any SettingsOpening { settingsOpener }
    @ObservationIgnored private var rowsCache: (key: RowsKey, rows: [EntryRow])?
    @ObservationIgnored private var largestFoldersCache: (key: RowsKey, rows: [EntryRow])?
    @ObservationIgnored private var largestCache: (key: RowsKey, rows: [EntryRow])?
    @ObservationIgnored private var tilesCache: (key: TilesKey, tiles: [TreemapTile])?

    private enum Keys {
        static let metric = "sizeMetric"
        static let staysOnVolume = "staysOnVolume"
    }

    /// `store` is where scans are saved (`nil` turns saving off). The most recent compatible
    /// snapshot whose root is still the same folder is restored at launch; no scan starts.
    init(defaults: UserDefaults = .standard, trashMover: any TrashMover = SystemTrashMover(),
         store: SnapshotStore? = SnapshotStore(url: SnapshotStore.defaultURL()),
         settingsOpener: any SettingsOpening = WorkspaceSettingsOpener()) {
        self.defaults = defaults
        self.trashMover = trashMover
        self.store = store
        self.settingsOpener = settingsOpener
        metric = defaults.string(forKey: Keys.metric).flatMap(SizeMetric.init(rawValue:)) ?? .allocated
        staysOnVolume = defaults.object(forKey: Keys.staysOnVolume) as? Bool ?? true
        refreshVolumes()
        restoreLastScan()
    }

    var isScanning: Bool { if case .scanning = phase { true } else { false } }
    var hasResult: Bool { tree != nil }
    var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Scanning

    func refreshVolumes() {
        volumes = VolumeLocator.scannableVolumes()
    }

    func scanHome() { startScan(homeURL) }

    func scan(_ volume: VolumeInfo) { startScan(URL(fileURLWithPath: volume.scanPath, isDirectory: true)) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Analyze"
        panel.prompt = "Scan"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = scanRoot ?? homeURL
        if panel.runModal() == .OK, let url = panel.url { startScan(url) }
    }

    /// Rescan All: the whole current root again. Only ever started by the user.
    func rescan() {
        guard let scanRoot else { return }
        startScan(scanRoot, preservingFocus: tree.map { $0.path(of: focus) })
    }

    /// The folder Rescan This Folder and Scan as New Root act on from the menu: the single
    /// selected folder, else the folder being shown.
    var commandTargetFolder: NodeID? {
        guard let tree else { return nil }
        if listSelection.count == 1, let id = listSelection.first, tree.contains(id), tree[id].isDirectory { return id }
        return focus
    }

    func canRescanFolder(_ id: NodeID) -> Bool {
        guard let tree, !isScanning, context != nil else { return false }
        return SubtreeRescan.canRescan(id, in: tree)
    }

    /// Rescans one folder and swaps its subtree in only when that scan finishes. Cancelling or
    /// a failure keeps the previous results on screen and on disk.
    func rescanFolder(_ id: NodeID) {
        guard canRescanFolder(id), let tree, let snapshot = currentSnapshot else { return }
        // The baseline is the root's volume: with Stay on One Volume off the folder may be on another one.
        let rootPath = tree.rootPath
        if id == FileTree.rootID { return rescan() }
        let folder = tree.path(of: id)
        let focusPath = tree.path(of: focus)
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        scanStartCount += 1
        rescanningFolder = folder
        phase = .scanning
        progress = nil
        scanTask = Task { [weak self] in
            guard let model = self else { return }
            do {
                let updated = try await SubtreeRescan.run(
                    snapshot, folder: folder,
                    progress: { update in Task { @MainActor in model.receive(update, generation: generation) } })
                model.finishFolderRescan(updated, now: VolumeBaseline.capture(forPath: rootPath),
                                         generation: generation, focusPath: focusPath)
            } catch is CancellationError {
                model.endFolderRescan(generation: generation, error: nil)
            } catch {
                model.endFolderRescan(generation: generation, error: error)
            }
        }
    }

    func canScanAsNewRoot(_ id: NodeID) -> Bool {
        guard let tree, !isScanning, id != FileTree.rootID, tree.contains(id) else { return false }
        return tree[id].isDirectory && !tree.isRemoved(id) && tree.hasExactPath(id)
    }

    /// Starts a full scan rooted at this folder. The current root stays in Recent Scans.
    func scanAsNewRoot(_ id: NodeID) {
        guard canScanAsNewRoot(id), let tree else { return }
        startScan(tree.url(of: id))
    }

    private func finishFolderRescan(_ updated: ScanSnapshot, now: VolumeBaseline?, generation: Int, focusPath: String) {
        guard generation == scanGeneration else { return }
        let completedFolder = rescanningFolder
        lastResult = updated.result
        tree = updated.result.tree
        if let completedFolder {
            let homePath = PathUtilities.standardize(homeURL.path(percentEncoded: false))
            let trashFolders = TreeQueries.trashFolders(in: updated.tree, homePath: homePath, userID: getuid())
            if trashFolders.contains(where: { PathUtilities.isSameOrDescendant(updated.tree.path(of: $0), of: completedFolder) }) {
                trashNeedsRescan = false
            }
        }
        treeVersion += 1
        invalidateCaches()
        context?.rescannedFolders = updated.rescannedFolders
        context?.rescanAllocatedChange = updated.rescanAllocatedChange
        currentBaseline = now ?? currentBaseline
        focus = updated.tree.nodeID(forPath: focusPath) ?? FileTree.rootID
        listSelection = []
        hover.tile = nil
        rebaseCollector(onto: updated.tree, sameRoot: true)
        rescanningFolder = nil
        phase = .ready
        progress = nil
        scanTask = nil
        persist()
    }

    private func endFolderRescan(generation: Int, error: Error?) {
        guard generation == scanGeneration else { return }
        let folder = rescanningFolder.map { ($0 as NSString).lastPathComponent } ?? "the folder"
        rescanningFolder = nil
        phase = tree == nil ? .idle : .ready
        progress = nil
        scanTask = nil
        if let error {
            alertMessage = "Could not rescan “\(folder)”: \(error.localizedDescription) The previous results are kept."
        }
    }

    /// Title of the progress screen.
    var scanningTitle: String {
        if let rescanningFolder { return "Rescanning \((rescanningFolder as NSString).lastPathComponent)…" }
        return "Scanning \(scanRoot?.lastPathComponent ?? "")…"
    }

    func startScan(_ requested: URL, preservingFocus focusPath: String? = nil) {
        let url = URL(fileURLWithPath: VolumeLocator.preferredScanRoot(for: requested.path(percentEncoded: false)), isDirectory: true)
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        scanStartCount += 1
        rescanningFolder = nil
        scanRoot = url
        phase = .scanning
        progress = nil
        let options = ScanOptions(root: url, staysOnVolume: staysOnVolume)
        let rootPath = PathUtilities.standardize(url.path(percentEncoded: false))
        let identity = RootIdentity.capture(path: rootPath)
        let startBaseline = VolumeBaseline.capture(forPath: rootPath)
        scanTask = Task { [weak self] in
            // Held strongly for the duration of the scan; cancellation ends it promptly.
            guard let model = self else { return }
            do {
                let result = try await DiskScanner().scan(options) { update in
                    Task { @MainActor in model.receive(update, generation: generation) }
                }
                model.finishScan(result, generation: generation, focusPath: focusPath,
                                 identity: identity, startBaseline: startBaseline)
            } catch is CancellationError {
                model.scanWasCancelled(generation: generation)
            } catch {
                model.failScan(error, generation: generation)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        if let scanTask { cancelledScanTask = scanTask }
        scanTask = nil
    }

    /// Waits for the running scan, or for a cancelled one to unwind. Used by the smoke test.
    func waitForScan() async {
        await (scanTask ?? cancelledScanTask)?.value
    }

    private func receive(_ update: ScanProgress, generation: Int) {
        guard generation == scanGeneration, isScanning else { return }
        progress = update
    }

    private func finishScan(_ result: ScanResult, generation: Int, focusPath: String?,
                            identity: RootIdentity?, startBaseline: VolumeBaseline?) {
        guard generation == scanGeneration else { return }
        let previousRoot = tree?.rootPath
        lastResult = result
        tree = result.tree
        trashNeedsRescan = false
        treeVersion += 1
        invalidateCaches()
        focus = focusPath.flatMap { result.tree.nodeID(forPath: $0) } ?? FileTree.rootID
        listSelection = []
        hover.tile = nil
        rebaseCollector(onto: result.tree, sameRoot: previousRoot == result.tree.rootPath)
        let endBaseline = VolumeBaseline.capture(forPath: result.tree.rootPath)
        context = identity.map {
            SnapshotContext(root: $0, scope: .determine(rootPath: result.tree.rootPath, staysOnVolume: result.options.staysOnVolume),
                            startBaseline: startBaseline, endBaseline: endBaseline, rescannedFolders: [], restoredAt: nil)
        }
        currentBaseline = endBaseline
        phase = .ready
        scanTask = nil
        persist()
    }

    /// A rescan of the same folder keeps collected items, re-measured from the new tree.
    /// Items that are gone or can no longer be trashed are dropped, and the user is told.
    /// Scanning a different folder starts with an empty Collector.
    private func rebaseCollector(onto newTree: FileTree, sameRoot: Bool) {
        let previous = collector.items
        collector.removeAll()
        guard sameRoot, !previous.isEmpty else { return }
        var dropped = 0
        for item in previous {
            guard let id = newTree.nodeID(forPath: item.path),
                  case .added = collector.add(Collector.Item(tree: newTree, id: id)) else { dropped += 1; continue }
        }
        if dropped > 0 {
            alertMessage = "\(dropped) collected \(dropped == 1 ? "item is" : "items are") no longer in the scan results and \(dropped == 1 ? "was" : "were") removed from the Collector."
        }
    }

    private func scanWasCancelled(generation: Int) {
        guard generation == scanGeneration else { return }
        phase = tree == nil ? .idle : .ready
        if tree != nil, let current = lastResult { scanRoot = URL(fileURLWithPath: current.tree.rootPath) }
        progress = nil
    }

    private func failScan(_ error: Error, generation: Int) {
        guard generation == scanGeneration else { return }
        phase = .failed(error.localizedDescription)
        progress = nil
    }

    func closeScan() {
        cancelScan()
        tree = nil
        lastResult = nil
        scanRoot = nil
        context = nil
        currentBaseline = nil
        rescanningFolder = nil
        trashNeedsRescan = false
        collector.removeAll()
        invalidateCaches()
        phase = .idle
    }

    // MARK: - Navigation

    func focus(on id: NodeID) {
        guard let tree, tree.contains(id), tree[id].isDirectory, !tree.isRemoved(id) else { return }
        focus = id
        listSelection = []
        hover.tile = nil
    }

    var canGoUp: Bool { tree.map { focus != FileTree.rootID && $0.contains(focus) } ?? false }

    func goUp() {
        guard let tree, canGoUp else { return }
        let previous = focus
        focus(on: tree[focus].parent)
        listSelection = [previous]
    }

    /// Double-click / Return: enter folders, preview everything else.
    func activate(_ id: NodeID) {
        guard let tree else { return }
        if tree[id].isDirectory && !tree[id].isPackage { focus(on: id) } else { quickLook(id) }
    }

    func activateSelection() {
        if listSelection.count == 1, let id = listSelection.first { activate(id) }
    }

    var breadcrumb: [NodeID] { tree.map { $0.lineage(of: focus) } ?? [] }

    func displayName(_ id: NodeID) -> String {
        guard let tree else { return "" }
        if id == FileTree.rootID {
            let path = tree.rootPath
            if path == PathUtilities.standardize(homeURL.path(percentEncoded: false)) { return "Home" }
            if let volume = volumes.first(where: { $0.scanPath == path }) { return volume.name }
            return FileManager.default.displayName(atPath: path)
        }
        return tree[id].name
    }

    // MARK: - Derived content

    private struct RowsKey: Hashable {
        let version: Int, focus: NodeID, metric: SizeMetric, filter: FileFilter
    }

    private struct TilesKey: Hashable {
        let version: Int, focus: NodeID, metric: SizeMetric, filter: FileFilter, width: Int, height: Int
    }

    private func invalidateCaches() {
        rowsCache = nil
        largestFoldersCache = nil
        largestCache = nil
        tilesCache = nil
    }

    /// Children of the focus folder, filtered and sorted.
    var rows: [EntryRow] {
        guard let tree else { return [] }
        let key = RowsKey(version: treeVersion, focus: focus, metric: metric, filter: filter)
        let base: [EntryRow]
        if let cached = rowsCache, cached.key == key {
            base = cached.rows
        } else {
            base = TreeQueries.filteredChildren(in: tree, of: focus, metric: metric, filter: filter).map { EntryRow(tree: tree, id: $0) }
            rowsCache = (key, base)
        }
        return listSortOrder.isEmpty ? base : base.sorted(using: listSortOrder)
    }

    var largestFolderRows: [EntryRow] {
        guard let tree else { return [] }
        let key = RowsKey(version: treeVersion, focus: focus, metric: metric, filter: filter)
        if let cached = largestFoldersCache, cached.key == key { return sortedLargest(cached.rows) }
        let ids = TreeQueries.largestFolders(in: tree, under: focus,
            query: LargestFoldersQuery(limit: 500, metric: metric, filter: filter))
        let rows = ids.map { EntryRow(tree: tree, id: $0) }
        largestFoldersCache = (key, rows)
        return sortedLargest(rows)
    }

    /// Immediate child folders of the current root, used as stable in-app space-hog alerts.
    /// Ancestors and descendants are not mixed, so one subtree is never reported repeatedly.
    var spaceHogRows: [EntryRow] {
        guard let tree else { return [] }
        return tree.sortedChildren(of: FileTree.rootID, by: metric)
            .filter { tree[$0].isDirectory && !tree[$0].isPackage && tree[$0].size(metric) > 0 }
            .prefix(5)
            .map { EntryRow(tree: tree, id: $0) }
    }

    var largestRows: [EntryRow] {
        guard let tree else { return [] }
        let key = RowsKey(version: treeVersion, focus: focus, metric: metric, filter: filter)
        if let cached = largestCache, cached.key == key { return sortedLargest(cached.rows) }
        let ids = TreeQueries.largestItems(in: tree, under: focus, query: LargestItemsQuery(limit: 500, metric: metric, filter: filter))
        let rows = ids.map { EntryRow(tree: tree, id: $0) }
        largestCache = (key, rows)
        return sortedLargest(rows)
    }

    private func sortedLargest(_ rows: [EntryRow]) -> [EntryRow] {
        listSortOrder.isEmpty ? rows : rows.sorted(using: listSortOrder)
    }

    func tiles(for size: CGSize) -> [TreemapTile] {
        guard let tree, size.width >= 1, size.height >= 1 else { return [] }
        let key = TilesKey(version: treeVersion, focus: focus, metric: metric, filter: filter,
                           width: Int(size.width), height: Int(size.height))
        if let cached = tilesCache, cached.key == key { return cached.tiles }
        let tiles = TreemapLayout.layout(tree: tree, focus: focus,
                                         in: TreemapRect(x: 0, y: 0, width: Double(Int(size.width)), height: Double(Int(size.height))),
                                         metric: metric, filter: filter)
        tilesCache = (key, tiles)
        return tiles
    }

    var focusNode: FileNode? { tree.map { $0[focus] } }

    var trashInsight: TrashInsight {
        guard let tree else { return TrashInsight(coverage: .notInScan, folderIDs: [], allocated: 0, logical: 0, items: 0) }
        let homePath = PathUtilities.standardize(homeURL.path(percentEncoded: false))
        let ids = TreeQueries.trashFolders(in: tree, homePath: homePath, userID: getuid())
        let allocated = ids.reduce(Int64(0)) { $0 + tree[$1].allocatedSize }
        let logical = ids.reduce(Int64(0)) { $0 + tree[$1].logicalSize }
        let items = ids.reduce(Int64(0)) { $0 + tree[$1].itemCount }
        let hasUnmeasuredNode = ids.contains { !tree[$0].flags.isDisjoint(with: .notMeasured) }
        let hasTrashIssue = lastResult?.issues.contains { issue in
            let path = PathUtilities.standardize(issue.path)
            return path.contains("/.Trash/") || path.hasSuffix("/.Trash")
                || path.contains("/.Trashes/") || path.hasSuffix("/.Trashes")
        } ?? false

        let coverage: TrashInsight.Coverage
        if hasUnmeasuredNode || hasTrashIssue {
            coverage = .partial
        } else if trashNeedsRescan, !ids.isEmpty {
            coverage = .changedSinceScan
        } else if !ids.isEmpty {
            coverage = allocated == 0 && logical == 0 && items == 0 ? .empty : .measured
        } else {
            let root = PathUtilities.standardize(tree.rootPath)
            let homeTrash = homePath + "/.Trash"
            let dataHomeTrash = "/System/Volumes/Data" + homeTrash
            let uid = String(getuid())
            let mountTrash = VolumeLocator.mountPoint(of: root).map {
                PathUtilities.standardize($0.mountPath) + "/.Trashes/" + uid
            }
            let known = [homeTrash, dataHomeTrash] + [mountTrash].compactMap { $0 }
            let rootIsTrash = root.hasSuffix("/.Trash") || root.hasSuffix("/.Trashes/" + uid)
            let includesKnownTrash = known.contains { PathUtilities.isSameOrDescendant($0, of: root) }
            coverage = rootIsTrash || includesKnownTrash ? .empty : .notInScan
        }
        return TrashInsight(coverage: coverage, folderIDs: ids, allocated: allocated, logical: logical, items: items)
    }

    func showTrash() {
        guard let id = trashInsight.primaryFolderID else { return }
        focus(on: id)
        mode = .explore
    }

    var canRescanTrash: Bool {
        guard let id = trashInsight.primaryFolderID else { return false }
        return id == FileTree.rootID ? !isScanning && scanRoot != nil : canRescanFolder(id)
    }

    func rescanTrash() {
        guard let id = trashInsight.primaryFolderID else { return }
        if id == FileTree.rootID { rescan() } else { rescanFolder(id) }
    }

    @ObservationIgnored private var breakdownCache: (key: [Int], value: [FileCategory: (allocated: Int64, logical: Int64, count: Int)])?

    /// Bytes per category below the focus folder, cached per tree version.
    var categoryBreakdown: [FileCategory: (allocated: Int64, logical: Int64, count: Int)] {
        guard let tree else { return [:] }
        let key = [treeVersion, Int(focus)]
        if let cached = breakdownCache, cached.key == key { return cached.value }
        let value = TreeQueries.categoryBreakdown(in: tree, under: focus)
        breakdownCache = (key, value)
        return value
    }

    func relativeLocation(of id: NodeID) -> String {
        guard let tree else { return "" }
        let parent = tree[id].parent
        guard parent >= 0 else { return "" }
        let base = tree.path(of: focus)
        let full = tree.path(of: parent)
        if full == base { return "" }
        return String(full.dropFirst(base == "/" ? 1 : base.count + 1))
    }

    // MARK: - Finder actions

    /// `nil` when the node's path cannot be trusted to name it (a name that is not valid
    /// UTF-8 on the way), so no Finder action ever opens, reveals or copies another file.
    func url(of id: NodeID) -> URL? {
        guard let tree, tree.contains(id), tree.hasExactPath(id) else { return nil }
        return tree.url(of: id)
    }

    func hasExactPath(_ id: NodeID) -> Bool { tree.map { $0.contains(id) && $0.hasExactPath(id) } ?? false }

    private func reportInexactPaths(_ count: Int) {
        guard count > 0 else { return }
        alertMessage = count == 1
            ? "This item's name is not valid UTF-8, so Disk Analyzer cannot be sure which file the path names. Open its folder in Finder instead."
            : "\(count) items have names that are not valid UTF-8, so Disk Analyzer cannot be sure which files their paths name. Open their folders in Finder instead."
    }

    func quickLook(_ id: NodeID) {
        guard let url = url(of: id) else { return reportInexactPaths(1) }
        quickLookURL = url
    }

    func quickLookSelection() {
        if let id = listSelection.first { quickLook(id) } else if let id = hover.tile?.nodeID { quickLook(id) }
    }

    func reveal(_ ids: some Collection<NodeID>) {
        let urls = ids.compactMap(url(of:))
        reportInexactPaths(ids.count - urls.count)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealCollected(_ item: Collector.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// Reveals scan issues only when every component of the displayed path is exact.
    /// An invalid UTF-8 name is repaired for display, so using it with Finder could select
    /// a different file. Descendants inherit the same limitation.
    func revealIssues(_ ids: some Collection<ScanIssue.ID>) {
        guard let result = lastResult else { return }
        let invalidRoots = result.issues
            .filter { $0.kind == .invalidName }
            .map { PathUtilities.standardize($0.path) }
        let selected = result.issues.filter { ids.contains($0.id) }
        let urls = selected.compactMap { issue -> URL? in
            let path = PathUtilities.standardize(issue.path)
            guard !invalidRoots.contains(where: { PathUtilities.isSameOrDescendant(path, of: $0) }) else { return nil }
            return URL(fileURLWithPath: path)
        }
        reportInexactPaths(selected.count - urls.count)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPaths(_ ids: some Collection<NodeID>) {
        let urls = ids.compactMap(url(of:))
        reportInexactPaths(ids.count - urls.count)
        guard !urls.isEmpty else { return }
        let text = urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Collector and Trash

    func canCollect(_ id: NodeID) -> Bool {
        guard let tree, id != FileTree.rootID, tree.contains(id) else { return false }
        return Collector.Item.limitation(of: id, in: tree) == nil && collector.coveringItem(for: tree.path(of: id)) == nil
    }

    func collect(_ ids: some Collection<NodeID>) {
        guard let tree else { return }
        var refused = 0, changed = 0
        for id in ids where id != FileTree.rootID && tree.contains(id) {
            switch collector.add(Collector.Item(tree: tree, id: id)) {
            case .refused(.changedSinceScan): changed += 1
            case .refused: refused += 1
            default: break
            }
        }
        var lines: [String] = []
        if refused > 0 {
            lines.append(refused == 1
                ? "One item was not added: the scan could not look inside it or its name is not valid, so its size is unknown."
                : "\(refused) items were not added: the scan could not look inside them or their names are not valid, so their size is unknown.")
        }
        if changed > 0 {
            lines.append(changed == 1
                ? "One item was not added: it changed since the scan, so its size is out of date. Rescan its folder first."
                : "\(changed) items were not added: they changed since the scan, so their sizes are out of date. Rescan their folder first.")
        }
        if !lines.isEmpty { alertMessage = lines.joined(separator: "\n\n") }
        if !collector.isEmpty { isCollectorPresented = true }
    }

    func uncollect(_ item: Collector.Item) {
        collector.remove(path: item.path)
    }

    func clearCollector() { collector.removeAll() }

    /// The Trash acts on the scanned tree, so it waits while a scan is replacing it.
    var canTrash: Bool { !collector.isEmpty && !isScanning && tree != nil }

    func requestTrash() {
        guard canTrash else { return }
        isTrashConfirmationPresented = true
    }

    /// Moves every collected item to the Trash, after re-validating each one on disk.
    func performTrash() {
        guard canTrash, let tree else { return }
        let trashWasIncluded = trashInsight.primaryFolderID != nil
        let items = collector.items
        let policy = TrashPolicy(scanRoot: tree.rootPath)
        let outcomes = TrashOperation.run(items, policy: policy, mover: trashMover)
        var updated = tree
        var freed: Int64 = 0
        for (item, outcome) in zip(items, outcomes) where outcome.succeeded {
            collector.remove(path: item.path)
            if let id = updated.nodeID(forPath: item.path) {
                // A hard link frees nothing while another link to the same data remains.
                if !item.isHardLinkDuplicate && !item.hasOtherHardLinks { freed += updated[id].allocatedSize }
                updated.markRemoved(id)
            }
        }
        self.tree = updated
        treeVersion += 1
        invalidateCaches()
        listSelection = listSelection.filter { !updated.isRemoved($0) }
        if updated.isRemoved(focus) { focus = FileTree.rootID }
        hover.tile = nil
        let movedAnything = outcomes.contains(where: \.succeeded)
        if movedAnything, trashWasIncluded { trashNeedsRescan = true }
        trashSummary = TrashSummary(moved: outcomes.filter(\.succeeded).count, freedAllocated: freed,
                                    problems: outcomes.filter { !$0.succeeded })
        if movedAnything { persist() }
    }

    // MARK: - Export

    func exportIssues() {
        guard let result = lastResult else { return }
        save(CSVExport.issues(result.issues), suggestedName: "Disk Analyzer - Skipped Items.csv")
    }

    func exportLargestFolders() {
        guard let tree else { return }
        save(CSVExport.items(largestFolderRows.map(\.id), in: tree), suggestedName: "Disk Analyzer - Biggest Folders.csv")
    }

    func exportLargest() {
        guard let tree else { return }
        save(CSVExport.items(largestRows.map(\.id), in: tree), suggestedName: "Disk Analyzer - Biggest Files.csv")
    }

    private func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            alertMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }

    // MARK: - Saved scans

    /// The current results as a saveable snapshot (the tree includes Trash moves).
    var currentSnapshot: ScanSnapshot? {
        guard var result = lastResult, let tree, let context else { return nil }
        result.tree = tree
        return ScanSnapshot(result: result, root: context.root, scope: context.scope, startBaseline: context.startBaseline,
                            endBaseline: context.endBaseline, rescannedFolders: context.rescannedFolders,
                            rescanAllocatedChange: context.rescanAllocatedChange)
    }

    var reconciliation: SpaceReconciliation? {
        currentSnapshot.map { SpaceReconciliation(snapshot: $0, current: currentBaseline) }
    }

    var scanLabels: [ScanLabel] {
        reconciliation.map { ScanLabel.labels(for: $0, restoredAt: context?.restoredAt) } ?? []
    }

    /// Reads the volume figures again, for the "Changed since scan" comparison.
    func refreshCurrentBaseline() {
        guard let tree else { return }
        currentBaseline = VolumeBaseline.capture(forPath: tree.rootPath)
    }

    func showReconciliation() {
        guard tree != nil else { return }
        refreshCurrentBaseline()
        isReconciliationPresented = true
    }

    /// Reads the saved scans and shows the most recent one that is still the same folder.
    /// Never starts a scan.
    private func restoreLastScan() {
        guard let store else { return }
        let generation = scanGeneration
        restoreTask = Task { [weak self] in
            let notices = await store.takeNotices()
            let snapshot = await store.restorableSnapshot()
            let recents = await store.recentScans()
            guard let model = self else { return }
            model.recentScans = recents
            if !notices.isEmpty { model.alertMessage = notices.map(\.message).joined(separator: "\n\n") }
            guard let snapshot, generation == model.scanGeneration, model.tree == nil, !model.isScanning else { return }
            let savedAt = recents.first { $0.summary.root.key == snapshot.root.key }?.summary.savedAt ?? snapshot.result.finishedAt
            model.show(restored: snapshot, savedAt: savedAt)
        }
    }

    /// Waits for the launch restore. Used by the smoke test.
    func waitForRestore() async { await restoreTask?.value }

    /// Waits for pending saves. Used by the smoke test.
    func waitForPersistence() async { await persistTask?.value }

    func openRecent(_ scan: RecentScan) {
        guard let store, !isScanning else { return }
        guard scan.summary.isCompatible else {
            alertMessage = "This saved scan uses a format this version of Disk Analyzer cannot read. Scan the folder again."
            return
        }
        let availability = scan.summary.root.availability()
        guard availability.isRestorable else {
            alertMessage = "\(availability.title). \(availability.explanation)"
            return
        }
        let generation = scanGeneration
        Task { [weak self] in
            do {
                let snapshot = try await store.load(id: scan.id)
                guard let model = self, generation == model.scanGeneration, !model.isScanning else { return }
                model.show(restored: snapshot, savedAt: scan.summary.savedAt)
            } catch {
                self?.alertMessage = error.localizedDescription
            }
        }
    }

    private func show(restored snapshot: ScanSnapshot, savedAt: Date) {
        lastResult = snapshot.result
        tree = snapshot.tree
        trashNeedsRescan = false
        treeVersion += 1
        invalidateCaches()
        scanRoot = URL(fileURLWithPath: snapshot.tree.rootPath, isDirectory: true)
        context = SnapshotContext(root: snapshot.root, scope: snapshot.scope, startBaseline: snapshot.startBaseline,
                                  endBaseline: snapshot.endBaseline, rescannedFolders: snapshot.rescannedFolders,
                                  rescanAllocatedChange: snapshot.rescanAllocatedChange, restoredAt: savedAt)
        focus = FileTree.rootID
        listSelection = []
        hover.tile = nil
        collector.removeAll()
        currentBaseline = VolumeBaseline.capture(forPath: snapshot.tree.rootPath)
        phase = .ready
        progress = nil
    }

    /// Saves the current results, one save after another, off the main thread.
    private func persist() {
        guard let store, let snapshot = currentSnapshot else { return }
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value
            var problem: String?
            do {
                try await store.save(snapshot)
            } catch {
                problem = error.localizedDescription
            }
            let recents = await store.recentScans()
            guard let model = self else { return }
            model.persistenceProblem = problem
            model.recentScans = recents
        }
    }

    func openStorageSettings() {
        let outcome = StorageSettings.open(using: settingsOpener)
        lastStorageSettingsOutcome = outcome
        switch outcome {
        case .openedStoragePane: break
        case .openedSystemSettings: alertMessage = "System Settings is open. Choose General > Storage."
        case .failed: alertMessage = "Could not open System Settings. " + StorageSettings.manualInstructions
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
