# Disk Analyzer

A native macOS app that shows what takes up space on a disk. Pick your home folder, the
data volume or any folder; Disk Analyzer walks it in the background, then lets you explore
the result as a sortable hierarchy and a squarified treemap, list the largest items, filter,
preview with Quick Look, reveal in Finder and, if you choose to, move items to the Trash.

- **Metadata only.** The scan reads `lstat(2)` information and never opens file contents.
- **Nothing is deleted permanently.** The only destructive action is an explicit,
  confirmed **Move to Trash**, which you can undo from the Trash.
- **Honest numbers.** Both *allocated* and *logical* sizes are shown, hard links are counted
  once, and everything the scan could not read is listed instead of silently ignored.
- **Zero third-party dependencies.** Swift, SwiftUI, AppKit and Foundation only.

Requires macOS 14 Sonoma or later. Apple silicon and Intel (`--universal` build).

## Screenshots

### Explore and treemap

![Disk Analyzer showing a folder hierarchy and squarified treemap](docs/screenshots/explore.png)

### Largest items

![Disk Analyzer listing the largest files and packages](docs/screenshots/largest-items.png)

### Collector

![Disk Analyzer Collector reviewing an item before moving it to the Trash](docs/screenshots/collector.png)

## Features

| Area | What you get |
|------|--------------|
| Scan roots | Home folder, any mounted volume (the system volume maps to its Data volume), or any folder via the Open panel |
| Scanning | Asynchronous, cancellable at any time (⌘.), live progress, stays on one volume by default like `du -x` (File > Stay on One Volume) |
| Sizes | **Allocated** (`st_blocks × 512`) and **Logical** (`st_size`), switchable everywhere |
| Hierarchy | Folder listing with share bars, sortable columns, breadcrumb navigation, ⌘↑ / ⌘↓ |
| Treemap | Squarified layout, three nested levels, hover details, click to select, double-click to drill down; small items grouped into one tile; hard-link duplicates get no area |
| Largest items | Top 500 files and packages below the current folder, with their location; CSV export |
| Filters | Name (case- and accent-insensitive), minimum size, modification age, kind, hidden items; folders stay visible when something inside matches |
| Finder | Quick Look (Space or ⌘Y), Reveal in Finder (⌥⌘R), Copy Path |
| Collector | Stage items for review (⌘K). Overlapping selections are merged and a hard-linked file is counted once, so nothing counts twice. Folders the scan could not measure are not accepted. Kept across a rescan of the same folder |
| Trash | Confirmation dialog, every item re-validated on disk right before it moves (same object, still inside the scanned folder after resolving aliases; protected system and account folders, folders that contain one, and cloud storage roots refused, also through aliases), per-item results; disabled while scanning |
| Skipped items | Permission-denied, privacy-protected, unreadable and other-volume folders, with counts, reasons, CSV export and a shortcut to Privacy & Security settings |

## Install from source

You need the Xcode **Command Line Tools** with Swift 6 or later (`xcode-select --install`).
A full Xcode install also works; nothing here requires it.

```bash
git clone https://github.com/brunokktro/DiskAnalyzer.git
cd DiskAnalyzer
scripts/package-app.sh            # builds dist/Disk Analyzer.app (add --universal for arm64 + x86_64)
open "dist/Disk Analyzer.app"
```

The bundle is ad-hoc signed. Because it is not notarized, a copy downloaded from the internet
is blocked by Gatekeeper; open it with right-click > Open, or build it yourself as above.
To sign with your own identity: `SIGN_IDENTITY="Developer ID Application: …" scripts/package-app.sh`.

## Using it

1. Choose **Scan Home Folder**, a volume in the sidebar, or **Choose Folder…** (⌘O).
2. Explore: double-click folders or treemap tiles to go deeper, use the breadcrumb or ⌘↑ to go back.
3. Switch **Allocated / Logical** in the toolbar, or open **Largest Items** (⌘2).
4. Right-click anything for Quick Look, Reveal in Finder or **Add to Collector**.
5. Open the Collector (⌥⌘C), review, then **Move to Trash…** and confirm.

### Full Disk Access

macOS privacy protection (TCC) hides some folders, such as Mail, Messages and Safari data,
from apps that do not have **Full Disk Access**. Disk Analyzer reports those folders as
*Blocked by macOS privacy protection* and shows the count in the status bar. If you want them
measured, add the app in **System Settings > Privacy & Security > Full Disk Access** and rescan.
The app works without it.

## What the numbers mean

**Allocated** is what the file system reports as in use for each file (`st_blocks × 512`,
see `man 2 stat`). It is the best available estimate of the space a file occupies, and the
default ranking. **Logical** is the size of the content (`st_size`), what Finder lists as
"size". A sparse disk image can be gigabytes logically and a few kilobytes allocated.

Neither number is the exact space you get back by deleting something on APFS:

- **Clones** (Finder duplicates, `cp -c`) share blocks; each copy reports the full allocation.
- **Snapshots** (Time Machine local snapshots, system updates) keep deleted blocks alive.
- **Hard links** keep data on disk while another link exists. The scanner and the Collector
  count an inode once, and the Collector warns about hard-linked files.
- **Firmlinks.** On the startup disk, `/Users`, `/Applications` and other folders are firmlinks
  to the same folders on the Data volume. Choosing the startup disk scans its Data volume, and
  any folder reached a second time through another path is counted once and listed as
  *Already counted at another path*.
- **Purgeable** space and file-system compression are not visible per file.

Disk Analyzer therefore labels freed space as approximate and never claims APFS physical
reclaim precision. The totals agree with `du -k -x` on the same folder, which is how the tests
cross-check them. Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#size-semantics).

## Development

```bash
scripts/test.sh                   # 108 unit and integration tests (Swift Testing)
scripts/package-app.sh            # release build + .app bundle
scripts/smoke-test.sh             # launches the packaged app against a fixture and checks its report
scripts/make-fixture.sh /tmp/da   # writes the test fixture tree for manual exploration
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout and conventions, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the scanner, the tree and the UI fit together.

## Known limitations

- Very large scans hold the whole tree in memory: about 470,000 entries use ~265 MB including
  the UI. Tens of millions of entries need several GB.
- Results are a snapshot. Changes after the scan are not tracked; rescan with ⌘R.
- File kinds come from file extensions, not content inspection.
- Not sandboxed, so it can scan the home folder and volumes without asking per folder.
  This also means it is not distributable through the Mac App Store as is.
- English UI only for now.

## License

[MIT](LICENSE)
