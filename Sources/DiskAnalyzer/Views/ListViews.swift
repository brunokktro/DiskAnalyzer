import DiskAnalyzerCore
import SwiftUI

/// Context-menu actions shared by the list, the Largest Items table and the treemap.
struct ItemActions: View {
    let model: AppModel
    let ids: Set<NodeID>

    var body: some View {
        if let tree = model.tree, !ids.isEmpty {
            let single = ids.count == 1 ? ids.first : nil
            if let single, tree[single].isDirectory, !tree[single].isPackage {
                Button("Open Folder", systemImage: "arrow.down.right.circle") { model.focus(on: single) }
            }
            let anyExact = ids.contains(where: model.hasExactPath)
            if let single {
                Button("Quick Look", systemImage: "eye") { model.quickLook(single) }
                    .disabled(!anyExact)
            }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(ids) }
                .disabled(!anyExact)
            Button(ids.count == 1 ? "Copy Path" : "Copy Paths", systemImage: "doc.on.doc") { model.copyPaths(ids) }
                .disabled(!anyExact)
            Divider()
            Button("Add to Collector", systemImage: "tray.and.arrow.down") { model.collect(ids) }
                .disabled(!ids.contains(where: model.canCollect))
        }
    }
}

/// Children of the focus folder with share bars. Selection is shared with the treemap.
struct DirectoryListView: View {
    @Bindable var model: AppModel

    var body: some View {
        let rows = model.rows
        let total = max(model.focusNode?.size(model.metric) ?? 0, 1)
        Table(rows, selection: $model.listSelection, sortOrder: $model.listSortOrder) {
            columns(total: total)
        }
        .contextMenu(forSelectionType: NodeID.self) { ids in
            ItemActions(model: model, ids: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.activate(id) }
        }
        .onKeyPress(.space) {
            model.quickLookSelection()
            return .handled
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(model.filter.isActive ? "No Matches" : "Empty Folder",
                                       systemImage: model.filter.isActive ? "line.3.horizontal.decrease.circle" : "folder",
                                       description: Text(model.filter.isActive ? "No item in this folder matches the filter." : "This folder has no items."))
            }
        }
    }
}

extension DirectoryListView {
    @TableColumnBuilder<EntryRow, KeyPathComparator<EntryRow>>
    func columns(total: Int64) -> some TableColumnContent<EntryRow, KeyPathComparator<EntryRow>> {
        TableColumn("Name", value: \EntryRow.name) { (row: EntryRow) in
            NameCell(row: row)
        }
        .width(min: 140, ideal: 200)
        TableColumn(model.metric.title, value: model.metric.rowKeyPath) { (row: EntryRow) in
            SizeCell(bytes: row.size(model.metric), total: total, category: row.category)
        }
        .width(min: 120, ideal: 140)
        TableColumn("Items", value: \EntryRow.items) { (row: EntryRow) in
            Text(verbatim: row.isDirectory ? SizeFormatting.count(row.items) : "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 44, ideal: 56)
        TableColumn("Modified", value: \EntryRow.modified) { (row: EntryRow) in
            DateCell(date: row.modified)
        }
        .width(min: 80, ideal: 100)
    }
}

extension SizeMetric {
    /// Written as a `switch`: a ternary between two key-path literals crashes the Swift 6.4 type checker.
    var rowKeyPath: KeyPath<EntryRow, Int64> {
        switch self {
        case .allocated: return \EntryRow.allocated
        case .logical: return \EntryRow.logical
        }
    }
}

struct DateCell: View {
    let date: Date
    var body: some View {
        Text(date, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary)
    }
}

struct NameCell: View {
    let row: EntryRow
    var location: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.symbol(for: row))
                .foregroundStyle(Theme.color(row.category))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if let location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            FlagBadges(flags: row.flags)
        }
        .opacity(row.flags.contains(.hardLinkDuplicate) ? 0.6 : 1)
        .help(row.kindLabel)
    }
}

struct SizeCell: View {
    let bytes: Int64
    let total: Int64
    let category: FileCategory

    var body: some View {
        HStack(spacing: 8) {
            ShareBar(fraction: Double(bytes) / Double(max(total, 1)), category: category)
                .frame(minWidth: 30)
            Text(SizeFormatting.string(bytes))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .help(SizeFormatting.percent(bytes, of: total) + " of this folder")
    }
}

/// Top files and packages below the focus folder.
struct LargestItemsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let rows = model.largestRows
        let total = max(model.focusNode?.size(model.metric) ?? 0, 1)
        VStack(spacing: 0) {
            HStack {
                Text("Largest files and packages in \(model.displayName(model.focus))")
                    .font(.headline)
                Text("(top \(rows.count), hard links counted once)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…", systemImage: "square.and.arrow.up") { model.exportLargest() }
                    .disabled(rows.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(rows, selection: $model.listSelection, sortOrder: $model.listSortOrder) {
                columns(total: total)
            }
            .contextMenu(forSelectionType: NodeID.self) { ids in
                ItemActions(model: model, ids: ids)
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.quickLook(id) }
            }
            .onKeyPress(.space) {
                model.quickLookSelection()
                return .handled
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "doc.questionmark",
                                           description: Text(model.filter.isActive ? "No file matches the filter." : "No files below this folder."))
                }
            }
        }
    }
}

extension LargestItemsView {
    @TableColumnBuilder<EntryRow, KeyPathComparator<EntryRow>>
    func columns(total: Int64) -> some TableColumnContent<EntryRow, KeyPathComparator<EntryRow>> {
        TableColumn("Name", value: \EntryRow.name) { (row: EntryRow) in
            NameCell(row: row, location: model.relativeLocation(of: row.id))
        }
        .width(min: 200, ideal: 340)
        TableColumn(model.metric.title, value: model.metric.rowKeyPath) { (row: EntryRow) in
            SizeCell(bytes: row.size(model.metric), total: total, category: row.category)
        }
        .width(min: 140, ideal: 180)
        TableColumn("Kind", value: \EntryRow.kindLabel) { (row: EntryRow) in
            Text(row.kindLabel).foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 100)
        TableColumn("Modified", value: \EntryRow.modified) { (row: EntryRow) in
            DateCell(date: row.modified)
        }
        .width(min: 80, ideal: 100)
    }
}
