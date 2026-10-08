import AppKit
import DiskAnalyzerCore
import SwiftUI

@main
struct DiskAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Disk Analyzer", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: delegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let smoke = SmokeTest.parse(CommandLine.arguments)
    lazy var model = AppModel(
        defaults: smoke == nil ? .standard : UserDefaults(suiteName: "DiskAnalyzer.SmokeTest") ?? .standard,
        trashMover: smoke == nil ? SystemTrashMover() : RecordingTrashMover()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`); harmless inside the bundle.
        NSApp.setActivationPolicy(.regular)
        if smoke != nil {
            // Publication screenshots must be deterministic and readable regardless of the
            // developer's system appearance. Normal launches continue following macOS.
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        NSApp.activate()
        if let smoke { Task { await smoke.run(model: model) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelScan()
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan Home Folder") { model.scanHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Scan Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Divider()
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.scanRoot == nil || model.isScanning)
            Button("Stop Scan") { model.cancelScan() }
                .keyboardShortcut(".")
                .disabled(!model.isScanning)
            Button("Close Scan") { model.closeScan() }
                .disabled(model.tree == nil)
            Divider()
            Toggle("Stay on One Volume", isOn: Binding(get: { model.staysOnVolume }, set: { model.staysOnVolume = $0 }))
                .help("Do not enter other volumes mounted inside the scanned folder. Applies to the next scan.")
        }
        CommandGroup(after: .importExport) {
            Button("Export Largest Items…") { model.exportLargest() }
                .disabled(model.tree == nil)
            Button("Export Skipped Items…") { model.exportIssues() }
                .disabled(model.lastResult == nil)
        }
        CommandMenu("Go") {
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!model.canGoUp)
            Button("Open Selection") { model.activateSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(model.listSelection.count != 1)
            Divider()
            Button("Quick Look") { model.quickLookSelection() }
                .keyboardShortcut("y")
                .disabled(model.listSelection.isEmpty)
            Button("Reveal in Finder") { model.reveal(model.listSelection) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.listSelection.isEmpty)
            Button("Add to Collector") { model.collect(model.listSelection) }
                .keyboardShortcut("k")
                .disabled(!model.listSelection.contains(where: model.canCollect))
        }
        CommandGroup(after: .sidebar) {
            Button(model.isCollectorPresented ? "Hide Collector" : "Show Collector") { model.isCollectorPresented.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Show Skipped Items") { model.isIssuesPresented = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.lastResult == nil)
            Divider()
            Button("Explore") { model.mode = .explore }
                .keyboardShortcut("1")
            Button("Largest Items") { model.mode = .largest }
                .keyboardShortcut("2")
        }
    }
}
