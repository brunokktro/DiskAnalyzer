import Foundation

/// Items staged for review before an explicit "Move to Trash".
///
/// The Collector never stores overlapping paths: adding a folder absorbs any collected
/// descendants, and adding something inside a collected folder is a no-op. Totals count
/// each file system object once: a second path to an inode the scan already counted
/// (hard link) adds nothing, so no byte is counted twice.
public struct Collector: Sendable, Equatable {
    public struct Item: Sendable, Hashable, Identifiable {
        /// Why an item cannot be moved to the Trash from Disk Analyzer.
        public enum Limitation: Sendable, Hashable {
            /// The scan could not look inside it (unreadable, excluded, another volume, or a
            /// folder already counted at another path):
            /// its sizes are not real, so a confirmation based on them would understate the move.
            case notMeasured
            /// Its name, or an ancestor's, is not valid UTF-8, so the path may not name this item.
            case invalidName
            /// What is at the path now is not what the scan measured: another type, or a file with
            /// another size or modification date (typical of restored results). The sizes shown
            /// would be wrong and the object may be a different one; rescan first.
            case changedSinceScan
        }

        public var id: String { path }
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let allocatedSize: Int64
        public let logicalSize: Int64
        public let itemCount: Int64
        /// The entry is a hard link: moving it to the Trash frees nothing while other links remain.
        public let hasOtherHardLinks: Bool
        /// `(st_dev, st_ino)` when the item was collected. The Trash refuses the path if it now names another object.
        public let identity: FileIdentity?
        /// A second path to an inode the scan already counted elsewhere. Shown, never added to totals.
        public let isHardLinkDuplicate: Bool
        /// Set when the item must not be moved to the Trash at all.
        public let limitation: Limitation?
        /// Folders inside this one that the scan could not measure: the real content is larger than shown.
        public let unmeasuredFolders: Int

        public init(path: String, name: String, isDirectory: Bool, allocatedSize: Int64, logicalSize: Int64, itemCount: Int64,
                    hasOtherHardLinks: Bool = false, identity: FileIdentity? = nil, isHardLinkDuplicate: Bool = false,
                    limitation: Limitation? = nil, unmeasuredFolders: Int = 0) {
            self.path = PathUtilities.standardize(path)
            self.name = name
            self.isDirectory = isDirectory
            self.allocatedSize = allocatedSize
            self.logicalSize = logicalSize
            self.itemCount = itemCount
            self.hasOtherHardLinks = hasOtherHardLinks
            self.identity = identity
            self.isHardLinkDuplicate = isHardLinkDuplicate
            self.limitation = limitation
            self.unmeasuredFolders = unmeasuredFolders
        }

        public var isTrashable: Bool { limitation == nil }

        public func size(_ metric: SizeMetric) -> Int64 {
            metric == .allocated ? allocatedSize : logicalSize
        }
    }

    public enum AddOutcome: Equatable, Sendable {
        case added(absorbed: Int)
        case alreadyCovered(by: String)
        case refused(Item.Limitation)
    }

    public private(set) var items: [Item] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var totalAllocated: Int64 { total(.allocated) }
    public var totalLogical: Int64 { total(.logical) }

    /// Sum over distinct objects: hard-link duplicates and repeated identities are skipped.
    public func total(_ metric: SizeMetric) -> Int64 {
        var seen = Set<FileIdentity>()
        var sum: Int64 = 0
        for item in items where !item.isHardLinkDuplicate {
            if let identity = item.identity, !item.isDirectory, !seen.insert(identity).inserted { continue }
            sum += item.size(metric)
        }
        return sum
    }

    /// Collected folders that contain at least one folder the scan could not measure.
    public var unmeasuredFolders: Int { items.reduce(0) { $0 + $1.unmeasuredFolders } }

    public func contains(path: String) -> Bool {
        let path = PathUtilities.standardize(path)
        return items.contains { $0.path == path }
    }

    /// The collected path that already includes `path`, if any.
    public func coveringItem(for path: String) -> Item? {
        let path = PathUtilities.standardize(path)
        return items.first { PathUtilities.isSameOrDescendant(path, of: $0.path) }
    }

    @discardableResult
    public mutating func add(_ item: Item) -> AddOutcome {
        if let limitation = item.limitation { return .refused(limitation) }
        if let covering = coveringItem(for: item.path) { return .alreadyCovered(by: covering.path) }
        let before = items.count
        items.removeAll { PathUtilities.isSameOrDescendant($0.path, of: item.path) }
        let absorbed = before - items.count
        items.append(item)
        return .added(absorbed: absorbed)
    }

    @discardableResult
    public mutating func remove(path: String) -> Bool {
        let path = PathUtilities.standardize(path)
        let before = items.count
        items.removeAll { $0.path == path }
        return items.count != before
    }

    public mutating func removeAll() { items.removeAll() }

    public func sorted(by metric: SizeMetric) -> [Item] {
        items.sorted { $0.size(metric) != $1.size(metric) ? $0.size(metric) > $1.size(metric) : $0.path < $1.path }
    }
}

public extension Collector.Item {
    /// Captures the node as scanned, plus its current identity and link count from `lstat(2)`.
    init(tree: FileTree, id: NodeID) {
        let node = tree[id]
        let path = tree.path(of: id)
        var info = stat()
        let exists = lstat(path, &info) == 0
        self.init(
            path: path,
            name: node.name,
            isDirectory: node.isDirectory,
            allocatedSize: node.allocatedSize,
            logicalSize: node.logicalSize,
            itemCount: node.itemCount,
            hasOtherHardLinks: exists && !node.isDirectory && info.st_nlink > 1,
            identity: exists ? FileIdentity(info) : nil,
            isHardLinkDuplicate: node.flags.contains(.hardLinkDuplicate),
            limitation: Self.limitation(of: id, in: tree) ?? (exists && !Self.matchesScan(node, info) ? .changedSinceScan : nil),
            unmeasuredFolders: node.isDirectory ? Self.unmeasuredFolders(below: id, in: tree) : 0
        )
    }

    /// Why `id` cannot be trashed, if anything. Pure tree check, no disk access.
    static func limitation(of id: NodeID, in tree: FileTree) -> Limitation? {
        if !tree.hasExactPath(id) { return .invalidName }
        return tree[id].flags.isDisjoint(with: .notMeasured) ? nil : .notMeasured
    }

    /// The object at the path has the type the scan recorded and, for a file, the same size and
    /// modification date (computed as the scanner does, so equal values compare exactly).
    static func matchesScan(_ node: FileNode, _ info: stat) -> Bool {
        let type = info.st_mode & S_IFMT
        switch node.kind {
        case .directory: return type == S_IFDIR
        case .symlink: return type == S_IFLNK
        case .other: return true
        case .file:
            let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            return type == S_IFREG && Int64(info.st_size) == node.logicalSize && mtime == node.modificationTime
        }
    }

    private static func unmeasuredFolders(below id: NodeID, in tree: FileTree) -> Int {
        var count = 0
        tree.walkDescendants(of: id) { _, node in
            guard node.isDirectory else { return false }
            if !node.flags.isDisjoint(with: .notMeasured) { count += 1 }
            return true
        }
        return count
    }
}
