import DiskAnalyzerCore
import SwiftUI

/// Compares what the scan measured with the volume's used space. Every figure has a text
/// label; nothing is told by color alone.
struct ReconciliationView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Space Reconciliation", systemImage: "chart.bar.doc.horizontal").font(.title2.weight(.semibold))
            if let rec = model.reconciliation {
                ScanLabelsView(labels: model.scanLabels)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        volumeSection(rec)
                        if rec.comparesWithVolume { explainedSection(rec) } else { folderOnlySection(rec) }
                        unmeasuredSection(rec)
                        changeSection(rec)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No scan to compare.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Storage Settings…", systemImage: "gearshape") { model.openStorageSettings() }
                    .help("macOS Storage settings explain system data, snapshots and purgeable space")
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshCurrentBaseline() }
                    .help("Read the volume's figures again")
                Spacer()
                Button("Done") { model.isReconciliationPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func volumeSection(_ rec: SpaceReconciliation) -> some View {
        section("Volume at the end of the scan", footnote: "Reported by the file system. On APFS, capacity and used space belong to the container shared by its volumes.") {
            row("Volume", rec.volumeName.map { "\($0) (\(rec.mountPath ?? ""))" } ?? rec.mountPath ?? "Unknown")
            row("Capacity", bytes(rec.capacity))
            row("Used (capacity − available)", bytes(rec.used))
            row("Available", bytes(rec.available))
            row("Available for important data", bytes(rec.availableForImportantUsage))
            row("Purgeable (estimated)", bytes(rec.purgeableEstimate))
            if let date = rec.baselineDate { row("Read at", date.formatted(date: .abbreviated, time: .standard)) }
        }
    }

    private func explainedSection(_ rec: SpaceReconciliation) -> some View {
        section("Used space, explained", footnote: "Not attributed or shared: other volumes in the same APFS container (system, VM, preboot), local snapshots, file system metadata, purgeable data and folders the scan could not read. Measured beyond used: clones and shared blocks report their full size in every copy, so the scan can measure more than the volume uses. After a folder rescan, the total is the used space at the end of the scan plus what the folder rescans measured, so the rescanned folders are compared with their own change.") {
            row("Measured by this scan", bytes(rec.attributed), symbol: "checkmark.circle")
            row("Not attributed or shared", bytes(rec.unattributed), symbol: "questionmark.circle")
            if rec.rescanAllocatedChange == 0 {
                row("Total used", bytes(rec.accountedUsed), symbol: "equal.circle", emphasized: true)
            } else {
                row("Total used (end of scan + folder rescans)", bytes(rec.accountedUsed), symbol: "equal.circle", emphasized: true)
                row("Used at the end of the scan", bytes(rec.used))
                row("Measured by folder rescans", SizeFormatting.signed(rec.rescanAllocatedChange))
            }
            Divider()
            row("Measured allocation (whole scan)", bytes(rec.measuredAllocated), symbol: "sum")
            row("Measured beyond used", bytes(rec.measuredBeyondUsed), symbol: "plus.square.on.square")
        }
    }

    private func folderOnlySection(_ rec: SpaceReconciliation) -> some View {
        section("Folder scan", footnote: "This scan covers one folder (or crosses into other volumes), so it is not compared with the volume's used space. Scan the volume itself to explain its used space.") {
            row("Measured allocation", bytes(rec.measuredAllocated), symbol: "sum")
        }
    }

    private func unmeasuredSection(_ rec: SpaceReconciliation) -> some View {
        section("Not measured", footnote: "Their sizes are unknown and not part of the measured allocation.") {
            row("Could not be read", "\(rec.inaccessible)", symbol: "lock")
            row("Skipped on purpose", "\(rec.skipped)", symbol: "arrow.uturn.forward")
            if rec.inaccessible + rec.skipped > 0 {
                Button("Show Skipped Items…") { model.isReconciliationPresented = false; model.isIssuesPresented = true }
                    .buttonStyle(.link)
            }
        }
    }

    private func changeSection(_ rec: SpaceReconciliation) -> some View {
        section("Change in used space", footnote: "Positive means the volume uses more space than at the time shown. A folder rescan updates only that folder, so “Since the scan” compares the volume with the full scan plus what the folder rescans measured; changes elsewhere still show here.") {
            row("During the scan", signed(rec.changeDuringScan))
            if !(model.context?.rescannedFolders ?? []).isEmpty { row("Measured by folder rescans", SizeFormatting.signed(rec.rescanAllocatedChange)) }
            row("Since the scan", signed(rec.changeSinceScan))
            if let date = rec.currentBaselineDate { row("Compared at", date.formatted(date: .abbreviated, time: .standard)) }
        }
    }

    // MARK: - Building blocks

    private func section(_ title: String, footnote: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) { content() }
            Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: String, _ value: String, symbol: String? = nil, emphasized: Bool = false) -> some View {
        GridRow {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol ?? "circle.fill").opacity(symbol == nil ? 0 : 1)
            }
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .fontWeight(emphasized ? .semibold : .regular)
    }

    private func bytes(_ value: Int64?) -> String { value.map(SizeFormatting.string) ?? "Not reported" }
    private func signed(_ value: Int64?) -> String { value.map(SizeFormatting.signed) ?? "Cannot compare" }
}
