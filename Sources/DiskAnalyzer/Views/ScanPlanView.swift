import DiskAnalyzerCore
import Foundation
import SwiftUI

struct ScanPlanView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let proposal = model.pendingScan, let estimate = model.pendingScanEstimate {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plan Full Scan").font(.title2.weight(.semibold))
                        Text((proposal.root.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "internaldrive.fill").font(.title).foregroundStyle(.secondary)
                }

                if let date = proposal.lastScannedAt {
                    Label {
                        Text("Last scanned \(date.formatted(date: .abbreviated, time: .shortened)), \(date.formatted(.relative(presentation: .named))).")
                    } icon: { Image(systemName: "clock.arrow.circlepath") }
                    .font(.callout)
                } else {
                    Label("No previous scan for this root", systemImage: "clock.badge.questionmark")
                        .font(.callout)
                }

                if let bytes = proposal.estimatedBytes {
                    LabeledContent(proposal.bytesAreUpperBound ? "Upper-bound scope" : "Estimated scope",
                                   value: SizeFormatting.string(bytes))
                        .font(.callout)
                }

                Picker("Cloud files", selection: $model.pendingCloudMode) {
                    ForEach(CloudScanMode.selectableCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.pendingCloudMode.title,
                              systemImage: model.pendingCloudMode == .localOnly ? "externaldrive.badge.checkmark" : "icloud")
                            .font(.headline)
                        Text(model.pendingCloudMode.shortDetail)
                            .foregroundStyle(.secondary)
                        if model.pendingCloudMode == .localOnly {
                            Text("Dataless cloud folders are skipped and reported. The result is a safe lower bound for local storage and does not download cloud content.")
                        } else {
                            Text("Disk Analyzer traverses File Provider folder metadata. It still never opens file contents, but OneDrive, WorkDocs or iCloud may grow their metadata cache and the scan can take much longer.")
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Estimated time", value: Self.range(estimate))
                        .font(.title3.weight(.semibold))
                    Text(Self.basis(estimate.basis))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Actual time depends mostly on item count, SSD speed, permissions, current system load and File Provider response time.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Cancel", role: .cancel) { model.cancelPendingScan() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Start Scan") { model.confirmPendingScan() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 590)
        }
    }

    private static func range(_ estimate: ScanDurationEstimate) -> String {
        let lower = time(estimate.lowerSeconds)
        let upper = time(estimate.upperSeconds)
        return lower == upper ? lower : "\(lower) to \(upper)"
    }

    private static func time(_ seconds: Int) -> String {
        if seconds < 60 { return "under 1 min" }
        if seconds < 3_600 { return "\(max(1, Int(ceil(Double(seconds) / 60)))) min" }
        let hours = Double(seconds) / 3_600
        return hours < 2 ? String(format: "%.1f hr", hours) : "\(Int(ceil(hours))) hr"
    }

    private static func basis(_ basis: ScanDurationEstimate.Basis) -> String {
        switch basis {
        case .previousScan: "Calibrated from the previous scan of this root."
        case .usedBytes: "Broad estimate based on the storage currently used on the volume."
        case .unknown: "No previous measurement is available, so this is a conservative first-scan range."
        }
    }
}
