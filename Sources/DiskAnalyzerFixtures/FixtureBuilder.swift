import Darwin
import Foundation

/// Builds a deterministic directory tree that exercises every scanner rule:
/// nested folders, known file sizes, a sparse file, hard links, symbolic links
/// (including a loop), hidden entries, a package, Unicode names, old timestamps
/// and, optionally, a folder without read permission.
///
/// Only the logical sizes are fixed. Allocated sizes depend on the file system,
/// so tests compare them against `lstat(2)` and `du(1)` instead of constants.
public enum FixtureBuilder {
    public struct Manifest: Sendable {
        public let root: URL
        /// Logical bytes the scanner must report for the whole tree (hard links counted once).
        public let expectedLogicalTotal: Int64
        /// Regular files counted once (hard-link duplicates excluded), plus symlinks.
        public let expectedCountedItems: Int64
        /// Paths relative to `root`.
        public let largestFile: String
        public let sparseFile: String
        public let sparseLogicalSize: Int64
        public let hardLinkPaths: [String]
        public let packagePath: String
        public let unreadablePath: String?
        public let hiddenPaths: [String]
        public let oldFilePath: String
        public let symlinkPaths: [String]
    }

    public struct Options: Sendable {
        /// Creates a folder with mode 000. Call ``restorePermissions(_:)`` before removing the tree.
        public var includesUnreadableFolder: Bool
        /// Multiplies every regular file size; 1 keeps the tree around 6 MB.
        public var sizeScale: Int
        /// Extra flat folders with many small files, for performance checks.
        public var bulkFolders: Int
        public var bulkFilesPerFolder: Int

        public init(includesUnreadableFolder: Bool = true, sizeScale: Int = 1, bulkFolders: Int = 0, bulkFilesPerFolder: Int = 0) {
            self.includesUnreadableFolder = includesUnreadableFolder
            self.sizeScale = max(1, sizeScale)
            self.bulkFolders = bulkFolders
            self.bulkFilesPerFolder = bulkFilesPerFolder
        }
    }

    public enum FixtureError: Error, CustomStringConvertible {
        case notEmpty(String)
        case posix(String, Int32)

        public var description: String {
            switch self {
            case .notEmpty(let path): "Refusing to write a fixture into non-empty folder \(path)."
            case .posix(let what, let code): "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Fixed reference date so "old file" filters are deterministic: 2020-01-01T00:00:00Z.
    public static let oldDate = Date(timeIntervalSince1970: 1_577_836_800)

    @discardableResult
    public static func build(at root: URL, options: Options = Options()) throws -> Manifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false)), !existing.isEmpty {
            throw FixtureError.notEmpty(root.path(percentEncoded: false))
        }
        let scale = Int64(options.sizeScale)
        var logical: Int64 = 0
        var items: Int64 = 0

        func dir(_ relative: String) throws {
            try fm.createDirectory(at: root.appending(path: relative), withIntermediateDirectories: true)
        }
        func file(_ relative: String, _ size: Int64, byte: UInt8 = 0x5A) throws {
            let url = root.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: Int(size)).write(to: url)
            logical += size
            items += 1
        }

        try dir("Projects/Alpha/build")
        try dir("Projects/Beta")
        try dir("Media/Photos/2019")
        try dir("Empty Folder")

        try file("Projects/Alpha/main.swift", 4_096)
        try file("Projects/Alpha/build/output.o", 300_000 * scale)
        try file("Projects/Alpha/build/cache.db", 120_000 * scale)
        try file("Projects/Beta/notes.md", 1_500)
        try file("Projects/Beta/data.csv", 64_000 * scale)
        try file("Media/Photos/2019/beach.jpg", 900_000 * scale)
        try file("Media/Photos/2019/mountain.heic", 700_000 * scale)
        try file("Media/movie.mov", 2_500_000 * scale)
        try file("Media/song.m4a", 400_000 * scale)
        try file("Archive.zip", 800_000 * scale)
        try file(".Trashes/\(getuid())/old-download.dmg", 600_000 * scale)
        try file("Résumé – final ✓.pdf", 50_000)
        try file("tiny.txt", 1)
        try file("zero.bin", 0)

        // Hidden entries: dot-names and the UF_HIDDEN flag.
        try file(".hidden-config", 2_048)
        try file("Projects/.cache/blob.bin", 30_000 * scale)
        try file("FlaggedHidden.txt", 512)
        try setHiddenFlag(root.appending(path: "FlaggedHidden.txt"))

        // A package: Launch Services treats any `.app` directory as a single document.
        try file("Tools/Example.app/Contents/Info.plist", 600)
        try file("Tools/Example.app/Contents/MacOS/Example", 200_000 * scale)

        // Sparse file: large logical size, almost nothing allocated.
        let sparseSize: Int64 = 64 * 1_048_576
        let sparseURL = root.appending(path: "Media/sparse-disk.img")
        guard fm.createFile(atPath: sparseURL.path(percentEncoded: false), contents: nil) else {
            throw FixtureError.posix("create sparse file", errno)
        }
        let handle = try FileHandle(forWritingTo: sparseURL)
        try handle.truncate(atOffset: UInt64(sparseSize))
        try handle.close()
        logical += sparseSize
        items += 1

        // Hard link: two paths, one inode, counted once.
        try file("Projects/Beta/shared.bin", 256_000 * scale)
        try fm.linkItem(at: root.appending(path: "Projects/Beta/shared.bin"), to: root.appending(path: "Media/shared-link.bin"))

        // Symbolic links are listed but never followed, including one that points at its parent.
        try fm.createSymbolicLink(atPath: root.appending(path: "Media/link-to-movie").path(percentEncoded: false), withDestinationPath: "movie.mov")
        try fm.createSymbolicLink(atPath: root.appending(path: "Projects/loop").path(percentEncoded: false), withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appending(path: "dangling-link").path(percentEncoded: false), withDestinationPath: "does-not-exist")
        let symlinks = ["Media/link-to-movie", "Projects/loop", "dangling-link"]
        for link in symlinks {
            var info = stat()
            guard lstat(root.appending(path: link).path(percentEncoded: false), &info) == 0 else { throw FixtureError.posix("lstat \(link)", errno) }
            logical += Int64(info.st_size)
            items += 1
        }

        for folder in 0..<options.bulkFolders {
            for index in 0..<options.bulkFilesPerFolder {
                try file(String(format: "Bulk/folder-%03d/file-%05d.dat", folder, index), Int64(100 + (index % 7) * 50))
            }
        }

        // Old timestamp for date filters.
        let oldFile = "Projects/Beta/notes.md"
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: root.appending(path: oldFile).path(percentEncoded: false))

        var unreadable: String?
        if options.includesUnreadableFolder {
            let locked = "Locked"
            try file("Locked/secret.txt", 10_000)
            // Bytes inside the locked folder cannot be measured by a scan.
            logical -= 10_000
            items -= 1
            guard chmod(root.appending(path: locked).path(percentEncoded: false), 0) == 0 else {
                throw FixtureError.posix("chmod Locked", errno)
            }
            unreadable = locked
        }

        return Manifest(
            root: root,
            expectedLogicalTotal: logical,
            expectedCountedItems: items,
            largestFile: "Media/movie.mov",
            sparseFile: "Media/sparse-disk.img",
            sparseLogicalSize: sparseSize,
            hardLinkPaths: ["Projects/Beta/shared.bin", "Media/shared-link.bin"],
            packagePath: "Tools/Example.app",
            unreadablePath: unreadable,
            hiddenPaths: [".hidden-config", ".Trashes", "Projects/.cache", "FlaggedHidden.txt"],
            oldFilePath: oldFile,
            symlinkPaths: symlinks
        )
    }

    /// Makes every folder below `root` traversable again so the tree can be removed.
    public static func restorePermissions(_ root: URL) {
        let locked = root.appending(path: "Locked").path(percentEncoded: false)
        _ = chmod(locked, 0o755)
    }

    private static func setHiddenFlag(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FixtureError.posix("lstat hidden", errno) }
        guard chflags(path, info.st_flags | UInt32(UF_HIDDEN)) == 0 else { throw FixtureError.posix("chflags hidden", errno) }
    }
}
