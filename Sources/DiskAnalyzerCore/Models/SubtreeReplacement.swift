import Foundation

public enum SubtreeReplacementError: Error, Equatable, LocalizedError {
    case notInTree(String)
    case notAFolder(String)
    case rootMismatch(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .notInTree(let path): "“\(path)” is not part of the current scan."
        case .notAFolder(let path): "“\(path)” is not a folder."
        case let .rootMismatch(expected, found): "The rescan describes “\(found)”, not “\(expected)”."
        }
    }
}

extension FileTree {
    /// A new tree in which the folder `target` and everything below it are the contents of
    /// `subtree` (a scan of that same folder). Every ancestor total is recomputed, entries
    /// moved to the Trash earlier are dropped, and the rest of the tree is unchanged.
    ///
    /// `self` is not modified, so a caller that only assigns the result after a successful
    /// rescan keeps the old data on any failure.
    public func replacingSubtree(at target: NodeID, with subtree: FileTree) throws -> FileTree {
        guard contains(target), !isRemoved(target) else { throw SubtreeReplacementError.notInTree(String(target)) }
        let targetPath = path(of: target)
        guard self[target].isDirectory else { throw SubtreeReplacementError.notAFolder(targetPath) }
        guard subtree.rootPath == targetPath else {
            throw SubtreeReplacementError.rootMismatch(expected: targetPath, found: subtree.rootPath)
        }

        enum Source { case current, replacement }
        var nodes: [FileNode] = []
        nodes.reserveCapacity(count + subtree.count)
        var inodes: [NodeID: UInt64] = [:]
        // Pre-order walk so every parent gets a smaller ID than its children, as `assemble` expects.
        var stack: [(id: NodeID, source: Source, parent: NodeID)] = [(Self.rootID, .current, -1)]
        while let (id, source, parent) = stack.popLast() {
            let newID = NodeID(nodes.count)
            var node: FileNode
            let children: [NodeID]
            if source == .current, id == target {
                // The rescanned folder keeps its name and the properties of its name; the rest is new.
                node = subtree.root
                node.name = self[target].name
                node.flags.formUnion(self[target].flags.intersection([.hidden, .package]))
                node.flags.remove(.removed)
                (node.logicalSize, node.allocatedSize, node.itemCount) = subtree.ownContribution(of: Self.rootID)
                children = subtree.children(of: Self.rootID)
                for child in children.reversed() { stack.append((child, .replacement, newID)) }
            } else {
                let tree = source == .current ? self : subtree
                node = tree[id]
                if let inode = tree.linkInodes[id] { inodes[newID] = inode }
                (node.logicalSize, node.allocatedSize, node.itemCount) = tree.ownContribution(of: id)
                children = tree.children(of: id)
                for child in children.reversed() { stack.append((child, source, newID)) }
            }
            node.parent = parent
            node.childStart = 0
            node.childCount = 0
            nodes.append(node)
        }
        return FileTree.assemble(rootPath: rootPath, nodes: &nodes, linkInodes: inodes)
    }

    /// What the node adds on its own, before aggregation: a file's sizes, or a folder's own
    /// blocks (its total minus the live children that were summed into it).
    func ownContribution(of id: NodeID) -> (logical: Int64, allocated: Int64, items: Int64) {
        let node = self[id]
        guard node.isDirectory, !node.flags.contains(.hardLinkDuplicate) else {
            return (node.logicalSize, node.allocatedSize, node.itemCount)
        }
        var logical = node.logicalSize, allocated = node.allocatedSize, items = node.itemCount
        for child in children(of: id) where !self[child].flags.contains(.hardLinkDuplicate) {
            logical -= self[child].logicalSize
            allocated -= self[child].allocatedSize
            items -= self[child].itemCount
        }
        return (logical, allocated, items)
    }

    /// Entry counts of the live tree, as ``ScanStatistics`` reports them.
    func liveStatistics(duration: Duration) -> ScanStatistics {
        var stats = ScanStatistics()
        stats.duration = duration
        var stack = [Self.rootID]
        while let id = stack.popLast() {
            let node = self[id]
            switch node.kind {
            case .directory:
                stats.directories += 1
                if node.flags.contains(.alreadyCounted) { stats.foldersAlreadyCounted += 1 }
            case .file:
                stats.files += 1
                if node.flags.contains(.hardLinkDuplicate) { stats.hardLinkDuplicates += 1 }
            case .symlink: stats.symlinks += 1
            case .other: stats.otherEntries += 1
            }
            stack.append(contentsOf: children(of: id))
        }
        return stats
    }
}

extension ScanResult {
    /// This result with the folder at `path` replaced by `rescan` (a scan of that folder).
    /// Issues recorded inside the folder are replaced by the rescan's; entry counts are
    /// recomputed. `finishedAt` and the options stay those of the full scan.
    public func replacingSubtree(at path: String, with rescan: ScanResult) throws -> ScanResult {
        let folder = PathUtilities.standardize(path)
        guard let target = tree.nodeID(forPath: folder) else { throw SubtreeReplacementError.notInTree(folder) }
        let merged = try tree.replacingSubtree(at: target, with: rescan.tree)

        let kept = issues.filter { !PathUtilities.isSameOrDescendant($0.path, of: folder) }
        var counts = issueCounts
        for issue in issues where PathUtilities.isSameOrDescendant(issue.path, of: folder) {
            counts[issue.kind, default: 0] -= 1
        }
        for (kind, value) in rescan.issueCounts { counts[kind, default: 0] += value }
        // Issues past the in-memory cap were counted but not listed, so they cannot be matched
        // to the folder; a count never goes below zero because of that.
        counts = counts.compactMapValues { $0 > 0 ? $0 : nil }
        let combined = (kept + rescan.issues).prefix(options.maxRecordedIssues).enumerated().map { index, issue in
            ScanIssue(id: index, path: issue.path, kind: issue.kind, errorCode: issue.errorCode)
        }
        return ScanResult(tree: merged, options: options, issues: combined, issueCounts: counts,
                          statistics: merged.liveStatistics(duration: statistics.duration), finishedAt: finishedAt)
    }
}

/// Rescans one folder of a snapshot and returns the updated snapshot. Nothing is changed
/// unless the rescan finishes: cancellation and errors throw, and the caller keeps (and
/// keeps saved) the snapshot it passed in.
public enum SubtreeRescan {
    public typealias Scanner = @Sendable (ScanOptions, DiskScanner.ProgressHandler?) async throws -> ScanResult

    public static let diskScanner: Scanner = { options, progress in
        try await DiskScanner().scan(options, progress: progress)
    }

    /// The folder must be a live, exactly named, measurable folder of the snapshot.
    public static func canRescan(_ id: NodeID, in tree: FileTree) -> Bool {
        guard tree.contains(id), tree[id].isDirectory, !tree.isRemoved(id), tree.hasExactPath(id) else { return false }
        return tree[id].flags.isDisjoint(with: [.otherVolume, .excluded, .alreadyCounted])
    }

    /// The rescan only deduplicates hard links inside the folder, so links that cross the
    /// folder boundary are settled here, keeping each inode counted exactly once:
    ///
    /// - a file in the rescan that is another link to an inode the tree counts outside the
    ///   folder is marked as a duplicate (the inode stays counted where the full scan counted it);
    /// - a duplicate outside the folder is counted again, as a fresh scan would, only when the
    ///   tree counted its inode inside the replaced folder and that inode is no longer counted;
    /// - when a counted link outside the folder became stale, a rescanned link inside stays a
    ///   duplicate until the outside folder is rescanned. Its stored inode is carried into the
    ///   merged tree so later rescans can either preserve or transfer that count correctly.
    ///
    /// Returns the adjusted rescan and the adjusted current tree. The outside `lstat(2)` pass
    /// only runs when the rescan holds multiply-linked files or a duplicate may cross the boundary.
    static func reconcileHardLinks(_ rescan: FileTree, with tree: FileTree, folder: NodeID) throws -> (rescan: FileTree, tree: FileTree) {
        func identity(_ path: String, requiresLinks: Bool) -> FileIdentity? {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, !requiresLinks || info.st_nlink > 1 else { return nil }
            return FileIdentity(info)
        }
        var inside: [FileIdentity: [NodeID]] = [:]
        for index in 1..<max(rescan.count, 1) {
            let id = NodeID(index), node = rescan[id]
            guard node.kind == .file, !node.flags.contains(.hardLinkDuplicate),
                  let identity = identity(rescan.path(of: id), requiresLinks: true) else { continue }
            inside[identity, default: []].append(id)
        }
        // Read the sparse inode map directly instead of walking live children. A node moved to
        // the Trash is intentionally absent from `walkDescendants`, but its former inode still
        // decides whether a surviving duplicate outside the folder must take the count.
        var countedInsideBefore: Set<UInt64> = []
        var duplicatedInsideBefore: Set<UInt64> = []
        var duplicatedInsidePaths: [String: UInt64] = [:]
        for (id, inode) in tree.linkInodes where tree.contains(id) && tree.isAncestor(folder, of: id) {
            let node = tree[id]
            guard node.kind == .file else { continue }
            if node.flags.contains(.hardLinkDuplicate) {
                duplicatedInsideBefore.insert(inode)
                duplicatedInsidePaths[tree.path(of: id)] = inode
            } else {
                countedInsideBefore.insert(inode)
            }
        }
        // When the counted link outside disappeared, a former duplicate inside may now have
        // `st_nlink == 1`. The regular multiply-linked pass above intentionally skips it, so add
        // it back by its stable path and stored inode before reconciling the stale outside node.
        for (path, storedInode) in duplicatedInsidePaths {
            guard let id = rescan.nodeID(forPath: path), rescan[id].kind == .file,
                  !rescan[id].flags.contains(.hardLinkDuplicate),
                  let liveIdentity = identity(path, requiresLinks: false), liveIdentity.inode == storedInode,
                  inside[liveIdentity]?.contains(id) != true else { continue }
            inside[liveIdentity, default: []].append(id)
        }
        // Duplicates outside the folder: a flags-only pass, then one lstat each (they are few).
        var duplicatesOutside: [(id: NodeID, identity: FileIdentity)] = []
        if !countedInsideBefore.isEmpty {
            tree.walkDescendants(of: FileTree.rootID) { id, node in
                if id == folder { return false }
                if node.kind == .file, node.flags.contains(.hardLinkDuplicate), let stored = tree.linkInodes[id],
                   countedInsideBefore.contains(stored), let identity = identity(tree.path(of: id), requiresLinks: false),
                   identity.inode == stored {
                    duplicatesOutside.append((id, identity))
                }
                return true
            }
        }
        let wanted = Set(inside.keys).union(duplicatesOutside.map(\.identity))
        guard !wanted.isEmpty else { return (rescan, tree) }

        var countedOutside: Set<FileIdentity> = []
        var staleCountedOutsideInodes: Set<UInt64> = []
        var visited = 0
        var failure: Error?
        tree.walkDescendants(of: FileTree.rootID) { id, node in
            if id == folder { return false }
            visited += 1
            if visited % 1_024 == 0, failure == nil {
                do { try Task.checkCancellation() } catch { failure = error }
            }
            guard failure == nil, node.kind == .file, !node.flags.contains(.hardLinkDuplicate) else {
                return failure == nil
            }
            if let storedInode = tree.linkInodes[id], duplicatedInsideBefore.contains(storedInode) {
                if let liveIdentity = identity(tree.path(of: id), requiresLinks: false), liveIdentity.inode == storedInode {
                    if wanted.contains(liveIdentity) { countedOutside.insert(liveIdentity) }
                } else {
                    // The old outside node still contributes to this snapshot even though its path
                    // disappeared or now names another inode. Keep the rescanned link duplicate until
                    // Rescan All replaces that stale node, rather than counting the inode twice.
                    staleCountedOutsideInodes.insert(storedInode)
                }
            } else if let liveIdentity = identity(tree.path(of: id), requiresLinks: true), wanted.contains(liveIdentity) {
                countedOutside.insert(liveIdentity)
            }
            return true
        }
        if let failure { throw failure }

        var adjustedRescan = rescan
        for (identity, ids) in inside
        where countedOutside.contains(identity) || staleCountedOutsideInodes.contains(identity.inode) {
            for id in ids {
                adjustedRescan.markHardLinkDuplicate(id)
                adjustedRescan.rememberLinkInode(identity.inode, for: id)
            }
        }
        var adjustedTree = tree
        var counted = countedOutside.union(inside.keys)
        // Pre-order walk order: the first surviving duplicate takes the count, like the scanner's first link.
        for duplicate in duplicatesOutside where !counted.contains(duplicate.identity) {
            adjustedTree.markCounted(duplicate.id)
            counted.insert(duplicate.identity)
        }
        return (adjustedRescan, adjustedTree)
    }

    /// Rescans `folder` and swaps its subtree into the snapshot. The full scan's baselines are
    /// kept: the rest of the tree is as old as they are. The change the rescan measured is added
    /// to ``ScanSnapshot/rescanAllocatedChange`` so freshness compares the volume with what the
    /// results account for.
    public static func run(_ snapshot: ScanSnapshot, folder path: String, scanner: Scanner = diskScanner,
                           progress: DiskScanner.ProgressHandler? = nil) async throws -> ScanSnapshot {
        let folder = PathUtilities.standardize(path)
        guard let id = snapshot.tree.nodeID(forPath: folder) else { throw SubtreeReplacementError.notInTree(folder) }
        guard canRescan(id, in: snapshot.tree) else { throw SubtreeReplacementError.notAFolder(folder) }
        let previous = snapshot.result.options
        let rescanMode: CloudScanMode = previous.cloudScanMode == .legacyUnspecified ? .localOnly : previous.cloudScanMode
        let options = ScanOptions(root: URL(fileURLWithPath: folder, isDirectory: true), staysOnVolume: previous.staysOnVolume,
                                  excludedPaths: previous.excludedPaths, cloudScanMode: rescanMode,
                                  detectsPackages: previous.detectsPackages,
                                  maxRecordedIssues: previous.maxRecordedIssues, progressInterval: previous.progressInterval)
        var rescan = try await scanner(options, progress)
        try Task.checkCancellation()
        let (adjustedRescan, adjustedTree) = try reconcileHardLinks(rescan.tree, with: snapshot.tree, folder: id)
        rescan.tree = adjustedRescan
        var current = snapshot.result
        current.tree = adjustedTree
        var updated = snapshot
        updated.result = try current.replacingSubtree(at: folder, with: rescan)
        let measured = SafeArithmetic.difference(updated.tree.root.allocatedSize, snapshot.tree.root.allocatedSize) ?? 0
        updated.rescanAllocatedChange = SafeArithmetic.saturatingSum(snapshot.rescanAllocatedChange, measured)
        updated.rescannedFolders.append(folder)
        return updated
    }
}
