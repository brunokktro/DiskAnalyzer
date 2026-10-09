import DiskAnalyzerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section("Scan") {
                SidebarButton(title: "Home Folder", subtitle: "Current user", symbol: "house") {
                    model.scanHome()
                }
                SidebarButton(title: "Choose Folder…", subtitle: "Any folder you can read", symbol: "folder.badge.plus") {
                    model.chooseFolder()
                }
            }
            Section("Volumes") {
                ForEach(model.volumes) { volume in
                    VolumeRow(volume: volume) { model.scan(volume) }
                }
            }
            if !model.recentScans.isEmpty {
                Section("Recent Scans") {
                    ForEach(model.recentScans) { scan in
                        RecentScanRow(scan: scan, isCurrent: model.context?.root.key == scan.summary.root.key) {
                            model.openRecent(scan)
                        }
                    }
                }
            }
            if let result = model.lastResult {
                Section("Current Scan") {
                    ScanLabelsView(labels: model.scanLabels)
                    if let problem = model.persistenceProblem {
                        Label("Not saved: \(problem)", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Allocated", value: SizeFormatting.string(model.tree?.root.allocatedSize ?? 0))
                    LabeledContent("Logical", value: SizeFormatting.string(model.tree?.root.logicalSize ?? 0))
                    LabeledContent("Files", value: SizeFormatting.count(Int64(result.statistics.files)))
                    LabeledContent("Folders", value: SizeFormatting.count(Int64(result.statistics.directories)))
                    LabeledContent("Duration", value: result.statistics.duration.formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)))
                    LabeledContent("Scanned", value: result.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    Button("Space Reconciliation…", systemImage: "chart.bar.doc.horizontal") { model.showReconciliation() }
                        .buttonStyle(.borderless)
                        .disabled(model.reconciliation == nil)
                        .help("Compare what the scan measured with the volume's used space")
                }
                .font(.callout)
                Section("Trash") {
                    TrashSizingView(model: model)
                }
                Section("Biggest Folders") {
                    SpaceHogsView(model: model)
                }
                Section("Breakdown") {
                    CategoryBreakdownView(model: model)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("Refresh Volumes", systemImage: "arrow.clockwise") { model.refreshVolumes() }
                    .help("Refresh the list of volumes")
            }
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(volume.name, systemImage: volume.isBootVolume ? "internaldrive" : (volume.isRemovable ? "externaldrive" : "externaldrive.connected.to.line.below"))
                if let total = volume.totalCapacity, total > 0 {
                    let free = volume.availableCapacity ?? 0
                    ProgressView(value: Double(total - free), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    Text("\(SizeFormatting.string(free)) free of \(SizeFormatting.string(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Scan \(volume.scanPath) (\(volume.fileSystemType))")
    }
}

private struct TrashSizingView: View {
    let model: AppModel

    var body: some View {
        let insight = model.trashInsight
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.showTrash()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label("Trash", systemImage: "trash")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(SizeFormatting.string(insight.allocated))
                            .monospacedDigit()
                    }
                    Label(insight.coverage.title, systemImage: insight.coverage.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if insight.coverage != .notInScan {
                        Text("\(SizeFormatting.string(insight.logical)) logical · \(SizeFormatting.count(insight.items)) items")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Scan Home or a whole volume to include it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(insight.primaryFolderID == nil)

            if insight.primaryFolderID != nil {
                HStack {
                    Button("View", systemImage: "arrow.right.circle") { model.showTrash() }
                    Button("Rescan", systemImage: "arrow.clockwise") { model.rescanTrash() }
                        .disabled(!model.canRescanTrash)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .help("Trash still consumes disk space until it is emptied. Partial is a lower bound; Changed means Rescan is required for a current total.")
    }
}

private struct SpaceHogsView: View {
    let model: AppModel

    var body: some View {
        let rows = model.spaceHogRows
        let total = max(model.tree?.root.size(model.metric) ?? 0, 1)
        if rows.isEmpty {
            Text("No measured folders in this root.").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                let fraction = Double(row.size(model.metric)) / Double(total)
                Button {
                    model.focus(on: row.id)
                    model.mode = .explore
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(row.name, systemImage: "folder.fill")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(SizeFormatting.string(row.size(model.metric))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ShareBar(fraction: fraction, category: .folder)
                        HStack {
                            Text(SizeFormatting.percent(row.size(model.metric), of: total) + " of scan")
                            Spacer()
                            if fraction >= 0.5 {
                                Label("Dominant", systemImage: "exclamationmark.triangle.fill")
                            } else if fraction >= 0.25 {
                                Label("Large share", systemImage: "exclamationmark.circle")
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("View all biggest folders", systemImage: "list.number") {
                model.focus(on: FileTree.rootID)
                model.mode = .folders
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

private struct CategoryBreakdownView: View {
    let model: AppModel

    var body: some View {
        if model.tree != nil {
            let breakdown = model.categoryBreakdown
            let entries = breakdown.map { (category: $0.key, bytes: model.metric == .allocated ? $0.value.allocated : $0.value.logical) }
                .filter { $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }
            let total = max(entries.reduce(0) { $0 + $1.bytes }, 1)
            ForEach(entries, id: \.category) { entry in
                Button {
                    toggle(entry.category)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(entry.category.title, systemImage: entry.category.symbolName)
                                .foregroundStyle(model.filter.categories.contains(entry.category) ? Color.accentColor : .primary)
                            Spacer()
                            Text(SizeFormatting.string(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ShareBar(fraction: Double(entry.bytes) / Double(total), category: entry.category)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help("Click to filter by \(entry.category.title)")
            }
        }
    }

    private func toggle(_ category: FileCategory) {
        if model.filter.categories.contains(category) {
            model.filter.categories.remove(category)
        } else {
            model.filter.categories.insert(category)
        }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Disk Analyzer").font(.largeTitle.weight(.semibold))
                Text("See what takes up space. Scans read file metadata only and never change your files.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button { model.scanHome() } label: {
                    Label("Scan Home Folder", systemImage: "house").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button { model.chooseFolder() } label: {
                    Label("Choose Folder…", systemImage: "folder").frame(minWidth: 160)
                }
                .controlSize(.large)
                if let data = model.volumes.first(where: \.isBootVolume) {
                    Button { model.scan(data) } label: {
                        Label("Scan \(data.name)", systemImage: "internaldrive").frame(minWidth: 160)
                    }
                    .controlSize(.large)
                }
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                tip("square.grid.3x3.square", "Double-click a treemap tile or a folder to drill down. ⌘↑ goes back up.")
                tip("eye", "Press Space for Quick Look, or right-click for Reveal in Finder.")
                tip("tray.and.arrow.down", "Add items to the Collector, review them, then move them to the Trash.")
                tip("lock.shield", "Folders protected by macOS are listed as skipped, never silently ignored.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        GridRow {
            Image(systemName: symbol).frame(width: 20)
            Text(text)
        }
    }
}

struct ScanProgressView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.scanningTitle).font(.title2.weight(.semibold))
            if model.rescanningFolder != nil {
                Text("The previous results stay as they are until this finishes.")
                    .foregroundStyle(.secondary)
            }
            if let progress = model.progress {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Items", SizeFormatting.count(Int64(progress.entriesVisited)))
                    row("Folders", SizeFormatting.count(Int64(progress.directoriesVisited)))
                    row("Allocated so far", SizeFormatting.string(progress.allocatedBytes))
                    row("Skipped", SizeFormatting.count(Int64(progress.issueCount)))
                    row("Elapsed", progress.elapsed.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                }
                .monospacedDigit()
                Text(progress.currentPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 520)
            } else {
                Text("Starting…").foregroundStyle(.secondary)
            }
            Button("Stop Scan", role: .cancel) { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).gridColumnAlignment(.leading)
        }
    }
}

/// One saved scan. Unavailable ones say why with a symbol and text, and cannot be opened.
private struct RecentScanRow: View {
    let scan: RecentScan
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Label((scan.summary.root.path as NSString).lastPathComponent.nilIfEmpty ?? scan.summary.root.path,
                      systemImage: scan.summary.scope == .volume ? "internaldrive" : "folder")
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(SizeFormatting.string(scan.summary.allocatedBytes)) · \(scan.summary.savedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if !scan.summary.isCompatible {
                    Label("Saved by another version", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !scan.availability.isRestorable {
                    Label(scan.availability.title, systemImage: scan.availability.symbolName)
                        .font(.caption).foregroundStyle(.secondary)
                } else if scan.summary.isPartial {
                    Label("Partial", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(scan.canOpen ? 1 : 0.6)
        .help(scan.canOpen ? "Open the saved scan of \(scan.summary.root.path)" : scan.availability.explanation)
    }
}

/// Status labels of the current scan: symbol plus text, with the explanation on hover.
struct ScanLabelsView: View {
    let labels: [ScanLabel]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(labels, id: \.self) { label in
                Label(label.title, systemImage: label.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(label.detail)
                    .accessibilityHint(label.detail)
            }
        }
    }
}
