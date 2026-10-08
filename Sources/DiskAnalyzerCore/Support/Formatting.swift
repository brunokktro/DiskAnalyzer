import Foundation

public enum SizeFormatting {
    /// Decimal units (1 KB = 1000 bytes), the convention Finder uses for file sizes.
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "-" }
        let value = Double(part) / Double(whole) * 100
        if value > 0 && value < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", value)
    }

    public static func count(_ value: Int64) -> String {
        value.formatted(.number)
    }
}

/// RFC 4180 CSV rendering for exporting lists. Fields with separators, quotes or line
/// breaks are quoted; a leading `=`, `+`, `-` or `@` is prefixed with `'` so spreadsheet
/// apps do not evaluate a crafted file name as a formula.
public enum CSVExport {
    public static func field(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func render(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func issues(_ issues: [ScanIssue]) -> String {
        render(header: ["kind", "path", "errno", "message"],
               rows: issues.map { [$0.kind.rawValue, $0.path, String($0.errorCode), $0.message] })
    }

    public static func items(_ ids: [NodeID], in tree: FileTree) -> String {
        render(header: ["path", "allocated_bytes", "logical_bytes", "items", "modified"],
               rows: ids.map { id in
                   let node = tree[id]
                   return [tree.path(of: id), String(node.allocatedSize), String(node.logicalSize), String(node.itemCount),
                           ISO8601DateFormatter().string(from: node.modificationDate)]
               })
    }
}
