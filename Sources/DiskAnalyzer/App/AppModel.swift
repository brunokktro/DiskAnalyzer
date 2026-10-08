import AppKit
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

struct TrashSummary: Identifiable {
    let id = UUID()
    let moved: Int
    let freedAllocated: Int64
    let problems: [TrashOutcome]
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
        case explore, largest
        var id: String { rawValue }
        var title: String { self == .explore ? "Explore" : "Largest Items" }
        var symbol: String { self == .explore ? "square.grid.3x3.square" : "list.number" }
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
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let trashMover: any TrashMover
    var trashMoverForTesting: any TrashMover { trashMover }
    @ObservationIgnored private var rowsCache: (key: RowsKey, rows: [EntryRow])?
    @ObservationIgnored private var largestCache: (key: RowsKey, rows: [EntryRow])?
    @ObservationIgnored private var tilesCache: (key: TilesKey, tiles: [TreemapTile])?

    private enum Keys {
        static let metric = "sizeMetric"
        static let staysOnVolume = "staysOnVolume"
    }

    init(defaults: UserDefaults = .standard, trashMover: any TrashMover = SystemTrashMover()) {
        self.defaults = defaults
        self.trashMover = trashMover
        metric = defaults.string(forKey: Keys.metric).flatMap(SizeMetric.init(rawValue:)) ?? .allocated
        staysOnVolume = defaults.object(forKey: Keys.staysOnVolume) as? Bool ?? true
        refreshVolumes()
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

    func rescan() {
        guard let scanRoot else { return }
        startScan(scanRoot, preservingFocus: tree.map { $0.path(of: focus) })
    }

    func startScan(_ requested: URL, preservingFocus focusPath: String? = nil) {
        let url = URL(fileURLWithPath: VolumeLocator.preferredScanRoot(for: requested.path(percentEncoded: false)), isDirectory: true)
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        scanRoot = url
        phase = .scanning
        progress = nil
        let options = ScanOptions(root: url, staysOnVolume: staysOnVolume)
        scanTask = Task { [weak self] in
            // Held strongly for the duration of the scan; cancellation ends it promptly.
            guard let model = self else { return }
            do {
                let result = try await DiskScanner().scan(options) { update in
                    Task { @MainActor in model.receive(update, generation: generation) }
                }
                model.finishScan(result, generation: generation, focusPath: focusPath)
            } catch is CancellationError {
                model.scanWasCancelled(generation: generation)
            } catch {
                model.failScan(error, generation: generation)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Waits for the running scan, if any. Used by the smoke test.
    func waitForScan() async {
        await scanTask?.value
    }

    private func receive(_ update: ScanProgress, generation: Int) {
        guard generation == scanGeneration, isScanning else { return }
        progress = update
    }

    private func finishScan(_ result: ScanResult, generation: Int, focusPath: String?) {
        guard generation == scanGeneration else { return }
        let previousRoot = tree?.rootPath
        lastResult = result
        tree = result.tree
        treeVersion += 1
        invalidateCaches()
        focus = focusPath.flatMap { result.tree.nodeID(forPath: $0) } ?? FileTree.rootID
        listSelection = []
        hover.tile = nil
        rebaseCollector(onto: result.tree, sameRoot: previousRoot == result.tree.rootPath)
        phase = .ready
        scanTask = nil
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
        var refused = 0
        for id in ids where id != FileTree.rootID && tree.contains(id) {
            if case .refused = collector.add(Collector.Item(tree: tree, id: id)) { refused += 1 }
        }
        if refused > 0 {
            alertMessage = refused == 1
                ? "One item was not added: the scan could not look inside it or its name is not valid, so its size is unknown."
                : "\(refused) items were not added: the scan could not look inside them or their names are not valid, so their size is unknown."
        }
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
        trashSummary = TrashSummary(moved: outcomes.filter(\.succeeded).count, freedAllocated: freed,
                                    problems: outcomes.filter { !$0.succeeded })
    }

    // MARK: - Export

    func exportIssues() {
        guard let result = lastResult else { return }
        save(CSVExport.issues(result.issues), suggestedName: "Disk Analyzer - Skipped Items.csv")
    }

    func exportLargest() {
        guard let tree else { return }
        save(CSVExport.items(largestRows.map(\.id), in: tree), suggestedName: "Disk Analyzer - Largest Items.csv")
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

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
