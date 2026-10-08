import DiskAnalyzerFixtures
import Foundation

// Writes the test fixture tree to a folder so the app can be exercised by hand:
//
//   swift run FixtureGenerator <empty-or-new-folder> [--no-locked] [--scale N] [--bulk FOLDERS FILES]
//
// The folder must be empty or not exist. A "Locked" folder with mode 000 is created
// unless --no-locked is given; restore it with `chmod 755 <folder>/Locked` before
// removing the tree.

let arguments = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    FileHandle.standardError.write(Data("usage: FixtureGenerator <folder> [--no-locked] [--scale N] [--bulk FOLDERS FILES]\n".utf8))
    exit(64)
}
guard let target = arguments.first, !target.hasPrefix("-") else { usage() }

var options = FixtureBuilder.Options()
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--no-locked":
        options.includesUnreadableFolder = false
    case "--scale":
        guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { usage() }
        options.sizeScale = value
        index += 1
    case "--bulk":
        guard index + 2 < arguments.count, let folders = Int(arguments[index + 1]), let files = Int(arguments[index + 2]),
              folders >= 0, files >= 0 else { usage() }
        options.bulkFolders = folders
        options.bulkFilesPerFolder = files
        index += 2
    default:
        usage()
    }
    index += 1
}

do {
    let root = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
    let manifest = try FixtureBuilder.build(at: root, options: options)
    print("Fixture written to \(manifest.root.path(percentEncoded: false))")
    print("expected logical bytes: \(manifest.expectedLogicalTotal)")
    print("expected counted items: \(manifest.expectedCountedItems)")
    if let locked = manifest.unreadablePath {
        print("unreadable folder: \(locked) (restore with chmod 755 before removing)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
