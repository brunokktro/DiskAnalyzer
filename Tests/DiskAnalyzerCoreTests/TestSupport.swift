import Foundation
import DiskAnalyzerFixtures
@testable import DiskAnalyzerCore

/// A fixture tree in a unique temporary folder, removed (permissions restored first) on deinit.
/// Tests honor `TMPDIR`, so CI and contributors decide where scratch data lives.
final class TemporaryFixture: @unchecked Sendable {
    let root: URL
    let manifest: FixtureBuilder.Manifest?

    init(build: Bool = true, options: FixtureBuilder.Options = .init()) throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "DiskAnalyzerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        // Resolve /var -> /private/var so paths compare equal to what fts reports.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: (base.path(percentEncoded: false) as NSString).resolvingSymlinksInPath, isDirectory: true)
        manifest = build ? try FixtureBuilder.build(at: root, options: options) : nil
    }

    var rootPath: String { PathUtilities.standardize(root.path(percentEncoded: false)) }

    func path(_ relative: String) -> String { rootPath + "/" + relative }

    func scan(_ configure: (inout ScanOptions) -> Void = { _ in }) throws -> ScanResult {
        var options = ScanOptions(root: root)
        configure(&options)
        return try DiskScanner.scanSynchronously(options)
    }

    deinit {
        FixtureBuilder.restorePermissions(root)
        try? FileManager.default.removeItem(at: root)
    }
}

extension FileTree {
    func node(at relative: String) -> FileNode? {
        nodeID(forPath: rootPath + "/" + relative).map { self[$0] }
    }

    func id(_ relative: String) -> NodeID? {
        nodeID(forPath: rootPath + "/" + relative)
    }
}

/// Runs a command and returns stdout. Used to cross-check results against `du(1)`.
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func allocatedBytes(_ path: String) -> Int64 {
    var info = stat()
    return lstat(path, &info) == 0 ? Int64(info.st_blocks) * 512 : -1
}

/// Builds a small in-memory tree without touching the disk.
/// `spec` entries are `(path relative to root, logical size, allocated size)`; a trailing `/` makes a directory.
func makeTree(_ spec: [(String, Int64, Int64)], root: String = "/fixture", times: [String: Double] = [:], flags extraFlags: [String: NodeFlags] = [:]) -> FileTree {
    var nodes = [FileNode(name: root, parent: -1, kind: .directory, flags: [], logicalSize: 0, allocatedSize: 0,
                          itemCount: 0, modificationTime: 0, childStart: 0, childCount: 0)]
    var ids: [String: NodeID] = ["": 0]
    for (rawPath, logical, allocated) in spec {
        let isDirectory = rawPath.hasSuffix("/")
        let path = isDirectory ? String(rawPath.dropLast()) : rawPath
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let parent = ids[parentPath] ?? 0
        var flags: NodeFlags = name.hasPrefix(".") ? [.hidden] : []
        if isDirectory, name.hasSuffix(".app") { flags.insert(.package) }
        flags.formUnion(extraFlags[path] ?? [])
        nodes.append(FileNode(name: name, parent: parent, kind: isDirectory ? .directory : .file, flags: flags,
                              logicalSize: isDirectory ? 0 : logical, allocatedSize: isDirectory ? 0 : allocated,
                              itemCount: isDirectory ? 0 : 1, modificationTime: times[path] ?? 1_700_000_000,
                              childStart: 0, childCount: 0))
        ids[path] = NodeID(nodes.count - 1)
    }
    return FileTree.assemble(rootPath: root, nodes: &nodes)
}
