import Foundation

/// Byte arithmetic on figures that may come from a saved file or the file system. Nothing
/// here traps: an overflow gives `nil` (the figure is shown as not reported) or saturates.
enum SafeArithmetic {
    /// `a - b`, or `nil` if it does not fit in `Int64`.
    static func difference(_ a: Int64, _ b: Int64) -> Int64? {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? nil : value
    }

    /// `a + b`, clamped to the `Int64` range.
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : value
    }
}
