# Contributing

Thanks for helping. Bug reports, fixes and focused features are welcome.

## Setup

- macOS 14 or later.
- Swift 6 toolchain: the Xcode Command Line Tools are enough (`xcode-select --install`).
- No third-party packages. Please keep it that way; open an issue first if you think one is needed.

```bash
scripts/test.sh          # run the tests
scripts/package-app.sh   # build dist/Disk Analyzer.app
scripts/smoke-test.sh    # launch the packaged app against a fixture and verify its report
```

`swift run DiskAnalyzer` also starts the app without a bundle (no icon).

## Layout

```
Sources/
  DiskAnalyzerCore/      all logic, no UI imports except Foundation
    Models/              FileTree, FileNode, PathUtilities, subtree replacement
    Scanning/            DiskScanner (fts), ScanTypes
    Persistence/         SnapshotStore (SQLite), TreeCodec, RootIdentity, VolumeBaseline
    Reconciliation/      SpaceReconciliation, freshness policy, scan labels
    Query/               filters, biggest folders/files, Trash discovery, categories
    Treemap/             squarified layout and hit testing
    Collector/           staging area for the Trash
    Trash/               TrashPolicy, TrashOperation, TrashMover
    Volumes/             VolumeLocator
    Support/             size formatting, CSV export, Storage Settings opener
  DiskAnalyzer/          SwiftUI app (App/, Views/)
  DiskAnalyzerFixtures/  deterministic fixture tree
  FixtureGenerator/      CLI around the fixture
  IconGenerator/         renders the app icon
Tests/DiskAnalyzerCoreTests/
Packaging/Info.plist     bundle template (@VERSION@, @BUILD@, @BUNDLE_ID@)
scripts/                 test, package, smoke test, fixture
docs/ARCHITECTURE.md
```

## Rules that keep the project safe

1. **The scanner is metadata-only.** Never open, read or hash file contents in
   `DiskAnalyzerCore`. Quick Look is the only feature that reads contents, and it runs on demand
   in a system process. Local-only scans must keep the dataless materialization policy off and
   must never descend into a node marked `SF_DATALESS`.
2. **No permanent deletion.** The only removal path is `TrashOperation` through `TrashPolicy`
   and `FileManager.trashItem`. Do not add `removeItem`, `unlink` or similar on user data.
3. **Tests never touch the real Trash, the real saved scans or System Settings.** Use
   `RecordingMover` (tests) or `RecordingTrashMover` (smoke test), a `TemporaryStore` or
   `--smoke-store`, and a recording `SettingsOpening`.
4. **No machine-specific data.** No hardcoded user names, home paths or volume names. Resolve at
   runtime (`homeDirectoryForCurrentUser`, `statfs`, `mountedVolumeURLs`).
5. **Do not over-claim sizes.** Allocated size is an estimate of reclaimable space on APFS;
   UI text must not promise exact freed space. A folder scan is never compared with the volume's
   used space, and reconciliation buckets are never clamped to make numbers agree.
6. **Information is never color-only.** Pair colors with a symbol, a label, a pattern or a border.
7. **Saved data is never deleted to recover.** A damaged or unknown database is moved aside. Bump
   `SnapshotSchema.version` with an upgrade step for every schema change, and
   `TreeCodec.formatVersion` for every tree layout change.
8. **Nothing scans on its own.** Launch restores saved results. Home, volumes and chosen roots
   open an existing snapshot when one exists; otherwise they show a scan plan. A full scan starts
   only after the user reviews its time range and cloud mode and confirms **Start Scan**.

## Toolchain notes

- **No `@State`, `#Preview` or other SwiftUI macros.** In the macOS 27 SDK `@State` is
  implemented as a macro whose plugin (`SwiftUIMacros`) does not ship with the Command Line
  Tools, so any use breaks the CLT build. Keep view state in `@Observable` models and pass them
  with `@Bindable`. `@Observable` itself is fine (its plugin ships with the CLT).
- **Avoid ternaries between key-path literals** (`a ? \T.x : \T.y`) inside view builders: the
  Swift 6.4 type checker crashes with "failed to produce diagnostic". Use a `switch` (see
  `SizeMetric.rowKeyPath`). Prefer typed `@TableColumnBuilder` helpers for `Table` columns.
- **Run tests through `scripts/test.sh`.** With the 6.4 CLT, plain `swift test` intermittently
  fails with "plugin for module 'TestingMacros' not found" (the compiler is not always handed the
  Swift Testing macro plugin). The script passes the toolchain's plugin directory with
  `-Xswiftc -plugin-path`, which removed the failure in repeated build/test cycles.

## Tests

- Swift Testing (`import Testing`), one suite per area.
- File system tests build the fixture in a unique folder under `TMPDIR` and remove it afterwards
  (`TemporaryFixture`). They cross-check sizes against `lstat(2)` and `du(1)`, never against
  hardcoded allocation numbers, because allocation depends on the file system.
- Logic tests use `makeTree(_:)` to build trees in memory.
- Add a test with every behavior change. A fix comes with a test that fails without it.

## Smoke-test mode

The app accepts `--smoke-test <folder> --smoke-report <file.json> [--smoke-store <db>] [--smoke-snapshot <file.png>]`.
It scans the folder through the real `AppModel`, exercises navigation, filters, the treemap,
Biggest Folders, Biggest Files, explicit Trash sizing and navigation, the Collector-to-Trash flow
with a recording mover (nothing is moved), saving, Rescan This Folder (finished and cancelled) and
Storage Settings with a recording opener, writes the report and exits with 0 on success, 1 on a
failed check, 2 on timeout. `--smoke-restore <first-report.json> --smoke-report <file.json> --smoke-store <db>`
relaunches on the same saved-scans file and checks the restored totals,
 that Home-style navigation opens the
snapshot without scanning, and that no scan started. When `SNAPSHOT` is set, the harness requires
seven opaque PNGs: six 1280×800 app views plus the scan-plan sheet. `scripts/smoke-test.sh` runs both phases.

## Pull requests

- One topic per PR, with a short description of the user-visible change.
- `scripts/test.sh`, `scripts/package-app.sh` and `scripts/smoke-test.sh` pass locally.
- Update `CHANGELOG.md` under *Unreleased*, and the README or architecture doc when behavior changes.
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`fix(scanner): …`).
