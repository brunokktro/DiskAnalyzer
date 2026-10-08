// swift-tools-version: 6.0
//
// DiskAnalyzer is built with Swift Package Manager only, so it works with the
// Command Line Tools as well as a full Xcode install. See CONTRIBUTING.md for
// the SwiftUI macro restriction that keeps the CLT build working.

import PackageDescription

let package = Package(
    name: "DiskAnalyzer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskAnalyzer", targets: ["DiskAnalyzer"]),
        .executable(name: "FixtureGenerator", targets: ["FixtureGenerator"]),
        .executable(name: "IconGenerator", targets: ["IconGenerator"]),
        .library(name: "DiskAnalyzerCore", targets: ["DiskAnalyzerCore"]),
    ],
    targets: [
        // Pure logic: scanning, tree model, queries, treemap layout, collector, trash policy.
        .target(name: "DiskAnalyzerCore"),

        // Deterministic on-disk fixture trees, shared by tests and the generator CLI.
        .target(name: "DiskAnalyzerFixtures"),

        // The SwiftUI application.
        .executableTarget(name: "DiskAnalyzer", dependencies: ["DiskAnalyzerCore"]),

        // Developer tool: writes a fixture tree to a directory for manual testing.
        .executableTarget(name: "FixtureGenerator", dependencies: ["DiskAnalyzerFixtures"]),

        // Build tool: renders the app icon from code (no binary assets in the repo).
        .executableTarget(name: "IconGenerator", dependencies: ["DiskAnalyzerCore"]),

        .testTarget(
            name: "DiskAnalyzerCoreTests",
            dependencies: ["DiskAnalyzerCore", "DiskAnalyzerFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
