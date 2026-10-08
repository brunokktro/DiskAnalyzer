import Foundation
import Testing
@testable import DiskAnalyzerCore

@Suite("Squarified treemap")
struct TreemapTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 600, height: 400)

    @Test func squarifyTilesExactly() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(weights: weights, in: bounds)
        #expect(rects.count == weights.count)
        let total = weights.reduce(0, +)
        for (rect, weight) in zip(rects, weights) {
            #expect(abs(rect.area - bounds.area * weight / total) < 0.5)
            #expect(rect.x >= -0.001 && rect.y >= -0.001 && rect.maxX <= 600.001 && rect.maxY <= 400.001)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.area } - bounds.area) < 1)
        assertNoOverlap(rects)
    }

    /// The classic 6,6,4,3,2,2,1 example from Bruls et al. stays close to square.
    @Test func squarifyKeepsAspectRatiosReasonable() {
        let rects = TreemapLayout.squarify(weights: [6, 6, 4, 3, 2, 2, 1], in: TreemapRect(x: 0, y: 0, width: 6, height: 4))
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? .infinity
        #expect(worst < 3)
    }

    @Test func squarifyHandlesDegenerateInput() {
        #expect(TreemapLayout.squarify(weights: [], in: bounds).isEmpty)
        #expect(TreemapLayout.squarify(weights: [0, 0], in: bounds).allSatisfy { $0.area == 0 })
        let single = TreemapLayout.squarify(weights: [5], in: bounds)
        #expect(single == [bounds])
        let flat = TreemapLayout.squarify(weights: [1, 1], in: TreemapRect(x: 0, y: 0, width: 0, height: 100))
        #expect(flat.allSatisfy { $0.area == 0 })
    }

    @Test func squarifyRandomInputsAlwaysTile() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let count = Int(generator.next() % 60) + 1
            let weights = (0..<count).map { _ in Double(generator.next() % 10_000 + 1) }.sorted(by: >)
            let width = Double(generator.next() % 900 + 10), height = Double(generator.next() % 900 + 10)
            let rect = TreemapRect(x: 3, y: 5, width: width, height: height)
            let rects = TreemapLayout.squarify(weights: weights, in: rect)
            #expect(abs(rects.reduce(0) { $0 + $1.area } - rect.area) < rect.area * 1e-6 + 1e-6)
            #expect(rects.allSatisfy { $0.width >= -1e-9 && $0.height >= -1e-9 })
        }
    }

    @Test func layoutNestsDirectoriesAndAggregatesTail() {
        var spec: [(String, Int64, Int64)] = [("Big/", 0, 0), ("Big/a", 500_000, 500_000), ("Big/b", 300_000, 300_000), ("solo", 400_000, 400_000)]
        for index in 0..<300 { spec.append(("crumb\(index)", 10, 10)) }
        let tree = makeTree(spec)
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated)
        let big = tiles.first { $0.nodeID == tree.id("Big") }
        #expect(big?.isExpanded == true)
        #expect(tiles.contains { $0.nodeID == tree.id("Big/a") && $0.depth == 1 })
        let aggregate = tiles.first { if case .aggregate = $0.content { return true } else { return false } }
        guard case .aggregate(let parent, let count, let bytes)? = aggregate?.content else {
            Issue.record("expected an aggregate tile"); return
        }
        #expect(parent == FileTree.rootID)
        #expect(count == 300)
        #expect(bytes == 3_000)
        #expect(tiles.count < 20)
    }

    @Test func childrenStayInsideParentTile() {
        let tree = makeTree([("A/", 0, 0), ("A/x", 70, 70), ("A/y", 30, 30), ("B/", 0, 0), ("B/z", 50, 50)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated)
        for tile in tiles where tile.depth == 1 {
            let parentID = tree[tile.nodeID!].parent
            let parent = tiles.first { $0.nodeID == parentID }!
            #expect(tile.rect.x >= parent.rect.x && tile.rect.maxX <= parent.rect.maxX + 1e-6)
            #expect(tile.rect.y >= parent.rect.y && tile.rect.maxY <= parent.rect.maxY + 1e-6)
        }
    }

    @Test func packagesAreNotExpanded() {
        let tree = makeTree([("Tool.app/", 0, 0), ("Tool.app/bin", 100, 100)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated)
        #expect(tiles.count == 1)
        #expect(tiles[0].isExpanded == false)
    }

    @Test func maxDepthLimitsNesting() {
        let tree = makeTree([("a/", 0, 0), ("a/b/", 0, 0), ("a/b/c/", 0, 0), ("a/b/c/f", 100, 100)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated, options: TreemapOptions(maxDepth: 2))
        #expect(tiles.map(\.depth).max() == 1)
    }

    @Test func zeroSizedChildrenAreSkipped() {
        let tree = makeTree([("empty", 0, 0), ("full", 10, 10)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated)
        #expect(tiles.map(\.nodeID) == [tree.id("full")])
    }

    @Test func hitTestPrefersDeepestTile() {
        let tree = makeTree([("A/", 0, 0), ("A/x", 70, 70), ("A/y", 30, 30)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated)
        let x = tiles.first { $0.nodeID == tree.id("A/x") }!
        let hit = TreemapLayout.hitTest(tiles, x: x.rect.x + x.rect.width / 2, y: x.rect.y + x.rect.height / 2)
        #expect(hit?.nodeID == tree.id("A/x"))
        // The header strip belongs to the directory itself.
        let header = TreemapLayout.hitTest(tiles, x: 10, y: 5)
        #expect(header?.nodeID == tree.id("A"))
        #expect(TreemapLayout.hitTest(tiles, x: -1, y: -1) == nil)
    }

    @Test func layoutRespectsFilter() {
        let tree = makeTree([("movie.mov", 900, 900), ("doc.pdf", 100, 100)])
        let tiles = TreemapLayout.layout(tree: tree, focus: FileTree.rootID, in: bounds, metric: .allocated, filter: FileFilter(categories: [.document]))
        #expect(tiles.map(\.nodeID) == [tree.id("doc.pdf")])
        #expect(tiles.first?.rect == bounds)
    }

    private func assertNoOverlap(_ rects: [TreemapRect]) {
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let overlapW = min(a.maxX, b.maxX) - max(a.x, b.x)
                let overlapH = min(a.maxY, b.maxY) - max(a.y, b.y)
                #expect(overlapW <= 1e-6 || overlapH <= 1e-6, "rects \(i) and \(j) overlap")
            }
        }
    }
}
