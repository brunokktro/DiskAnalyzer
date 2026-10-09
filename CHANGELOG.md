# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

## 0.3.0 - 2026-10-09

### Added

- A blocking **Plan Full Scan** decision before every new root scan and **Rescan All**. It shows
  the root, exact time and relative age of the previous scan, estimated scope and a broad duration
  range. A previous scan calibrates the range; a first scan uses the volume's used space and clearly
  names item count, SSD, permissions, system load and File Provider latency as uncertainty sources.
- Two explicit cloud modes. Both apply and verify `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`, so
  regular-file contents remain dataless. **Local files only** is the default: it detects
  `SF_DATALESS`, skips dataless directories and gives dataless files zero logical and allocated
  contribution. **Include cloud catalog** permits File Provider directory enumeration and includes
  remote logical sizes while warning that provider metadata/cache usage and duration may grow.
- Cloud placeholders have their own tree flag, icon and count instead of appearing as trustworthy
  empty folders. Placeholder files do not consume the 5,000-row detailed-issue budget. The selected
  cloud mode is saved with the snapshot; pre-0.3 snapshots show **Legacy, cloud behavior unknown**.
- Thirteen cloud-mode tests, including an independent adversarial suite, cover policy
  application/restoration, real placeholder behavior, traversal decisions, estimate scaling,
  legacy snapshots, tree-format compatibility and SQLite round-trip. The complete suite now has
  230 tests; the packaged-app smoke flow has 57 checks and seven opaque screenshots, including the
  real scan-plan sheet.

### Changed

- Home and volume rows are navigation targets. They open the current or saved snapshot when one
  exists and never silently start a new scan. Without a snapshot they open the scan plan.
- Recent Scans and Current Scan show both the exact scan time and relative age. The current result
  also shows which cloud mode produced it.
- **Rescan This Folder** keeps the cloud mode of its parent snapshot. **Scan as New Root** uses the
  same explicit scan plan as other full-root scans. Every new plan starts on **Local files only**,
  even when the user selected cloud catalog for an earlier scan.
- Tree format 3 makes older releases identify 0.3 snapshots as newer while 0.3 continues reading
  format 2 snapshots from 0.2.

### Fixed

- Local-only scans no longer add remote placeholder `st_size` values to Logical totals. Dataless
  directories are skipped before descent when a provider marks them that way, and placeholder-file
  counts no longer crowd permission failures out of the detailed issue list.

## 0.2.0 - 2026-10-08

### Added

- **Biggest Folders** (⌘2): a dedicated top-500 view ranks ordinary folders by allocated or
  logical subtree size, largest first, with location, item count, drill-down and CSV export. The
  sidebar also keeps the five biggest top-level folders visible and labels folders that hold more
  than 25% or 50% of the scan, without relying on color.
- **Biggest Files** (⌘3), split from the old combined Largest Items label so folder and file
  analysis are explicit.
- Explicit **Trash sizing** for the current user's `~/.Trash` and per-volume `.Trashes/<uid>`:
  allocated and logical size, item count, Measured/Partial/Empty/Not in scan states, direct
  navigation and atomic folder rescan. A successful in-app move marks the shown Trash total as
  changed until it is rescanned.
- Product-reference documentation mapping the intentionally adopted TreeSize and Diskaroo
  capabilities and naming the features outside this release.
- Visual smoke validation now requires six opaque 1280×800 screenshots; a missing destination,
  missing screenshot, translucent PNG or wrong dimensions fails the test.

- Saved scans. The last scan of each root is saved in an SQLite database in
  `~/Library/Application Support/Disk Analyzer/` (file `0600`, folder `0700`) and, at launch, the most
  recent compatible one whose root is still the same folder is shown again. No scan starts at launch.
- Root identity: a saved root is the volume UUID plus the folder's file ID, not its path. A renamed or
  replaced folder, another volume at the same path, or a disconnected volume is never restored and is
  listed with the reason.
- Recent Scans in the sidebar (up to 10 roots), with size, date and availability.
- **Rescan This Folder** (⇧⌘R, context menu): rescans one folder and replaces its subtree only when
  that scan finishes. Cancelling or a failure keeps the previous results, on screen and saved. A
  file hard-linked inside and outside the folder stays counted once, also when the counted link was
  inside the folder and was deleted; for that the scanner records the inode of every multiply-linked
  file, and a link deleted outside the folder never makes the rescan count its inode twice. The full
  scan's baselines are kept, so freshness compares the volume with the full scan plus what the folder
  rescans measured and still sees changes elsewhere.
- **Scan as New Root** (context menu, File menu): a full scan rooted at the chosen folder.
- **Rescan All** (⌘R, renamed from Rescan). Only ever started by the user.
- Volume baselines (capacity, available, available for important use) at the start and end of every
  scan and when the results are shown.
- Space Reconciliation (⌥⌘S): file system used, available, purgeable estimate, measured allocation,
  unreadable and skipped counts, space not attributed or shared, measured allocation beyond used space
  (shown, never clamped), and the change during and since the scan. After folder rescans the buckets
  are computed against the used space the results account for (end of scan plus what the rescans
  measured), shown with both parts, so a rescanned folder's own change is never reported as
  unattributed or as measured beyond used.
- Labels: Complete, Partial, Whole volume, Folder only, Changed since scan, Stale, Restored. A folder
  scan is never compared with the volume's used space.
- Open Storage Settings… (General > Storage), through `NSWorkspace`, with a fallback to System Settings
  and then to written instructions.
- Database schema versioning with in-place upgrades in one transaction, and the expected tables and
  columns checked at every open. A damaged file, or one whose tables are missing or different, is
  moved aside, never deleted, and every snapshot that passes its checks is copied into a new file; a
  file from a newer version is left untouched and saving is turned off for the session.
- One SHA-256 checksum per saved row (identity, details and tree), plus range checks on every saved
  size, count, date and volume figure and overflow-checked reconciliation arithmetic, so a damaged or
  edited file is skipped instead of crashing the app at launch.
- The Collector refuses a file that changed since the scan (other type, size or modification date),
  so a file replaced at the same path since a saved scan cannot be moved to the Trash from it.
- 217 tests (109 new: codec, store, damaged and edited files, root identity on real disk images,
  subtree replacement, hard links across a rescanned folder, atomicity against the saved file,
  reconciliation invariants and freshness after folder rescans, labels, Storage Settings, biggest
  folder ranking and Trash discovery). The smoke test now relaunches the app, checks the restored
  results and that no scan started, validates Biggest Folders and Trash sizing, and requires six
  opaque screenshots.

### Fixed

- Scanning the startup disk ("Macintosh HD" in the Open panel) no longer counts the Data volume
  twice. The scan starts on the Data volume, as the sidebar already did, and the scanner counts
  any folder reached through a second path (APFS firmlinks, hard-linked folders) once.
- The Trash refuses a folder that contains a protected folder, not only the protected folder
  itself, on the path as written and on the resolved path.
- `CFBundleVersion` is now monotonic (MAJOR×10000 + MINOR×100 + PATCH) instead of the version
  without dots, which collided (0.1.10 and 0.11.0).
- Quick Look, Reveal in Finder and Copy Path are disabled for entries whose name is not valid
  UTF-8, because the repaired path may name a different file.

### Changed

- Also protected from the Trash: `~/Pictures`, `~/Music`, `~/Movies`, `~/Public`,
  `~/Library/CloudStorage`, `~/Library/Mobile Documents`, and every direct child of the two cloud
  roots (File Provider domains, iCloud Drive and app containers). Their contents stay movable.

## 0.1.0 - 2026-10-08

### Added

- SwiftUI app for macOS 14+, built with Swift Package Manager and the Command Line Tools.
- Scan roots: home folder, mounted volumes (system volume mapped to its Data volume) and any
  folder through the Open panel.
- Metadata-only scanner on `fts(3)`/`lstat(2)`: asynchronous, cancellable, live progress,
  stays on one volume, never follows symbolic links, counts hard links once.
- Allocated (`st_blocks × 512`) and logical (`st_size`) sizes, switchable everywhere.
- Hierarchy view with share bars, sortable columns and breadcrumb navigation.
- Squarified treemap with three nested levels, hover details, selection shared with the list,
  double-click drill-down and grouping of small items. Hard-link duplicates get no area.
- Largest Items view (top 500 files and packages) with CSV export.
- Filters by name, minimum size, modification age, kind and hidden items.
- Quick Look, Reveal in Finder and Copy Path.
- Collector with non-overlapping staging, totals that count each inode once, hard-link and
  unmeasured-folder warnings, and items kept across a rescan of the same folder.
- Move to Trash with confirmation and per-item re-validation right before the move: same file
  identity as when collected, still inside the scanned folder after resolving symbolic links
  (`realpath(3)`), protected locations refused also through aliases and firmlinks, folders the
  scan could not measure refused. Disabled while a scan runs. No permanent deletion anywhere.
- Skipped-items report (permission denied, privacy protection, unreadable, other volumes,
  exclusions) with CSV export and a shortcut to Privacy & Security settings.
- App icon rendered from code; deterministic packaging script with ad-hoc signing.
- Fixture generator, 108 unit and integration tests (including an adversarial review suite
  checked against `du(1)` and `FileManager`), and an end-to-end smoke-test mode.
