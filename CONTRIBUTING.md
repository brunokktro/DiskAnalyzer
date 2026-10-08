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
    Models/              FileTree, FileNode, PathUtilities
    Scanning/            DiskScanner (fts), ScanTypes
    Query/               filters, largest items, categories
    Treemap/             squarified layout and hit testing
    Collector/           staging area for the Trash
    Trash/               TrashPolicy, TrashOperation, TrashMover
    Volumes/             VolumeLocator
    Support/             size formatting, CSV export
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
   in a system process.
2. **No permanent deletion.** The only removal path is `TrashOperation` through `TrashPolicy`
   and `FileManager.trashItem`. Do not add `removeItem`, `unlink` or similar on user data.
3. **Tests never touch the real Trash.** Use `RecordingMover` (tests) or `RecordingTrashMover`
   (smoke test).
4. **No machine-specific data.** No hardcoded user names, home paths or volume names. Resolve at
   runtime (`homeDirectoryForCurrentUser`, `statfs`, `mountedVolumeURLs`).
5. **Do not over-claim sizes.** Allocated size is an estimate of reclaimable space on APFS;
   UI text must not promise exact freed space.
6. **Information is never color-only.** Pair colors with a symbol, a label, a pattern or a border.

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

The app accepts `--smoke-test <folder> --smoke-report <file.json> [--smoke-snapshot <file.png>]`.
It scans the folder through the real `AppModel`, exercises navigation, filters, the treemap and
the Collector-to-Trash flow with a recording mover (nothing is moved), writes the report and
exits with 0 on success, 1 on a failed check, 2 on timeout. `scripts/smoke-test.sh` wraps it.

## Pull requests

- One topic per PR, with a short description of the user-visible change.
- `scripts/test.sh`, `scripts/package-app.sh` and `scripts/smoke-test.sh` pass locally.
- Update `CHANGELOG.md` under *Unreleased*, and the README or architecture doc when behavior changes.
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`fix(scanner): …`).
