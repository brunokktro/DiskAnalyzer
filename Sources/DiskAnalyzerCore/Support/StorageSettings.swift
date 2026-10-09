import Foundation

/// Opens a System Settings location. The app passes an `NSWorkspace` adapter; tests pass a recorder.
public protocol SettingsOpening {
    /// Whether some installed application handles `url` (`NSWorkspace.urlForApplication(toOpen:)`).
    func canOpen(_ url: URL) -> Bool
    /// `NSWorkspace.open(_:)`; returns whether the system accepted the request.
    func open(_ url: URL) -> Bool
    /// Launches the application with this bundle identifier; returns whether it was found and opened.
    func openApplication(bundleIdentifier: String) -> Bool
}

/// macOS Storage settings (General > Storage), which explains space Disk Analyzer cannot
/// attribute: system data, local snapshots, purgeable space, other APFS volumes.
///
/// The pane is opened through `NSWorkspace` with the `x-apple.systempreferences:` URL that
/// System Settings registers, using the identifier of its Storage extension
/// (`/System/Library/ExtensionKit/Extensions/Storage.appex`, `com.apple.settings.Storage`).
/// Apple does not promise that identifier, so the chain falls back to opening System
/// Settings itself and, failing that, tells the user where to go. No scripting, no UI automation.
public enum StorageSettings {
    public static let paneURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
    public static let systemSettingsBundleIdentifier = "com.apple.systempreferences"
    public static let manualInstructions = "Open System Settings, then choose General > Storage."

    public enum Outcome: Sendable, Equatable {
        /// The Storage pane was requested.
        case openedStoragePane
        /// Only System Settings could be opened; the user still has to choose General > Storage.
        case openedSystemSettings
        /// Nothing could be opened; show ``manualInstructions``.
        case failed
    }

    public static func open(using opener: some SettingsOpening) -> Outcome {
        if opener.canOpen(paneURL), opener.open(paneURL) { return .openedStoragePane }
        if opener.openApplication(bundleIdentifier: systemSettingsBundleIdentifier) { return .openedSystemSettings }
        return .failed
    }
}
