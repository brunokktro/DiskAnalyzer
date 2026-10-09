import Foundation

/// Metadata-only directory walker built on `fts(3)`.
///
/// It never opens or reads file contents. For every entry it records `lstat(2)` data:
/// `st_size` as the logical size and `st_blocks * 512` as the allocated size (see `man 2 stat`).
/// Rules, chosen to match `du(1)` so results can be cross-checked from Terminal:
/// - symbolic links are never followed, except when the root itself is a link;
/// - a file with several hard links is counted once, at the first path seen;
/// - a folder reached again through another path (APFS firmlinks such as `/Users` and
///   `/System/Volumes/Data/Users`, or a hard-linked folder in an HFS+ Time Machine backup)
///   is counted once and not entered again. `fts` only catches such a folder when it is its
///   own ancestor (`FTS_DC`), so every folder identity `(st_dev, st_ino)` is remembered;
/// - directories on another device are not entered when ``ScanOptions/staysOnVolume`` is set;
/// - a directory's own allocated blocks count toward its total (APFS reports 0).
public struct DiskScanner: Sendable {
    public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    public init() {}

    /// Runs the scan off the caller's executor. Cancelling the calling task stops the walk
    /// within a few hundred entries and throws `CancellationError`.
    public func scan(_ options: ScanOptions, progress: ProgressHandler? = nil) async throws -> ScanResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(options, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Blocking variant. Honors cancellation of the task it runs in.
    public static func scanSynchronously(_ options: ScanOptions, progress: ProgressHandler? = nil) throws -> ScanResult {
        var walker = Walker(options: options, progress: progress)
        return try walker.run()
    }
}

private struct HardLinkKey: Hashable {
    let device: Int32
    let inode: UInt64
}

private struct Walker {
    let options: ScanOptions
    let progress: DiskScanner.ProgressHandler?
    let rootPath: String
    let excluded: Set<String>
    let clock = ContinuousClock()

    var nodes: [FileNode] = []
    var issues: [ScanIssue] = []
    var issueCounts: [ScanIssue.Kind: Int] = [:]
    var statistics = ScanStatistics()
    var seenHardLinks: Set<HardLinkKey> = []
    var seenDirectories: Set<HardLinkKey> = []
    var runningAllocated: Int64 = 0
    var runningLogical: Int64 = 0
    var currentDirectory = ""
    var linkInodes: [NodeID: UInt64] = [:]

    init(options: ScanOptions, progress: DiskScanner.ProgressHandler?) {
        self.options = options
        self.progress = progress
        self.rootPath = PathUtilities.standardize(options.root.path(percentEncoded: false))
        self.excluded = Set(options.excludedPaths.map(PathUtilities.standardize))
    }

    mutating func run() throws -> ScanResult {
        let started = clock.now
        var rootStat = stat()
        guard stat(rootPath, &rootStat) == 0 else { throw ScanError.cannotOpen(rootPath, errno) }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.notADirectory(rootPath) }
        let rootDevice = rootStat.st_dev

        guard let cPath = strdup(rootPath) else { throw ScanError.cannotOpen(rootPath, ENOMEM) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // FTS_PHYSICAL: never follow links. FTS_COMFOLLOW: except a linked root.
        // FTS_NOCHDIR: keep the process working directory untouched (thread safe).
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, nil) else {
            throw ScanError.cannotOpen(rootPath, errno)
        }
        defer { fts_close(fts) }

        var lastReport = started
        var sinceCancelCheck = 0

        while let entry = fts_read(fts) {
            sinceCancelCheck += 1
            if sinceCancelCheck >= 256 {
                sinceCancelCheck = 0
                try Task.checkCancellation()
                let now = clock.now
                if progress != nil, now - lastReport >= options.progressInterval {
                    lastReport = now
                    report(elapsed: now - started)
                }
            }
            try visit(entry, fts: fts, rootDevice: rootDevice)
        }
        if errno != 0, nodes.isEmpty { throw ScanError.cannotOpen(rootPath, errno) }
        try Task.checkCancellation()

        let tree = FileTree.assemble(rootPath: rootPath, nodes: &nodes, linkInodes: linkInodes)
        statistics.duration = clock.now - started
        report(elapsed: statistics.duration)
        return ScanResult(
            tree: tree,
            options: options,
            issues: issues,
            issueCounts: issueCounts,
            statistics: statistics,
            finishedAt: Date()
        )
    }

    // MARK: - Visiting

    private mutating func visit(_ entry: UnsafeMutablePointer<FTSENT>, fts: UnsafeMutablePointer<FTS>, rootDevice: dev_t) throws {
        let info = Int32(entry.pointee.fts_info)
        let level = Int(entry.pointee.fts_level)
        let isRoot = level == FTS_ROOTLEVEL

        switch info {
        case FTS_DP:
            return // Aggregation happens once, after the walk.
        case FTS_DNR:
            // Reported after FTS_D for the same directory: the node exists already.
            let code = entry.pointee.fts_errno
            if isRoot { throw ScanError.cannotOpen(rootPath, code) }
            let id = Int(entry.pointee.fts_number)
            if id > 0, id < nodes.count { nodes[id].flags.insert(.unreadable) }
            record(.from(errno: code), path: entryPath(entry), code: code)
            return
        case FTS_ERR:
            let code = entry.pointee.fts_errno
            if isRoot { throw ScanError.cannotOpen(rootPath, code) }
            record(.from(errno: code), path: entryPath(entry), code: code)
            return
        default:
            break
        }

        guard nodes.count < Int(Int32.max) else { throw ScanError.tooManyItems }
        let id = NodeID(nodes.count)
        let parent: NodeID = isRoot ? -1 : NodeID(truncatingIfNeeded: entry.pointee.fts_parent.pointee.fts_number)
        let (name, nameIsValid) = isRoot ? (rootPath, true) : Self.name(of: entry)
        if !nameIsValid { record(.invalidName, path: entryPath(entry), code: 0) }

        var node = FileNode(
            name: name, parent: parent, kind: .other, flags: [],
            logicalSize: 0, allocatedSize: 0, itemCount: 0, modificationTime: 0,
            childStart: 0, childCount: 0
        )
        if !isRoot && name.hasPrefix(".") { node.flags.insert(.hidden) }
        if !nameIsValid { node.flags.insert(.invalidName) }

        guard info != FTS_NS, let st = entry.pointee.fts_statp?.pointee else {
            node.flags.insert(.unreadable)
            node.itemCount = 1
            statistics.otherEntries += 1
            nodes.append(node)
            let code = entry.pointee.fts_errno
            record(.from(errno: code), path: entryPath(entry), code: code)
            return
        }

        node.modificationTime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if st.st_flags & UInt32(UF_HIDDEN) != 0, !isRoot { node.flags.insert(.hidden) }
        let allocated = Int64(st.st_blocks) * 512

        switch info {
        case FTS_D, FTS_DC:
            node.kind = .directory
            node.allocatedSize = allocated
            statistics.directories += 1
            entry.pointee.fts_number = Int(id)
            let isFirstVisit = seenDirectories.insert(HardLinkKey(device: st.st_dev, inode: st.st_ino)).inserted
            if isRoot { break }
            let path = entryPath(entry)
            if info == FTS_DC {
                node.flags.insert(.unreadable)
                record(.cycle, path: path, code: 0)
            } else if !isFirstVisit {
                node.flags.formUnion([.alreadyCounted, .hardLinkDuplicate])
                fts_set(fts, entry, FTS_SKIP)
                statistics.foldersAlreadyCounted += 1
                record(.alreadyCounted, path: path, code: 0)
            } else if options.staysOnVolume, st.st_dev != rootDevice {
                node.flags.insert(.otherVolume)
                fts_set(fts, entry, FTS_SKIP)
                record(.otherVolume, path: path, code: 0)
            } else if !excluded.isEmpty, excluded.contains(path) {
                node.flags.insert(.excluded)
                fts_set(fts, entry, FTS_SKIP)
                record(.excluded, path: path, code: 0)
            } else {
                currentDirectory = path
            }
            if options.detectsPackages, Self.mayBePackage(name), Self.isPackage(path) {
                node.flags.insert(.package)
            }
        case FTS_F:
            node.kind = .file
            node.itemCount = 1
            node.logicalSize = Int64(st.st_size)
            node.allocatedSize = allocated
            statistics.files += 1
            if st.st_nlink > 1 {
                linkInodes[id] = UInt64(st.st_ino)
                let key = HardLinkKey(device: st.st_dev, inode: st.st_ino)
                if !seenHardLinks.insert(key).inserted {
                    node.flags.insert(.hardLinkDuplicate)
                    statistics.hardLinkDuplicates += 1
                }
            }
        case FTS_SL, FTS_SLNONE:
            node.kind = .symlink
            node.itemCount = 1
            node.logicalSize = Int64(st.st_size)
            node.allocatedSize = allocated
            statistics.symlinks += 1
        default:
            node.kind = .other
            node.itemCount = 1
            node.logicalSize = Int64(st.st_size)
            node.allocatedSize = allocated
            statistics.otherEntries += 1
        }

        if !node.flags.contains(.hardLinkDuplicate) {
            runningAllocated += node.allocatedSize
            runningLogical += node.logicalSize
        }
        nodes.append(node)
    }

    private mutating func record(_ kind: ScanIssue.Kind, path: String, code: Int32) {
        issueCounts[kind, default: 0] += 1
        guard issues.count < options.maxRecordedIssues else { return }
        issues.append(ScanIssue(id: issues.count, path: PathUtilities.standardize(path), kind: kind, errorCode: code))
    }

    private func report(elapsed: Duration) {
        progress?(ScanProgress(
            entriesVisited: nodes.count,
            directoriesVisited: statistics.directories,
            allocatedBytes: runningAllocated,
            logicalBytes: runningLogical,
            issueCount: issueCounts.values.reduce(0, +),
            currentPath: currentDirectory,
            elapsed: elapsed
        ))
    }

    private func entryPath(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        String(cString: entry.pointee.fts_path)
    }

    private static func name(of entry: UnsafeMutablePointer<FTSENT>) -> (String, Bool) {
        withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) { cName in
                if let valid = String(validatingCString: cName) { return (valid, true) }
                return (String(cString: cName), false)
            }
        }
    }

    private static func mayBePackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name.index(after: dot) != name.endIndex
    }

    private static func isPackage(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }
}

extension FileTree {
    // MARK: - Tree construction

    /// Aggregates sizes bottom-up and lays children out contiguously, largest allocated first.
    /// Relies on `fts` creating every parent before its children (pre-order), so a reverse
    /// pass over the arena visits each child before its parent.
    static func assemble(rootPath: String, nodes: inout [FileNode], linkInodes: [NodeID: UInt64] = [:]) -> FileTree {
        for index in stride(from: nodes.count - 1, to: 0, by: -1) {
            let node = nodes[index]
            guard node.parent >= 0, !node.flags.contains(.hardLinkDuplicate) else { continue }
            let parent = Int(node.parent)
            nodes[parent].logicalSize += node.logicalSize
            nodes[parent].allocatedSize += node.allocatedSize
            nodes[parent].itemCount += node.itemCount
        }

        var counts = [Int32](repeating: 0, count: nodes.count)
        for node in nodes where node.parent >= 0 { counts[Int(node.parent)] += 1 }
        var start: Int32 = 0
        for index in nodes.indices {
            nodes[index].childStart = start
            nodes[index].childCount = counts[index]
            start += counts[index]
        }
        var childIndex = [NodeID](repeating: 0, count: Int(start))
        var cursor = nodes.map(\.childStart)
        for index in 1..<max(nodes.count, 1) {
            let parent = Int(nodes[index].parent)
            childIndex[Int(cursor[parent])] = NodeID(index)
            cursor[parent] += 1
        }
        for index in nodes.indices where nodes[index].childCount > 1 {
            let range = Int(nodes[index].childStart)..<Int(nodes[index].childStart + nodes[index].childCount)
            childIndex[range].sort { lhs, rhs in
                let a = nodes[Int(lhs)], b = nodes[Int(rhs)]
                if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                if a.logicalSize != b.logicalSize { return a.logicalSize > b.logicalSize }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return FileTree(rootPath: rootPath, nodes: nodes, childIndex: childIndex, linkInodes: linkInodes)
    }
}
