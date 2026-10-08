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
            if let result = model.lastResult {
                Section("Current Scan") {
                    LabeledContent("Allocated", value: SizeFormatting.string(model.tree?.root.allocatedSize ?? 0))
                    LabeledContent("Logical", value: SizeFormatting.string(model.tree?.root.logicalSize ?? 0))
                    LabeledContent("Files", value: SizeFormatting.count(Int64(result.statistics.files)))
                    LabeledContent("Folders", value: SizeFormatting.count(Int64(result.statistics.directories)))
                    LabeledContent("Duration", value: result.statistics.duration.formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)))
                }
                .font(.callout)
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
            Text("Scanning \(model.scanRoot?.lastPathComponent ?? "")…").font(.title2.weight(.semibold))
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
