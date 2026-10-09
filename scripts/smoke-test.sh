#!/usr/bin/env bash
# Launches the packaged app against a fresh fixture tree and checks its JSON report.
# The app scans, navigates, filters, draws the treemap and runs the Collector -> Trash
# flow with a recording stand-in, so nothing is moved to the real Trash. It also saves the
# scan, rescans a folder (finished and cancelled) and asks for Storage Settings through a
# recording stand-in. Then the app is launched a second time on the same saved-scans file
# and must show the saved results without starting any scan.
#
#   scripts/smoke-test.sh [path/to/Disk Analyzer.app]
#
# Fixture and report live in a mktemp folder under $TMPDIR and are removed on exit,
# unless KEEP_SMOKE=1. Set SNAPSHOT=path.png to keep a capture of the window.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${BUILD_PATH:-$ROOT/.build}"
APP="${1:-$ROOT/dist/Disk Analyzer.app}"
EXE="$APP/Contents/MacOS/DiskAnalyzer"
[[ -x "$EXE" ]] || { echo "app not found at $APP; run scripts/package-app.sh first" >&2; exit 66; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-analyzer-smoke.XXXXXX")"
# The app keeps its own settings in a separate suite during the smoke test, but AppKit still
# autosaves window and split-view frames to the app's defaults domain. Export that domain
# first and put it back on exit, so the developer's preferences end exactly as they were.
# `defaults import` merges, so keys the run added are removed first, one by one.
DOMAIN="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
defaults export "$DOMAIN" "$WORK/defaults-before.plist"
restore_defaults() {
  defaults export "$DOMAIN" "$WORK/defaults-after.plist" || return 1
  /usr/bin/python3 - "$WORK/defaults-before.plist" "$WORK/defaults-after.plist" <<'PY' |
import plistlib, sys
before, after = (plistlib.load(open(path, "rb")) for path in sys.argv[1:3])
print("\n".join(sorted(set(after) - set(before))))
PY
  while IFS= read -r key; do [[ -n "$key" ]] && defaults delete "$DOMAIN" "$key"; done
  defaults import "$DOMAIN" "$WORK/defaults-before.plist"
}
cleanup() {
  chmod 755 "$WORK/fixture/Locked" 2>/dev/null || true
  restore_defaults || echo "warning: could not restore the defaults of $DOMAIN" >&2
  [[ "${KEEP_SMOKE:-0}" == 1 ]] && { echo "kept $WORK"; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" --product FixtureGenerator >/dev/null
"$(swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" --show-bin-path)/FixtureGenerator" "$WORK/fixture" > "$WORK/manifest.txt"
EXPECTED_LOGICAL="$(awk '/expected logical bytes/ {print $4}' "$WORK/manifest.txt")"
EXPECTED_ITEMS="$(awk '/expected counted items/ {print $4}' "$WORK/manifest.txt")"

ARGS=(--smoke-test "$WORK/fixture" --smoke-report "$WORK/report.json" --smoke-store "$WORK/store/Snapshots.sqlite")
if [[ -n "${SNAPSHOT:-}" ]]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  ARGS+=(--smoke-snapshot "$SNAPSHOT")
fi

set +e
"$EXE" "${ARGS[@]}" > "$WORK/app.log" 2>&1
STATUS=$?
set -e
[[ -f "$WORK/report.json" ]] || { echo "no report (exit $STATUS)"; cat "$WORK/app.log"; exit 1; }

# Relaunch on the same saved-scans file: restore only, never a scan.
RESTORE_ARGS=(--smoke-restore "$WORK/report.json" --smoke-report "$WORK/restore.json" --smoke-store "$WORK/store/Snapshots.sqlite")
[[ -n "${SNAPSHOT:-}" ]] && RESTORE_ARGS+=(--smoke-snapshot "$SNAPSHOT")
set +e
"$EXE" "${RESTORE_ARGS[@]}" > "$WORK/restore.log" 2>&1
RESTORE_STATUS=$?
set -e
[[ -f "$WORK/restore.json" ]] || { echo "no restore report (exit $RESTORE_STATUS)"; cat "$WORK/restore.log"; exit 1; }

/usr/bin/python3 - "$WORK/report.json" "$EXPECTED_LOGICAL" "$EXPECTED_ITEMS" "$STATUS" "$WORK/restore.json" "$RESTORE_STATUS" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected_logical, expected_items, status = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
restore, restore_status = json.load(open(sys.argv[5])), int(sys.argv[6])
facts, checks = report["facts"], dict(report["checks"])
checks["logical_total_matches_fixture"] = facts.get("logical_bytes") == expected_logical
checks["item_count_matches_fixture"] = facts.get("items") == expected_items
checks["locked_folder_reported"] = facts.get("issues", {}).get("permissionDenied") == 1
checks["app_exit_code_zero"] = status == 0
checks.update({f"relaunch_{name}": ok for name, ok in restore["checks"].items()})
checks["relaunch_exit_code_zero"] = restore_status == 0
for name, ok in sorted(checks.items()):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}")
print(f"  scan: {facts.get('items')} items, {facts.get('logical_bytes')} logical bytes, {facts.get('allocated_bytes')} allocated bytes, {facts.get('treemap_tiles')} tiles")
print(f"  relaunch: restored {restore['facts'].get('root_path')}, scans started {restore['facts'].get('scan_start_count')}, labels {restore['facts'].get('scan_labels')}")
sys.exit(0 if all(checks.values()) else 1)
PY
if [[ -n "${SNAPSHOT:-}" ]]; then
  BASE="${SNAPSHOT%.*}"
  for view in explore folders files trash collector restored; do
    image="$BASE-$view.png"
    [[ -s "$image" ]] || { echo "missing smoke screenshot: $image" >&2; exit 1; }
    dimensions="$(sips -g pixelWidth -g pixelHeight "$image" 2>/dev/null)"
    grep -q 'pixelWidth: 1280' <<<"$dimensions" || { echo "unexpected screenshot width: $image" >&2; exit 1; }
    grep -q 'pixelHeight: 800' <<<"$dimensions" || { echo "unexpected screenshot height: $image" >&2; exit 1; }
    alpha="$(sips -g hasAlpha "$image" 2>/dev/null)"
    grep -q 'hasAlpha: no' <<<"$alpha" || { echo "screenshot is not opaque: $image" >&2; exit 1; }
  done
fi
echo "smoke test passed"
