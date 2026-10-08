import Foundation

/// Plain rectangle so the layout stays independent of AppKit/CoreGraphics and easy to test.
public struct TreemapRect: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var area: Double { width * height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    func inset(by amount: Double, top: Double = 0) -> TreemapRect {
        TreemapRect(x: x + amount, y: y + amount + top,
                    width: max(0, width - 2 * amount), height: max(0, height - 2 * amount - top))
    }
}

public struct TreemapTile: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case node(NodeID)
        /// Items too small to draw individually, merged into one tile.
        case aggregate(parent: NodeID, count: Int, bytes: Int64)
    }

    public let id: Int
    public let content: Content
    public let rect: TreemapRect
    public let depth: Int
    /// `true` for directories whose children were laid out inside the tile.
    public let isExpanded: Bool

    public var nodeID: NodeID? {
        if case .node(let id) = content { return id }
        return nil
    }
}

public struct TreemapOptions: Sendable, Hashable {
    /// How many directory levels are drawn nested inside the focus directory.
    public var maxDepth: Int
    /// Tiles smaller than this (in points²) are merged into an aggregate tile.
    public var minimumTileArea: Double
    /// Height reserved at the top of an expanded directory for its label.
    public var headerHeight: Double
    /// Gap between a directory border and its children.
    public var padding: Double
    /// Directories smaller than this are not expanded (their children would be unreadable).
    public var minimumExpandableSide: Double

    public init(maxDepth: Int = 3, minimumTileArea: Double = 36, headerHeight: Double = 16, padding: Double = 2, minimumExpandableSide: Double = 48) {
        self.maxDepth = maxDepth
        self.minimumTileArea = minimumTileArea
        self.headerHeight = headerHeight
        self.padding = padding
        self.minimumExpandableSide = minimumExpandableSide
    }
}

/// Squarified treemap (Bruls, Huizing & van Wijk, 2000): rows are filled greedily while
/// the worst aspect ratio in the row keeps improving, which keeps tiles close to square.
public enum TreemapLayout {
    public static func layout(
        tree: FileTree,
        focus: NodeID,
        in bounds: TreemapRect,
        metric: SizeMetric,
        filter: FileFilter = .none,
        options: TreemapOptions = TreemapOptions()
    ) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        guard bounds.width > 0, bounds.height > 0, tree.contains(focus) else { return tiles }
        let now = Date()
        layoutChildren(of: focus, in: bounds, depth: 0)
        return tiles

        func layoutChildren(of parent: NodeID, in rect: TreemapRect, depth: Int) {
            // Hard-link duplicates are not part of their parent's size, so they get no area either.
            let children = TreeQueries.filteredChildren(in: tree, of: parent, metric: metric, filter: filter, now: now)
                .filter { tree[$0].size(metric) > 0 && !tree[$0].flags.contains(.hardLinkDuplicate) }
            guard !children.isEmpty, rect.area > 0 else { return }
            let sizes = children.map { Double(tree[$0].size(metric)) }
            let total = sizes.reduce(0, +)
            guard total > 0 else { return }

            // Merge the tail that would render below the readable threshold.
            let scale = rect.area / total
            var visibleCount = children.count
            while visibleCount > 1, sizes[visibleCount - 1] * scale < options.minimumTileArea { visibleCount -= 1 }
            var weights = Array(sizes[0..<visibleCount])
            var aggregate: (count: Int, bytes: Int64)?
            if visibleCount < children.count {
                let rest = children[visibleCount...]
                let bytes = rest.reduce(Int64(0)) { $0 + tree[$1].size(metric) }
                aggregate = (rest.count, bytes)
                weights.append(Double(bytes))
            }

            let rects = squarify(weights: weights, in: rect)
            for (index, tileRect) in rects.enumerated() {
                if index == visibleCount, let aggregate {
                    tiles.append(TreemapTile(id: tiles.count, content: .aggregate(parent: parent, count: aggregate.count, bytes: aggregate.bytes),
                                             rect: tileRect, depth: depth, isExpanded: false))
                    continue
                }
                let child = children[index]
                let node = tree[child]
                let canExpand = node.isDirectory && !node.isPackage && depth + 1 < options.maxDepth
                    && min(tileRect.width, tileRect.height) >= options.minimumExpandableSide
                    && node.childCount > 0
                tiles.append(TreemapTile(id: tiles.count, content: .node(child), rect: tileRect, depth: depth, isExpanded: canExpand))
                if canExpand {
                    layoutChildren(of: child, in: tileRect.inset(by: options.padding, top: options.headerHeight), depth: depth + 1)
                }
            }
        }
    }

    /// Returns one rectangle per weight, in the same order, tiling `rect` exactly.
    /// Weights must be sorted descending for the classic quality guarantees.
    public static func squarify(weights: [Double], in rect: TreemapRect) -> [TreemapRect] {
        let total = weights.reduce(0, +)
        guard total > 0, rect.area > 0 else { return weights.map { _ in TreemapRect(x: rect.x, y: rect.y, width: 0, height: 0) } }
        let scale = rect.area / total
        let areas = weights.map { $0 * scale }
        var result: [TreemapRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var index = 0

        while index < areas.count {
            let side = min(remaining.width, remaining.height)
            var rowEnd = index + 1
            var rowArea = areas[index]
            var best = worstRatio(areas[index..<rowEnd], rowArea: rowArea, side: side)
            while rowEnd < areas.count {
                let candidateArea = rowArea + areas[rowEnd]
                let candidate = worstRatio(areas[index...rowEnd], rowArea: candidateArea, side: side)
                guard candidate <= best else { break }
                best = candidate
                rowArea = candidateArea
                rowEnd += 1
            }
            let isLastRow = rowEnd == areas.count
            remaining = placeRow(areas[index..<rowEnd], rowArea: rowArea, in: remaining, fillsRemaining: isLastRow, into: &result)
            index = rowEnd
        }
        return result
    }

    private static func worstRatio(_ row: ArraySlice<Double>, rowArea: Double, side: Double) -> Double {
        guard rowArea > 0, side > 0 else { return .infinity }
        let thickness = rowArea / side
        var worst = 1.0
        for area in row where area > 0 {
            let length = area / thickness
            worst = max(worst, max(length / thickness, thickness / length))
        }
        return worst
    }

    /// Places a row along the shorter side of `rect` and returns the space left over.
    private static func placeRow(_ row: ArraySlice<Double>, rowArea: Double, in rect: TreemapRect, fillsRemaining: Bool, into result: inout [TreemapRect]) -> TreemapRect {
        let horizontal = rect.width >= rect.height // stack the row vertically along the left edge
        let side = horizontal ? rect.height : rect.width
        let thickness = fillsRemaining ? (horizontal ? rect.width : rect.height) : (side > 0 ? rowArea / side : 0)
        var offset = 0.0
        for (position, area) in row.enumerated() {
            let isLast = position == row.count - 1
            let length = isLast ? side - offset : (rowArea > 0 ? side * area / rowArea : 0)
            if horizontal {
                result.append(TreemapRect(x: rect.x, y: rect.y + offset, width: thickness, height: length))
            } else {
                result.append(TreemapRect(x: rect.x + offset, y: rect.y, width: length, height: thickness))
            }
            offset += length
        }
        if horizontal {
            return TreemapRect(x: rect.x + thickness, y: rect.y, width: max(0, rect.width - thickness), height: rect.height)
        }
        return TreemapRect(x: rect.x, y: rect.y + thickness, width: rect.width, height: max(0, rect.height - thickness))
    }

    /// Deepest tile under a point; aggregate tiles win over the directory that contains them.
    public static func hitTest(_ tiles: [TreemapTile], x: Double, y: Double) -> TreemapTile? {
        var hit: TreemapTile?
        for tile in tiles where tile.rect.contains(x: x, y: y) {
            if hit == nil || tile.depth >= hit!.depth { hit = tile }
        }
        return hit
    }
}
