# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

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
