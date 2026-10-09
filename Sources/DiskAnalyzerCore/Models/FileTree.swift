import Foundation

/// Index of a node inside a ``FileTree``. 32 bits keep the arena compact; a
/// scan stops with ``ScanError/tooManyItems`` before it could overflow.
public typealias NodeID = Int32

public enum NodeKind: UInt8, Sendable, Hashable {
    case directory
    case file
    case symlink
    /// Sockets, FIFOs, device nodes and entries whose metadata could not be read.
    case other
}

public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// A directory that Launch Services presents as a single document (`.app`, `.photoslibrary`...).
    public static let package = NodeFlags(rawValue: 1 << 0)
    /// Dot-file or `UF_HIDDEN`.
    public static let hidden = NodeFlags(rawValue: 1 << 1)
    /// Second or later path to an inode already counted in this scan. Shown, never summed.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 2)
    /// Directory that could not be listed, or entry whose metadata could not be read.
    public static let unreadable = NodeFlags(rawValue: 1 << 3)
    /// Moved to the Trash after the scan. Hidden from every listing and excluded from totals.
    public static let removed = NodeFlags(rawValue: 1 << 4)
    /// Mount point of another volume that the scan did not enter.
    public static let otherVolume = NodeFlags(rawValue: 1 << 5)
    /// Directory skipped because it matched an exclusion.
    public static let excluded = NodeFlags(rawValue: 1 << 6)
    /// The on-disk name is not valid UTF-8. The displayed name is a lossy repair, so the
    /// path built from it may point at a different object (or none).
    public static let invalidName = NodeFlags(rawValue: 1 << 7)
    /// Folder already reached through another path in this scan: an APFS firmlink
    /// (`/Users` and `/System/Volumes/Data/Users` are one folder) or a hard-linked folder.
    /// Not entered, and always set together with ``hardLinkDuplicate`` so it is never summed.
    public static let alreadyCounted = NodeFlags(rawValue: 1 << 8)
    /// File Provider item whose contents are not local. In local-only mode, a dataless
    /// directory also carries `excluded` because its descendants were intentionally not enumerated.
    public static let cloudPlaceholder = NodeFlags(rawValue: 1 << 9)

    /// Flags meaning the scan did not measure what is inside this node: its sizes are a
    /// lower bound (often zero), so it must not be offered for the Trash as if they were real.
    public static let notMeasured: NodeFlags = [.unreadable, .otherVolume, .excluded, .alreadyCounted]
}

/// One entry of the scanned hierarchy. Directory sizes are aggregates of their subtree.
public struct FileNode: Sendable, Hashable {
    public var name: String
    public var parent: NodeID
    public var kind: NodeKind
    public var flags: NodeFlags
    /// Bytes of content as reported by `st_size` (what Finder calls "size").
    public var logicalSize: Int64
    /// Bytes of storage the file system reports as allocated (`st_blocks * 512`).
    public var allocatedSize: Int64
    /// Number of non-directory entries counted in this subtree (1 for a file).
    public var itemCount: Int64
    /// `st_mtime` as seconds since 1970.
    public var modificationTime: Double
    public var childStart: Int32
    public var childCount: Int32

    public var isDirectory: Bool { kind == .directory }
    public var isPackage: Bool { flags.contains(.package) }
    public var modificationDate: Date { Date(timeIntervalSince1970: modificationTime) }

    public func size(_ metric: SizeMetric) -> Int64 {
        metric == .allocated ? allocatedSize : logicalSize
    }
}

/// Which size a view or query ranks by.
public enum SizeMetric: String, CaseIterable, Sendable, Identifiable {
    /// Storage the file system reports as allocated. Closest to "what deleting this frees",
    /// but not exact on APFS: clones, snapshots and compression share or hide blocks.
    case allocated
    /// Size of the content (`st_size`). Sparse and compressed files can be far larger than their allocation.
    case logical

    public var id: String { rawValue }
    public var title: String { self == .allocated ? "Allocated" : "Logical" }
}

/// Immutable-by-default, arena-allocated tree produced by ``DiskScanner``.
///
/// Children of every directory are stored contiguously in `childIndex` and sorted by
/// allocated size (largest first), so listings and the treemap never re-sort the arena.
public struct FileTree: Sendable {
    public static let rootID: NodeID = 0

    /// Absolute, standardized path of the scanned root. Never ends with `/` unless it is `/`.
    public let rootPath: String
    public private(set) var nodes: [FileNode]
    public private(set) var childIndex: [NodeID]
    /// `st_ino` of each file that had more than one link when it was scanned. Lets a folder
    /// rescan tell which inode a link that no longer exists named. Sparse: most files have one link.
    public private(set) var linkInodes: [NodeID: UInt64]

    init(rootPath: String, nodes: [FileNode], childIndex: [NodeID], linkInodes: [NodeID: UInt64] = [:]) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.childIndex = childIndex
        self.linkInodes = linkInodes
    }

    public var count: Int { nodes.count }
    public var root: FileNode { nodes[0] }

    public subscript(id: NodeID) -> FileNode { nodes[Int(id)] }

    public func contains(_ id: NodeID) -> Bool { id >= 0 && Int(id) < nodes.count }

    /// Live children (removed entries are skipped), largest allocated first.
    public func children(of id: NodeID) -> [NodeID] {
        let node = nodes[Int(id)]
        guard node.childCount > 0 else { return [] }
        let range = Int(node.childStart)..<Int(node.childStart + node.childCount)
        return childIndex[range].filter { !nodes[Int($0)].flags.contains(.removed) }
    }

    /// Live children sorted by the requested metric, largest first, ties broken by name.
    public func sortedChildren(of id: NodeID, by metric: SizeMetric) -> [NodeID] {
        let kids = children(of: id)
        guard metric == .logical else { return kids }
        return kids.sorted { lhs, rhs in
            let a = nodes[Int(lhs)], b = nodes[Int(rhs)]
            if a.logicalSize != b.logicalSize { return a.logicalSize > b.logicalSize }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Root first, `id` last.
    public func lineage(of id: NodeID) -> [NodeID] {
        var chain: [NodeID] = []
        var current = id
        while current >= 0 {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        return chain.reversed()
    }

    public func isAncestor(_ ancestor: NodeID, of id: NodeID) -> Bool {
        var current = nodes[Int(id)].parent
        while current >= 0 {
            if current == ancestor { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    /// True when the node or any ancestor was moved to the Trash.
    public func isRemoved(_ id: NodeID) -> Bool {
        var current = id
        while current >= 0 {
            if nodes[Int(current)].flags.contains(.removed) { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    public func path(of id: NodeID) -> String {
        if id == Self.rootID { return rootPath }
        var components: [String] = []
        var current = id
        while current > Self.rootID {
            components.append(nodes[Int(current)].name)
            current = nodes[Int(current)].parent
        }
        let relative = components.reversed().joined(separator: "/")
        return rootPath == "/" ? "/" + relative : rootPath + "/" + relative
    }

    /// `false` when the node's name, or an ancestor's, is not valid UTF-8. Its path is then
    /// built from a lossy repair and may name a different object, or none.
    public func hasExactPath(_ id: NodeID) -> Bool {
        !lineage(of: id).contains { nodes[Int($0)].flags.contains(.invalidName) }
    }

    public func url(of id: NodeID) -> URL {
        URL(fileURLWithPath: path(of: id), isDirectory: nodes[Int(id)].isDirectory)
    }

    /// Resolves an absolute path back to a live node, or `nil` if it is outside the tree or removed.
    public func nodeID(forPath path: String) -> NodeID? {
        let target = PathUtilities.standardize(path)
        if target == rootPath { return Self.rootID }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var current = Self.rootID
        for component in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = children(of: current).first(where: { nodes[Int($0)].name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Depth-first walk of live descendants (the start node is not visited).
    /// `body` returns `false` to skip the subtree below the visited node.
    public func walkDescendants(of start: NodeID, _ body: (NodeID, FileNode) -> Bool) {
        var stack = children(of: start).reversed() as [NodeID]
        while let id = stack.popLast() {
            let node = nodes[Int(id)]
            if body(id, node), node.isDirectory {
                stack.append(contentsOf: children(of: id).reversed())
            }
        }
    }

    /// Records the inode that identifies a hard-linked file across later folder rescans.
    /// The map stays sparse; callers use this only for a file known to participate in
    /// cross-boundary hard-link reconciliation.
    mutating func rememberLinkInode(_ inode: UInt64, for id: NodeID) {
        guard contains(id), id != Self.rootID, nodes[Int(id)].kind == .file else { return }
        linkInodes[id] = inode
    }

    /// Marks a node as moved to the Trash and subtracts its contribution from every ancestor.
    /// Returns `false` if it was already removed.
    @discardableResult
    public mutating func markRemoved(_ id: NodeID) -> Bool {
        guard id != Self.rootID, !isRemoved(id) else { return false }
        let node = nodes[Int(id)]
        nodes[Int(id)].flags.insert(.removed)
        guard !node.flags.contains(.hardLinkDuplicate) else { return true }
        var current = node.parent
        while current >= 0 {
            nodes[Int(current)].logicalSize -= node.logicalSize
            nodes[Int(current)].allocatedSize -= node.allocatedSize
            nodes[Int(current)].itemCount -= node.itemCount
            current = nodes[Int(current)].parent
        }
        return true
    }

    /// Flags a file as a second path to an inode counted elsewhere and takes its sizes out of
    /// every ancestor, as if the scan had found it second.
    mutating func markHardLinkDuplicate(_ id: NodeID) {
        guard contains(id), !nodes[Int(id)].flags.contains(.hardLinkDuplicate) else { return }
        let node = nodes[Int(id)]
        nodes[Int(id)].flags.insert(.hardLinkDuplicate)
        var current = node.parent
        while current >= 0 {
            nodes[Int(current)].logicalSize -= node.logicalSize
            nodes[Int(current)].allocatedSize -= node.allocatedSize
            nodes[Int(current)].itemCount -= node.itemCount
            current = nodes[Int(current)].parent
        }
    }

    /// Clears ``NodeFlags/hardLinkDuplicate`` on a file and adds its sizes to every ancestor:
    /// the inverse of ``markHardLinkDuplicate(_:)``, for a link that is now the only one counted.
    mutating func markCounted(_ id: NodeID) {
        guard contains(id), id != Self.rootID, nodes[Int(id)].kind == .file, nodes[Int(id)].flags.contains(.hardLinkDuplicate) else { return }
        let node = nodes[Int(id)]
        nodes[Int(id)].flags.remove(.hardLinkDuplicate)
        var current = node.parent
        while current >= 0 {
            nodes[Int(current)].logicalSize += node.logicalSize
            nodes[Int(current)].allocatedSize += node.allocatedSize
            nodes[Int(current)].itemCount += node.itemCount
            current = nodes[Int(current)].parent
        }
    }
}

public enum PathUtilities {
    /// Absolute path without `.`/`..`, duplicate or trailing slashes. Symlinks are NOT resolved,
    /// because the path must keep pointing at what the user selected.
    public static func standardize(_ path: String) -> String {
        var standardized = (path as NSString).standardizingPath
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized.isEmpty ? "/" : standardized
    }

    /// `true` when `path` equals `ancestor` or lives below it. Both must be standardized.
    public static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
