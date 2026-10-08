import DiskAnalyzerCore
import SwiftUI

/// Category palette. Every color is always paired with an SF Symbol and a text label,
/// so no information depends on telling colors apart.
enum Theme {
    static func color(_ category: FileCategory) -> Color {
        switch category {
        case .folder: Color(red: 0.36, green: 0.55, blue: 0.85)
        case .package: Color(red: 0.55, green: 0.47, blue: 0.83)
        case .image: Color(red: 0.93, green: 0.62, blue: 0.24)
        case .video: Color(red: 0.86, green: 0.36, blue: 0.40)
        case .audio: Color(red: 0.82, green: 0.42, blue: 0.70)
        case .document: Color(red: 0.32, green: 0.68, blue: 0.56)
        case .archive: Color(red: 0.62, green: 0.52, blue: 0.38)
        case .diskImage: Color(red: 0.45, green: 0.50, blue: 0.58)
        case .code: Color(red: 0.30, green: 0.66, blue: 0.80)
        case .application: Color(red: 0.42, green: 0.42, blue: 0.86)
        case .other: Color(red: 0.62, green: 0.64, blue: 0.67)
        }
    }

    static func symbol(for row: EntryRow) -> String {
        switch row.kind {
        case .directory: row.flags.contains(.unreadable) ? "lock.fill" : row.category.symbolName
        case .symlink: "arrow.uturn.right"
        case .other: row.flags.contains(.unreadable) ? "exclamationmark.triangle" : "questionmark.square.dashed"
        case .file: row.category.symbolName
        }
    }
}

/// Horizontal share bar used in lists. The percentage is also printed next to it.
struct ShareBar: View {
    let fraction: Double
    let category: FileCategory

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.color(category).gradient)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct FlagBadges: View {
    let flags: NodeFlags

    var body: some View {
        HStack(spacing: 3) {
            if flags.contains(.unreadable) { badge("lock.fill", "Could not be read") }
            if flags.contains(.alreadyCounted) {
                badge("arrow.triangle.branch", "Same folder as another path in this scan, counted once there")
            } else if flags.contains(.hardLinkDuplicate) {
                badge("link", "Hard link, counted once elsewhere")
            }
            if flags.contains(.invalidName) { badge("questionmark.square.dashed", "Name is not valid UTF-8; Finder actions are disabled") }
            if flags.contains(.otherVolume) { badge("externaldrive", "Another volume, not scanned") }
            if flags.contains(.excluded) { badge("minus.circle", "Excluded from the scan") }
            if flags.contains(.hidden) { badge("eye.slash", "Hidden") }
        }
        .foregroundStyle(.secondary)
        .imageScale(.small)
    }

    private func badge(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol).help(help).accessibilityLabel(help)
    }
}
