import DiskAnalyzerCore
import SwiftUI

/// Squarified treemap of the focus folder. Click selects, double-click drills down,
/// the context menu exposes the Finder actions. Drawing happens in a `Canvas`; an
/// accessibility child is exposed per top-level tile so VoiceOver can read it.
struct TreemapView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let tiles = model.tiles(for: proxy.size)
            ZStack {
                if let tree = model.tree {
                    TreemapCanvas(tree: tree, tiles: tiles, metric: model.metric,
                                  selection: model.listSelection, hover: model.hover)
                }
                if tiles.isEmpty {
                    ContentUnavailableView(model.filter.isActive ? "Nothing Matches the Filter" : "Nothing to Draw",
                                           systemImage: "square.dashed",
                                           description: Text(model.filter.isActive ? "Clear or relax the filter to see this folder." : "This folder has no measurable content."))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let hit = TreemapLayout.hitTest(tiles, x: point.x, y: point.y)
                    if hit?.id != model.hover.tile?.id { model.hover.tile = hit }
                case .ended:
                    model.hover.tile = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard let tile = TreemapLayout.hitTest(tiles, x: value.location.x, y: value.location.y) else { return }
                    drillDown(tile)
                }.exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                    let tile = TreemapLayout.hitTest(tiles, x: value.location.x, y: value.location.y)
                    model.listSelection = tile?.nodeID.map { [$0] } ?? []
                })
            )
            .contextMenu {
                if let id = model.hover.tile?.nodeID {
                    ItemActions(model: model, ids: [id])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Treemap of \(model.displayName(model.focus))")
            .accessibilityChildren {
                ForEach(tiles.filter { $0.depth == 0 }) { tile in
                    Rectangle().accessibilityLabel(accessibilityText(tile))
                }
            }
        }
        .overlay(alignment: .bottomLeading) { HoverCaption(model: model) }
    }

    /// Drill into the folder under the pointer, or into the folder that owns the tile.
    private func drillDown(_ tile: TreemapTile) {
        guard let tree = model.tree else { return }
        switch tile.content {
        case .node(let id):
            var target = id
            if !tree[target].isDirectory || tree[target].isPackage { target = tree[target].parent }
            // Step one level below the focus, towards the clicked tile.
            let lineage = tree.lineage(of: target)
            if let index = lineage.firstIndex(of: model.focus), index + 1 < lineage.count {
                model.focus(on: lineage[index + 1])
            } else if target != model.focus {
                model.focus(on: target)
            } else {
                model.activate(id)
            }
        case .aggregate(let parent, _, _):
            if parent != model.focus { model.focus(on: parent) }
        }
    }

    private func accessibilityText(_ tile: TreemapTile) -> String {
        guard let tree = model.tree else { return "" }
        switch tile.content {
        case .node(let id):
            return "\(tree[id].name), \(SizeFormatting.string(tree[id].size(model.metric)))"
        case .aggregate(_, let count, let bytes):
            return "\(count) smaller items, \(SizeFormatting.string(bytes))"
        }
    }
}

private struct TreemapCanvas: View {
    let tree: FileTree
    let tiles: [TreemapTile]
    let metric: SizeMetric
    let selection: Set<NodeID>
    let hover: HoverState

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for tile in tiles { draw(tile, in: &context) }
            if let hovered = hover.tile {
                let rect = cgRect(hovered.rect).insetBy(dx: 0.5, dy: 0.5)
                context.stroke(Path(rect), with: .color(.primary.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
            for tile in tiles where tile.nodeID.map(selection.contains) == true {
                let rect = cgRect(tile.rect).insetBy(dx: 1, dy: 1)
                // Double outline: readable on light and dark tiles without relying on hue.
                context.stroke(Path(rect), with: .color(.black.opacity(0.9)), lineWidth: 3)
                context.stroke(Path(rect.insetBy(dx: 1.5, dy: 1.5)), with: .color(.white), lineWidth: 1.5)
            }
        }
    }

    private func cgRect(_ rect: TreemapRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func draw(_ tile: TreemapTile, in context: inout GraphicsContext) {
        let rect = cgRect(tile.rect).insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        switch tile.content {
        case .aggregate(_, let count, let bytes):
            context.fill(Path(rect), with: .color(Color.gray.opacity(0.25)))
            hatch(rect, in: &context)
            label("\(count) smaller items", detail: SizeFormatting.string(bytes), in: rect, context: &context, color: .secondary)
        case .node(let id):
            let node = tree[id]
            let category = FileCategory.classify(node)
            let base = Theme.color(category)
            if tile.isExpanded {
                context.fill(Path(rect), with: .color(base.opacity(0.16 + 0.06 * Double(tile.depth))))
                context.stroke(Path(rect), with: .color(base.opacity(0.7)), lineWidth: 1)
                let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(16, rect.height))
                context.fill(Path(header), with: .color(base.opacity(0.35)))
                label(node.name, detail: SizeFormatting.string(node.size(metric)), in: header, context: &context, color: .primary, header: true)
            } else {
                let brightness = node.isDirectory ? 0.78 : 0.92
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [base.opacity(brightness), base.opacity(brightness - 0.22)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.stroke(Path(rect), with: .color(.black.opacity(0.18)), lineWidth: 0.5)
                if node.isDirectory { hatch(rect, in: &context, opacity: 0.08) }
                label(node.name, detail: SizeFormatting.string(node.size(metric)), in: rect, context: &context, color: .white)
            }
        }
    }

    /// Diagonal hatching distinguishes aggregates and collapsed folders by texture, not hue.
    private func hatch(_ rect: CGRect, in context: inout GraphicsContext, opacity: Double = 0.18) {
        var path = Path()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 7
        }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.stroke(path, with: .color(.black.opacity(opacity)), lineWidth: 1)
        }
    }

    private func label(_ title: String, detail: String, in rect: CGRect, context: inout GraphicsContext, color: Color, header: Bool = false) {
        guard rect.width > 34, rect.height > 13 else { return }
        let inset = rect.insetBy(dx: 4, dy: header ? 1 : 3)
        let showsDetail = !header && rect.height > 30 && rect.width > 50
        let text = Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        context.draw(text, in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14))
        if header, rect.width > 140 {
            let size = Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            context.draw(size, at: CGPoint(x: inset.maxX, y: inset.minY + 7), anchor: .trailing)
        }
        if showsDetail {
            let size = Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(color.opacity(0.85))
            context.draw(size, in: CGRect(x: inset.minX, y: inset.minY + 14, width: inset.width, height: 13))
        }
    }
}

/// Floating caption with the full name, size and share of the tile under the pointer.
private struct HoverCaption: View {
    let model: AppModel

    var body: some View {
        if let tile = model.hover.tile, let tree = model.tree {
            let (title, bytes, symbol): (String, Int64, String) = {
                switch tile.content {
                case .node(let id): (tree.path(of: id), tree[id].size(model.metric), FileCategory.classify(tree[id]).symbolName)
                case .aggregate(_, let count, let bytes): ("\(count) smaller items", bytes, "square.stack.3d.down.right")
                }
            }()
            let total = model.focusNode?.size(model.metric) ?? 0
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).truncationMode(.middle)
                Text("\(SizeFormatting.string(bytes)) · \(SizeFormatting.percent(bytes, of: total))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            .allowsHitTesting(false)
        }
    }
}
