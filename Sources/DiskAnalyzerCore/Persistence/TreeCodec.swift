import CryptoKit
import Foundation

/// Compact binary form of a ``FileTree`` for ``SnapshotStore``.
///
/// Layout, little-endian: magic `DATR`, format version (u32), node count (u32), child-index
/// count (u32), root path (u32 length + UTF-8), then every node (parent i32, kind u8,
/// flags u16, logical i64, allocated i64, items i64, mtime f64, child start i32,
/// child count i32, name as u32 length + UTF-8), then the child index (i32 each), then the
/// link inodes (u32 count, then node id i32 + inode u64 each, ids ascending).
///
/// ``decode(_:)`` checks every bound and the whole parent/child structure, so a damaged or
/// crafted blob throws instead of producing a tree that would crash on navigation.
public enum TreeCodec {
    /// Bump when the layout changes. Snapshots in another version are listed as
    /// incompatible and never decoded.
    public static let formatVersion = 2
    static let magic: [UInt8] = Array("DATR".utf8)

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case badMagic
        case unsupportedVersion(Int)
        case truncated
        case invalidStructure(String)
        case checksumMismatch

        public var description: String {
            switch self {
            case .badMagic: "not a Disk Analyzer tree"
            case .unsupportedVersion(let version): "tree format \(version) is not supported"
            case .truncated: "the saved tree is truncated"
            case .invalidStructure(let detail): "the saved tree is inconsistent (\(detail))"
            case .checksumMismatch: "the saved tree does not match its checksum"
            }
        }
    }

    public static func checksum(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func encode(_ tree: FileTree) -> Data {
        var writer = ByteWriter()
        writer.reserve(tree.count * 64 + tree.childIndex.count * 4 + 64)
        writer.bytes(magic)
        writer.u32(UInt32(formatVersion))
        writer.u32(UInt32(tree.count))
        writer.u32(UInt32(tree.childIndex.count))
        writer.string(tree.rootPath)
        for node in tree.nodes {
            writer.i32(node.parent)
            writer.u8(node.kind.rawValue)
            writer.u16(node.flags.rawValue)
            writer.i64(node.logicalSize)
            writer.i64(node.allocatedSize)
            writer.i64(node.itemCount)
            writer.u64(node.modificationTime.bitPattern)
            writer.i32(node.childStart)
            writer.i32(node.childCount)
            writer.string(node.name)
        }
        for child in tree.childIndex { writer.i32(child) }
        writer.u32(UInt32(tree.linkInodes.count))
        for (id, inode) in tree.linkInodes.sorted(by: { $0.key < $1.key }) {
            writer.i32(id)
            writer.u64(inode)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> FileTree {
        try data.withUnsafeBytes { buffer in
            var reader = ByteReader(buffer: buffer)
            guard try reader.bytes(4) == magic else { throw DecodeError.badMagic }
            let version = Int(try reader.u32())
            guard version == formatVersion else { throw DecodeError.unsupportedVersion(version) }
            let nodeCount = Int(try reader.u32())
            let childCount = Int(try reader.u32())
            // Every node takes at least 47 bytes and every child 4: reject counts the blob cannot hold
            // before allocating anything.
            guard nodeCount >= 1, nodeCount <= Int(Int32.max),
                  nodeCount.multipliedReportingOverflow(by: 47).partialValue <= reader.remaining,
                  childCount <= reader.remaining / 4 else { throw DecodeError.truncated }
            let rootPath = try reader.string()

            var nodes: [FileNode] = []
            nodes.reserveCapacity(nodeCount)
            for _ in 0..<nodeCount {
                let parent = try reader.i32()
                guard let kind = NodeKind(rawValue: try reader.u8()) else { throw DecodeError.invalidStructure("unknown node kind") }
                let flags = NodeFlags(rawValue: try reader.u16())
                let logical = try reader.i64(), allocated = try reader.i64(), items = try reader.i64()
                let mtime = Double(bitPattern: try reader.u64())
                let start = try reader.i32(), count = try reader.i32()
                let name = try reader.string()
                nodes.append(FileNode(name: name, parent: parent, kind: kind, flags: flags, logicalSize: logical,
                                      allocatedSize: allocated, itemCount: items, modificationTime: mtime,
                                      childStart: start, childCount: count))
            }
            var childIndex = [NodeID](repeating: 0, count: childCount)
            for index in 0..<childCount { childIndex[index] = try reader.i32() }
            let linkCount = Int(try reader.u32())
            guard linkCount <= nodeCount, linkCount <= reader.remaining / 12 else { throw DecodeError.truncated }
            var linkInodes: [NodeID: UInt64] = [:]
            linkInodes.reserveCapacity(linkCount)
            var previous: NodeID = 0
            for _ in 0..<linkCount {
                let id = try reader.i32(), inode = try reader.u64()
                // Ascending ids, each a file: a damaged list throws instead of naming folders or repeating nodes.
                guard id > previous, Int(id) < nodeCount, nodes[Int(id)].kind == .file else {
                    throw DecodeError.invalidStructure("link inode of node \(id)")
                }
                linkInodes[id] = inode
                previous = id
            }
            guard reader.remaining == 0 else { throw DecodeError.invalidStructure("trailing bytes") }
            try validate(nodes: nodes, childIndex: childIndex, rootPath: rootPath)
            return FileTree(rootPath: rootPath, nodes: nodes, childIndex: childIndex, linkInodes: linkInodes)
        }
    }

    /// The invariants the rest of the app relies on: parents come before children (pre-order
    /// arena), every child range is inside the index, every child lists its real parent once,
    /// every size and count is in range (`0...2^56`), every date is a number, and no folder
    /// is smaller than the live, counted children summed into it.
    static func validate(nodes: [FileNode], childIndex: [NodeID], rootPath: String) throws {
        func fail(_ detail: String) -> DecodeError { .invalidStructure(detail) }
        guard nodes[0].parent == -1, nodes[0].kind == .directory, nodes[0].name == rootPath,
              rootPath.hasPrefix("/"), PathUtilities.standardize(rootPath) == rootPath else { throw fail("root") }
        var listed = [Int32](repeating: 0, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if index > 0 {
                guard node.parent >= 0, Int(node.parent) < index else { throw fail("parent of node \(index)") }
                guard nodes[Int(node.parent)].kind == .directory else { throw fail("parent is not a folder") }
                guard !node.name.isEmpty, !node.name.contains("/") else { throw fail("name of node \(index)") }
            }
            guard [node.logicalSize, node.allocatedSize, node.itemCount].allSatisfy(SavedRange.isBytes),
                  node.modificationTime.isFinite else { throw fail("sizes of node \(index)") }
            guard node.childStart >= 0, node.childCount >= 0,
                  Int(node.childStart) + Int(node.childCount) <= childIndex.count else { throw fail("children of node \(index)") }
            guard node.kind == .directory || node.childCount == 0 else { throw fail("file with children") }
            var logical: Int64 = 0, allocated: Int64 = 0, items: Int64 = 0
            for slot in Int(node.childStart)..<Int(node.childStart) + Int(node.childCount) {
                let child = childIndex[slot]
                guard child > 0, Int(child) < nodes.count, nodes[Int(child)].parent == NodeID(index) else {
                    throw fail("child entry \(slot)")
                }
                listed[Int(child)] += 1
                let entry = nodes[Int(child)]
                // Children come later in the arena and are range-checked when reached; saturate until then.
                guard entry.flags.isDisjoint(with: [.removed, .hardLinkDuplicate]) else { continue }
                logical = SafeArithmetic.saturatingSum(logical, entry.logicalSize)
                allocated = SafeArithmetic.saturatingSum(allocated, entry.allocatedSize)
                items = SafeArithmetic.saturatingSum(items, entry.itemCount)
            }
            guard logical <= node.logicalSize, allocated <= node.allocatedSize, items <= node.itemCount else {
                throw fail("total of folder \(index)")
            }
        }
        guard listed.dropFirst().allSatisfy({ $0 == 1 }), listed[0] == 0 else { throw fail("child listing") }
    }
}

private struct ByteWriter {
    var data = Data()

    mutating func reserve(_ count: Int) { data.reserveCapacity(count) }
    mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { append(value.littleEndian) }
    mutating func u32(_ value: UInt32) { append(value.littleEndian) }
    mutating func u64(_ value: UInt64) { append(value.littleEndian) }
    mutating func i32(_ value: Int32) { append(value.littleEndian) }
    mutating func i64(_ value: Int64) { append(value.littleEndian) }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        u32(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

private struct ByteReader {
    let buffer: UnsafeRawBufferPointer
    var offset = 0

    var remaining: Int { buffer.count - offset }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw TreeCodec.DecodeError.truncated }
        defer { offset += count }
        return Array(buffer[offset..<offset + count])
    }

    mutating func u8() throws -> UInt8 { try read(UInt8.self) }
    mutating func u16() throws -> UInt16 { UInt16(littleEndian: try read(UInt16.self)) }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try read(UInt32.self)) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try read(UInt64.self)) }
    mutating func i32() throws -> Int32 { Int32(littleEndian: try read(Int32.self)) }
    mutating func i64() throws -> Int64 { Int64(littleEndian: try read(Int64.self)) }

    mutating func string() throws -> String {
        let count = Int(try u32())
        guard count <= remaining else { throw TreeCodec.DecodeError.truncated }
        defer { offset += count }
        let slice = UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + count])
        guard let value = String(bytes: slice, encoding: .utf8) else {
            throw TreeCodec.DecodeError.invalidStructure("name is not UTF-8")
        }
        return value
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= remaining else { throw TreeCodec.DecodeError.truncated }
        defer { offset += size }
        return buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}
