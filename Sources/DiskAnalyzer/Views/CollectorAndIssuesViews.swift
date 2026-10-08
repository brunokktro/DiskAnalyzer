import DiskAnalyzerCore
import SwiftUI

/// Staging area for "Move to Trash". Nothing is moved until the user confirms.
struct CollectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        let items = model.collector.sorted(by: model.metric)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Collector", systemImage: "tray.full").font(.title3.weight(.semibold))
                Text("Stage items here, review them, then move them to the Trash. Nothing is deleted permanently.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                ContentUnavailableView("Collector Is Empty", systemImage: "tray",
                                       description: Text("Right-click an item and choose Add to Collector."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        CollectorRow(item: item, metric: model.metric)
                            .contextMenu {
                                Button("Reveal in Finder", systemImage: "folder") { model.revealCollected(item) }
                                Button("Remove from Collector", systemImage: "minus.circle") { model.uncollect(item) }
                            }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Items", value: "\(items.count)")
                LabeledContent("Allocated", value: SizeFormatting.string(model.collector.totalAllocated))
                LabeledContent("Logical", value: SizeFormatting.string(model.collector.totalLogical))
                Text("Space returned can differ on APFS: clones, snapshots and hard links share storage.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Clear", role: .cancel) { model.clearCollector() }
                        .disabled(items.isEmpty)
                    Spacer()
                    Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestTrash() }
                        .disabled(!model.canTrash)
                        .keyboardShortcut(.delete, modifiers: [.command])
                        .help(model.isScanning ? "Available when the scan finishes." : "Review, then move the collected items to the Trash.")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 260)
    }
}

private struct CollectorRow: View {
    let item: Collector.Item
    let metric: SizeMetric

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                if item.isHardLinkDuplicate {
                    Label("Same data as another item, not counted again", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                } else if item.hasOtherHardLinks {
                    Label("Other hard links keep this data on disk", systemImage: "link")
                        .font(.caption).foregroundStyle(.orange)
                }
                if item.unmeasuredFolders > 0 {
                    Label("\(item.unmeasuredFolders) unmeasured \(item.unmeasuredFolders == 1 ? "folder" : "folders") inside, real size is larger",
                          systemImage: "lock")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(SizeFormatting.string(item.size(metric))).monospacedDigit()
        }
        .help(item.path)
    }
}

/// Everything the scan could not measure or chose not to enter.
struct IssuesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let result = model.lastResult
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Skipped and Unreadable Items", systemImage: "exclamationmark.shield").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let result {
                Text("Totals exclude what could not be read. Folders protected by macOS privacy controls usually need Full Disk Access for Disk Analyzer in System Settings.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    ForEach(ScanIssue.Kind.allCases, id: \.self) { kind in
                        if let count = result.issueCounts[kind], count > 0 {
                            VStack(alignment: .leading) {
                                Text(SizeFormatting.count(Int64(count))).font(.title3.monospacedDigit().weight(.semibold))
                                Text(kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if result.issues.count < result.totalIssueCount {
                    Text("Showing the first \(result.issues.count) of \(result.totalIssueCount) entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Table(result.issues) {
                    TableColumn("Kind") { issue in
                        Label(issue.kind.title, systemImage: issue.kind.isFailure ? "lock" : "arrow.uturn.right")
                    }
                    .width(min: 150, ideal: 200)
                    TableColumn("Path") { issue in
                        Text(issue.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    TableColumn("Reason") { issue in
                        Text(issue.message).foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 180)
                }
                .contextMenu(forSelectionType: ScanIssue.ID.self) { ids in
                    Button("Reveal in Finder", systemImage: "folder") {
                        model.revealIssues(ids)
                    }
                }
                HStack {
                    Button("Open Privacy & Security Settings…") { model.openPrivacySettings() }
                    Spacer()
                    Button("Export CSV…", systemImage: "square.and.arrow.up") { model.exportIssues() }
                        .disabled(result.issues.isEmpty)
                }
            } else {
                ContentUnavailableView("No Scan Yet", systemImage: "magnifyingglass")
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
    }
}
