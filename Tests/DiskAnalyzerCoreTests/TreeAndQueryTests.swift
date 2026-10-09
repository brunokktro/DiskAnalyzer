import Foundation
import Testing
@testable import DiskAnalyzerCore

private let sample: [(String, Int64, Int64)] = [
    ("Docs/", 0, 0),
    ("Docs/report.pdf", 5_000, 8_192),
    ("Docs/notes.txt", 300, 4_096),
    ("Docs/Old/", 0, 0),
    ("Docs/Old/archive.zip", 90_000, 90_112),
    ("Media/", 0, 0),
    ("Media/clip.mov", 1_000_000, 1_003_520),
    ("Media/photo.jpg", 200_000, 200_704),
    ("Media/Sparse.img", 50_000_000, 4_096),
    ("Apps/", 0, 0),
    ("Apps/Tool.app/", 0, 0),
    ("Apps/Tool.app/Contents/", 0, 0),
    ("Apps/Tool.app/Contents/binary", 400_000, 401_408),
    (".secret", 10, 4_096),
]

@Suite("FileTree model")
struct FileTreeTests {
    @Test func aggregatesBottomUp() {
        let tree = makeTree(sample)
        #expect(tree.root.logicalSize == sample.reduce(0) { $0 + $1.1 })
        #expect(tree.root.allocatedSize == sample.reduce(0) { $0 + $1.2 })
        #expect(tree.root.itemCount == 8)
        #expect(tree.node(at: "Docs")?.logicalSize == 95_300)
    }

    @Test func pathRoundTrip() {
        let tree = makeTree(sample)
        for index in 0..<tree.count {
            let id = NodeID(index)
            #expect(tree.nodeID(forPath: tree.path(of: id)) == id)
        }
        #expect(tree.nodeID(forPath: "/elsewhere/file") == nil)
        #expect(tree.nodeID(forPath: "/fixture/Docs/../Media") == tree.id("Media"))
        #expect(tree.nodeID(forPath: "/fixture/Docs/") == tree.id("Docs"))
        #expect(tree.nodeID(forPath: "/fixtureX") == nil)
    }

    @Test func rootAtFileSystemRootBuildsPaths() {
        let tree = makeTree([("a/", 0, 0), ("a/b", 1, 1)], root: "/")
        let id = tree.nodeID(forPath: "/a/b")
        #expect(id.map { tree.path(of: $0) } == "/a/b")
        #expect(tree.nodeID(forPath: "/") == FileTree.rootID)
    }

    @Test func childrenSortByMetric() {
        let tree = makeTree(sample)
        let media = tree.id("Media")!
        #expect(tree.children(of: media).map { tree[$0].name } == ["clip.mov", "photo.jpg", "Sparse.img"])
        #expect(tree.sortedChildren(of: media, by: .logical).map { tree[$0].name } == ["Sparse.img", "clip.mov", "photo.jpg"])
    }

    @Test func lineageAndAncestry() {
        let tree = makeTree(sample)
        let zip = tree.id("Docs/Old/archive.zip")!
        let names = tree.lineage(of: zip).map { tree[$0].name }
        #expect(names == ["/fixture", "Docs", "Old", "archive.zip"])
        #expect(tree.isAncestor(tree.id("Docs")!, of: zip))
        #expect(!tree.isAncestor(tree.id("Media")!, of: zip))
        #expect(!tree.isAncestor(zip, of: zip))
    }

    @Test func markRemovedUpdatesAncestorsOnce() {
        var tree = makeTree(sample)
        let old = tree.id("Docs/Old")!
        let before = tree.root
        let zip = tree.id("Docs/Old/archive.zip")!
        let first = tree.markRemoved(old)
        let second = tree.markRemoved(old)
        let child = tree.markRemoved(zip) // already removed through its parent
        let root = tree.markRemoved(FileTree.rootID)
        #expect(first)
        #expect(!second)
        #expect(!child)
        #expect(!root)
        #expect(tree.root.logicalSize == before.logicalSize - 90_000)
        #expect(tree.root.allocatedSize == before.allocatedSize - 90_112)
        #expect(tree.root.itemCount == before.itemCount - 1)
        #expect(tree.node(at: "Docs")?.logicalSize == 5_300)
        #expect(tree.children(of: tree.id("Docs")!).count == 2)
        #expect(tree.nodeID(forPath: "/fixture/Docs/Old") == nil)
    }

    @Test func walkCanPruneSubtrees() {
        let tree = makeTree(sample)
        var visited: [String] = []
        tree.walkDescendants(of: FileTree.rootID) { _, node in
            visited.append(node.name)
            return node.name != "Docs"
        }
        #expect(visited.contains("Docs"))
        #expect(!visited.contains("report.pdf"))
        #expect(visited.contains("clip.mov"))
    }
}

@Suite("Queries and filters")
struct QueryTests {
    @Test func largestItemsRanksAndLimits() {
        let tree = makeTree(sample)
        let top = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(limit: 3))
        #expect(top.map { tree[$0].name } == ["clip.mov", "Tool.app", "photo.jpg"])
        let logical = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(limit: 1, metric: .logical))
        #expect(logical.map { tree[$0].name } == ["Sparse.img"])
    }

    @Test func largestFoldersRanksGloballyAndExcludesPackages() {
        let tree = makeTree(sample)
        let top = TreeQueries.largestFolders(in: tree, query: LargestFoldersQuery(limit: 4))
        let names = top.map { tree[$0].name }
        #expect(names == ["Media", "Apps", "Docs", "Old"])
        #expect(!names.contains("Tool.app"))
        #expect(top.map { tree[$0].allocatedSize } == top.map { tree[$0].allocatedSize }.sorted(by: >))

        let logical = TreeQueries.largestFolders(in: tree, query: LargestFoldersQuery(limit: 1, metric: .logical))
        #expect(logical.map { tree[$0].name } == ["Media"])
    }

    @Test func largestFoldersRespectScopeAndHiddenFilter() {
        let tree = makeTree([("Visible/", 0, 0), ("Visible/a", 100, 100), (".Trash/", 0, 0), (".Trash/b", 500, 500)])
        let visibleOnly = TreeQueries.largestFolders(in: tree, query: LargestFoldersQuery(filter: FileFilter(includesHidden: false)))
        #expect(visibleOnly.map { tree[$0].name } == ["Visible"])
        let all = TreeQueries.largestFolders(in: tree, query: LargestFoldersQuery())
        #expect(all.map { tree[$0].name } == [".Trash", "Visible"])

        let sampleTree = makeTree(sample)
        let videos = TreeQueries.largestFolders(in: sampleTree,
            query: LargestFoldersQuery(filter: FileFilter(categories: [.video])))
        #expect(videos.map { sampleTree[$0].name } == ["Media"])
        let archive = TreeQueries.largestFolders(in: sampleTree,
            query: LargestFoldersQuery(filter: FileFilter(nameContains: "archive")))
        #expect(archive.map { sampleTree[$0].name } == ["Docs", "Old"])
    }

    @Test func trashFoldersFindHomeDataVolumeAndExternalTrash() {
        let home = makeTree([(".Trash/", 0, 0), (".Trash/a", 10, 10)], root: "/Users/alice")
        #expect(TreeQueries.trashFolders(in: home, homePath: "/Users/alice", userID: 501).map { home.path(of: $0) } == ["/Users/alice/.Trash"])

        let data = makeTree([("Users/", 0, 0), ("Users/alice/", 0, 0), ("Users/alice/.Trash/", 0, 0), ("Users/alice/.Trash/a", 10, 10)], root: "/System/Volumes/Data")
        #expect(TreeQueries.trashFolders(in: data, homePath: "/Users/alice", userID: 501).map { data.path(of: $0) } == ["/System/Volumes/Data/Users/alice/.Trash"])

        let external = makeTree([(".Trashes/", 0, 0), (".Trashes/501/", 0, 0), (".Trashes/501/a", 10, 10), (".Trashes/502/", 0, 0), (".Trashes/502/b", 20, 20)], root: "/Volumes/External")
        #expect(TreeQueries.trashFolders(in: external, homePath: "/Users/alice", userID: 501).map { external.path(of: $0) } == ["/Volumes/External/.Trashes/501"])
    }

    @Test func largestItemsCanExposePackageContents() {
        let tree = makeTree(sample)
        let query = LargestItemsQuery(limit: 10, treatsPackagesAsItems: false)
        let names = TreeQueries.largestItems(in: tree, query: query).map { tree[$0].name }
        #expect(names.contains("binary"))
        #expect(!names.contains("Tool.app"))
    }

    @Test func largestItemsUnderSubfolder() {
        let tree = makeTree(sample)
        let docs = tree.id("Docs")!
        let names = TreeQueries.largestItems(in: tree, under: docs, query: LargestItemsQuery()).map { tree[$0].name }
        #expect(names == ["archive.zip", "report.pdf", "notes.txt"])
    }

    @Test func heapMatchesFullSortOnRandomData() {
        var generator = SplitMix64(seed: 42)
        var spec: [(String, Int64, Int64)] = []
        for index in 0..<2_000 {
            let size = Int64(generator.next() % 1_000_000)
            spec.append(("f\(index)", size, size))
        }
        let tree = makeTree(spec)
        let top = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(limit: 50)).map { tree[$0].allocatedSize }
        let expected = spec.map(\.2).sorted(by: >).prefix(50)
        #expect(top == Array(expected))
    }

    @Test func filterByNameIsCaseAndDiacriticInsensitive() {
        let tree = makeTree([("Résumé.PDF", 10, 10), ("other.txt", 10, 10)])
        let filter = FileFilter(nameContains: "resume")
        let names = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: filter)).map { tree[$0].name }
        #expect(names == ["Résumé.PDF"])
    }

    @Test func filterByCategoryAndSize() {
        let tree = makeTree(sample)
        var filter = FileFilter(categories: [.video, .image])
        var names = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: filter)).map { tree[$0].name }
        #expect(names == ["clip.mov", "photo.jpg"])
        filter.minimumSize = 500_000
        names = TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: filter)).map { tree[$0].name }
        #expect(names == ["clip.mov"])
    }

    @Test func filterByAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tree = makeTree([("old.txt", 1, 1), ("new.txt", 1, 1)], times: ["old.txt": 1_500_000_000, "new.txt": 1_699_999_000])
        let older = FileFilter(age: .olderThanYear)
        let newer = FileFilter(age: .newerThanWeek)
        #expect(TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: older), now: now).map { tree[$0].name } == ["old.txt"])
        #expect(TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: newer), now: now).map { tree[$0].name } == ["new.txt"])
    }

    @Test func hiddenFilterPrunesHiddenSubtrees() {
        let tree = makeTree([(".cache/", 0, 0), (".cache/big.bin", 9_999, 9_999), ("visible.txt", 1, 1)])
        let filter = FileFilter(includesHidden: false)
        #expect(TreeQueries.largestItems(in: tree, query: LargestItemsQuery(filter: filter)).map { tree[$0].name } == ["visible.txt"])
        #expect(TreeQueries.filteredChildren(in: tree, of: FileTree.rootID, metric: .allocated, filter: filter).map { tree[$0].name } == ["visible.txt"])
    }

    @Test func filteredChildrenKeepPathToMatches() {
        let tree = makeTree(sample)
        let filter = FileFilter(categories: [.archive])
        let top = TreeQueries.filteredChildren(in: tree, of: FileTree.rootID, metric: .allocated, filter: filter)
        #expect(top.map { tree[$0].name } == ["Docs"])
        let docs = TreeQueries.filteredChildren(in: tree, of: tree.id("Docs")!, metric: .allocated, filter: filter)
        #expect(docs.map { tree[$0].name } == ["Old"])
    }

    @Test func noFilterReturnsAllChildren() {
        let tree = makeTree(sample)
        #expect(TreeQueries.filteredChildren(in: tree, of: FileTree.rootID, metric: .allocated, filter: .none).count == 4)
        #expect(!FileFilter.none.isActive)
        #expect(FileFilter(minimumSize: 1).isActive)
    }

    @Test func categoryBreakdownSumsFiles() {
        let tree = makeTree(sample)
        let breakdown = TreeQueries.categoryBreakdown(in: tree)
        #expect(breakdown[.video]?.allocated == 1_003_520)
        #expect(breakdown[.diskImage]?.logical == 50_000_000)
        let total = breakdown.values.reduce(Int64(0)) { $0 + $1.logical }
        #expect(total == tree.root.logicalSize)
    }

    @Test func categoryClassification() {
        #expect(FileCategory.classify(name: "a.MOV", kind: .file, isPackage: false) == .video)
        #expect(FileCategory.classify(name: "Thing.app", kind: .directory, isPackage: true) == .application)
        #expect(FileCategory.classify(name: "Lib.photoslibrary", kind: .directory, isPackage: true) == .package)
        #expect(FileCategory.classify(name: "folder", kind: .directory, isPackage: false) == .folder)
        #expect(FileCategory.classify(name: "noext", kind: .file, isPackage: false) == .other)
        #expect(FileCategory.classify(name: "link.mov", kind: .symlink, isPackage: false) == .other)
    }
}

/// Deterministic PRNG for reproducible property-style tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
