import DiskAnalyzerCore
import QuickLook
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .navigationTitle(model.tree.map { _ in model.displayName(model.focus) } ?? "Disk Analyzer")
        .navigationSubtitle(model.tree.map { $0.path(of: model.focus) } ?? "")
        .toolbar { MainToolbar(model: model) }
        .inspector(isPresented: $model.isCollectorPresented) {
            CollectorView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $model.isIssuesPresented) { IssuesView(model: model) }
        .confirmationDialog(trashTitle, isPresented: $model.isTrashConfirmationPresented, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.performTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
        .alert("Moved to Trash", isPresented: summaryBinding, presenting: model.trashSummary) { _ in
            Button("OK") { model.trashSummary = nil }
        } message: { summary in
            Text(summaryText(summary))
        }
        .alert("Disk Analyzer", isPresented: alertBinding, presenting: model.alertMessage) { _ in
            Button("OK") { model.alertMessage = nil }
        } message: { Text($0) }
    }

    @ViewBuilder private var detail: some View {
        if model.isScanning {
            ScanProgressView(model: model)
        } else if model.tree != nil {
            BrowserView(model: model)
        } else {
            WelcomeView(model: model)
        }
    }

    private var trashTitle: String {
        let count = model.collector.count
        return "Move \(count) \(count == 1 ? "item" : "items") (\(SizeFormatting.string(model.collector.totalAllocated))) to the Trash?"
    }

    private var trashMessage: String {
        var text = "Each item is checked again before it moves. You can restore everything from the Trash until you empty it."
        let unmeasured = model.collector.unmeasuredFolders
        if unmeasured > 0 {
            text += " \(unmeasured) \(unmeasured == 1 ? "folder" : "folders") inside could not be measured, so more than the size shown will move."
        }
        return text
    }

    private var summaryBinding: Binding<Bool> {
        Binding(get: { model.trashSummary != nil }, set: { if !$0 { model.trashSummary = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    private func summaryText(_ summary: TrashSummary) -> String {
        var lines = ["\(summary.moved) moved to the Trash. About \(SizeFormatting.string(summary.freedAllocated)) allocated, freed once the Trash is emptied (APFS clones, snapshots and hard links can keep some of it)."]
        if !summary.problems.isEmpty {
            lines.append("\(summary.problems.count) not moved and kept in the Collector:")
            for outcome in summary.problems.prefix(6) {
                switch outcome.status {
                case .refused(let refusal): lines.append("• \((outcome.path as NSString).lastPathComponent): \(refusal.localizedDescription)")
                case .failed(let message): lines.append("• \((outcome.path as NSString).lastPathComponent): \(message)")
                case .moved: break
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct MainToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.up") { model.goUp() }
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.tree == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Size", selection: $model.metric) {
                ForEach(SizeMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Allocated: storage the file system reports in use. Logical: size of the content.")
            if model.isScanning {
                Button("Stop", systemImage: "stop.circle") { model.cancelScan() }
            } else {
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                    .disabled(model.scanRoot == nil)
            }
            Button("Collector", systemImage: model.collector.isEmpty ? "tray" : "tray.full") {
                model.isCollectorPresented.toggle()
            }
            .help("Show the Collector (\(model.collector.count) items)")
        }
    }
}

struct BrowserView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model)
            Divider()
            FilterBar(model: model)
            Divider()
            switch model.mode {
            case .explore:
                HSplitView {
                    DirectoryListView(model: model)
                        .frame(minWidth: 380, idealWidth: 520)
                    TreemapView(model: model)
                        .frame(minWidth: 320)
                        .padding(6)
                        .background(.background)
                }
            case .largest:
                LargestItemsView(model: model)
            }
            Divider()
            StatusBar(model: model)
        }
    }
}

struct BreadcrumbBar: View {
    let model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let lineage = model.breadcrumb
                ForEach(Array(lineage.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        model.focus(on: id)
                    } label: {
                        Label(model.displayName(id), systemImage: index == 0 ? "externaldrive" : "folder")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fontWeight(index == lineage.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.borderless)
                    .contextMenu { ItemActions(model: model, ids: [id]) }
                }
                Spacer(minLength: 12)
                if let node = model.focusNode {
                    Text("\(SizeFormatting.string(node.size(model.metric))) · \(SizeFormatting.count(node.itemCount)) items")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

struct FilterBar: View {
    @Bindable var model: AppModel

    private static let sizeThresholds: [(String, Int64)] = [
        ("Any size", 0), ("≥ 1 MB", 1_000_000), ("≥ 10 MB", 10_000_000), ("≥ 100 MB", 100_000_000), ("≥ 1 GB", 1_000_000_000),
    ]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(model.filter.isActive ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            TextField("Filter by name", text: $model.filter.nameContains)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("Size", selection: $model.filter.minimumSize) {
                ForEach(Self.sizeThresholds, id: \.1) { Text($0.0).tag($0.1) }
            }
            .fixedSize()
            Picker("Modified", selection: $model.filter.age) {
                ForEach(FileFilter.Age.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Menu {
                ForEach(FileCategory.allCases.filter { $0 != .folder }) { category in
                    Toggle(isOn: Binding(
                        get: { model.filter.categories.contains(category) },
                        set: { isOn in
                            if isOn { model.filter.categories.insert(category) } else { model.filter.categories.remove(category) }
                        })) {
                        Label(category.title, systemImage: category.symbolName)
                    }
                }
                Divider()
                Button("All Kinds") { model.filter.categories = [] }
            } label: {
                Text(model.filter.categories.isEmpty ? "All kinds" : model.filter.categories.map(\.title).sorted().joined(separator: ", "))
                    .lineLimit(1)
            }
            .fixedSize()
            Toggle("Hidden", isOn: $model.filter.includesHidden)
                .toggleStyle(.checkbox)
                .help("Include dot-files and items flagged hidden")
            Spacer()
            if model.filter.isActive {
                Button("Clear Filters") { model.filter = FileFilter() }
                    .buttonStyle(.link)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let tree = model.tree, let result = model.lastResult {
                Label("\(SizeFormatting.string(tree.root.allocatedSize)) allocated", systemImage: "internaldrive")
                Label("\(SizeFormatting.string(tree.root.logicalSize)) logical", systemImage: "doc")
                Label("\(SizeFormatting.count(tree.root.itemCount)) items", systemImage: "number")
                if result.statistics.hardLinkDuplicates > 0 {
                    let count = result.statistics.hardLinkDuplicates
                    Label("\(SizeFormatting.count(Int64(count))) duplicate hard \(count == 1 ? "link" : "links") not counted", systemImage: "link")
                        .help("Files with several hard links are counted once, at the first path found")
                }
                if result.statistics.foldersAlreadyCounted > 0 {
                    let count = result.statistics.foldersAlreadyCounted
                    Label("\(SizeFormatting.count(Int64(count))) \(count == 1 ? "folder" : "folders") counted at another path", systemImage: "arrow.triangle.branch")
                        .help("Folders reached twice, for example through APFS firmlinks, are counted once, at the first path found")
                }
                Spacer()
                let failures = result.failureCount
                let skipped = result.totalIssueCount
                Button {
                    model.isIssuesPresented = true
                } label: {
                    Label(skipped == 0 ? "Everything was readable" : "\(SizeFormatting.count(Int64(failures))) unreadable · \(SizeFormatting.count(Int64(skipped - failures))) skipped",
                          systemImage: failures > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Show what the scan could not read or did not enter")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
