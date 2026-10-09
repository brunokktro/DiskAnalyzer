# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report security issues privately through GitHub's **Report a vulnerability** button
(Security > Advisories) on this repository. Do not open a public issue. Include the macOS
version, steps to reproduce, and what you expected versus what happened. You should get an
acknowledgement within a week.

## Security model

Disk Analyzer runs with your user's permissions and is **not sandboxed**, so it can read the
metadata of anything your account can list. It is designed to be safe with that access:

- **Read-only scanning.** The scanner only reads file metadata with `lstat(2)` through `fts(3)`.
  It does not open, read, hash or upload file contents. Symbolic links are never followed during
  the walk.
- **No network access.** The app makes no network requests and collects no telemetry.
- **System Settings.** *Open Storage Settings…* only asks macOS (through `NSWorkspace`) to open the
  Storage pane or System Settings. No scripting, no UI automation.
- **No permanent deletion.** The single destructive action is *Move to Trash*, through
  `FileManager.trashItem`, after an explicit confirmation. Items stay restorable from the Trash.
- **Trash guardrails.** Every item is re-checked right before it moves, and each one succeeds or
  fails on its own:
  - it must still exist with the same type (file vs. folder) and the same file identity
    (`st_dev`, `st_ino`) it had when it was collected, so a path that now names another object is
    refused;
  - it must be inside the scanned folder both as written and after resolving every symbolic link on
    its way (`realpath(3)` of its parent folder against the resolved scan root), so replacing a
    folder with an alias after the scan cannot redirect the move outside the scan;
  - it must not be the scanned folder, a mount point, the app itself, a protected system or
    account folder, or a folder that CONTAINS one of those (moving it would take the protected
    folder along: a relocated home, a release folder holding the running app). Protection is
    checked on the path as written, on the resolved path, and by file identity, so an alias or
    firmlink of a protected folder is still protected;
  - it must not be a cloud storage root or a direct child of one (`~/Library/CloudStorage` and
    its File Provider domains, `~/Library/Mobile Documents` and the iCloud Drive and app
    containers inside it), because moving such a folder removes the synced tree in the cloud
    too. Files and folders further down stay movable, as in Finder;
  - the scan must have measured it: folders the scan could not list (permissions, macOS privacy
    protection), excluded folders, other volumes, folders already counted at another path (APFS
    firmlinks) and entries with invalid name encoding are never offered for the Trash, because
    their size is unknown. A collected folder that contains such
    folders is allowed, and the confirmation says that more than the size shown will move.
- **Exact paths.** A name that is not valid UTF-8 is shown repaired, so its path may name a
  different file. Quick Look, Reveal in Finder, Copy Path, the Collector and the Trash all refuse
  such entries and anything below them.
- **Exports.** CSV exports are written only where you choose in the Save panel. Fields that a
  spreadsheet would evaluate as formulas (`=`, `+`, `-`, `@`) are prefixed with `'`.
- **Privacy protection.** Folders protected by macOS (TCC) are reported as skipped. Granting
  Full Disk Access is optional and only extends what the scan can measure.

## Saved scans

- **What is saved.** The last scan of each root (up to 10 roots): file and folder names, sizes,
  dates, the skipped-items list, the root's volume UUID and file ID, and the volume's capacity
  figures. No file contents. Nothing leaves the Mac.
- **Where.** `~/Library/Application Support/Disk Analyzer/Snapshots.sqlite`. The app creates the
  folder with mode `0700` and the file with `0600`. The file is not encrypted; FileVault protects it
  at rest like the rest of your home folder. To remove every saved scan, quit the app and move that
  folder to the Trash.
- **Restoring is checked.** A snapshot is shown only when its root is the same folder (same volume
  UUID and file ID) as when it was saved. Every saved row (identity, scope, dates, list figures,
  details and tree) is verified against one SHA-256 checksum, so accidental damage anywhere in the
  row keeps it from being restored. The checksum is not a signature: whoever edits the file can
  recompute it. What keeps an edited file from crashing the app is validation before use: the tree's
  whole parent/child structure, every size and count in range (0 to 2^56 bytes), no folder smaller
  than the counted entries inside it, plausible dates, durations and volume figures, and byte
  arithmetic that reports an overflow instead of trapping. A row that fails any check is not
  restored and stays on disk; the list shows only rows whose list figures are in range. A file whose
  tables are not the ones this version uses is moved aside like a damaged one.
- **Damaged files are never deleted.** A file that SQLite cannot read, that fails its integrity
  check, that another program created, whose tables are missing or different, or whose format cannot
  be upgraded is renamed next to the original (`Snapshots.unreadable-<date>.sqlite`) and the user is
  told. Readable snapshots are copied out of it first. A file written by a newer version is left
  untouched and saving is turned off.
- **Restored results and the Trash.** Collecting and moving to the Trash work on restored results
  with the same per-item checks as on fresh ones (identity at collection time, containment, protected
  locations). A file that no longer has the type, size or modification date the scan recorded (a
  file replaced at the same path since a saved scan, for example) cannot be collected, so it cannot
  be moved to the Trash from those results; rescan its folder first. The confirmation says when the
  results were restored or the volume changed since the scan, because sizes may differ from what is
  shown.

## Things that are out of scope

- A race inside the final instant between the last validation and `FileManager.trashItem`, if
  another process swaps a path component exactly then. Changes made at any earlier moment in the
  session are caught by the checks above. The move is still a Trash move, never a deletion.
- Exact reclaimed-space accounting on APFS (clones, snapshots, purgeable space).
