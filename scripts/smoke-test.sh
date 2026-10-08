#!/usr/bin/env bash
# Launches the packaged app against a fresh fixture tree and checks its JSON report.
# The app scans, navigates, filters, draws the treemap and runs the Collector -> Trash
# flow with a recording stand-in, so nothing is moved to the real Trash.
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
cleanup() {
  chmod 755 "$WORK/fixture/Locked" 2>/dev/null || true
  [[ "${KEEP_SMOKE:-0}" == 1 ]] && { echo "kept $WORK"; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" --product FixtureGenerator >/dev/null
"$(swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" --show-bin-path)/FixtureGenerator" "$WORK/fixture" > "$WORK/manifest.txt"
EXPECTED_LOGICAL="$(awk '/expected logical bytes/ {print $4}' "$WORK/manifest.txt")"
EXPECTED_ITEMS="$(awk '/expected counted items/ {print $4}' "$WORK/manifest.txt")"

ARGS=(--smoke-test "$WORK/fixture" --smoke-report "$WORK/report.json")
[[ -n "${SNAPSHOT:-}" ]] && ARGS+=(--smoke-snapshot "$SNAPSHOT")

set +e
"$EXE" "${ARGS[@]}" > "$WORK/app.log" 2>&1
STATUS=$?
set -e
[[ -f "$WORK/report.json" ]] || { echo "no report (exit $STATUS)"; cat "$WORK/app.log"; exit 1; }

/usr/bin/python3 - "$WORK/report.json" "$EXPECTED_LOGICAL" "$EXPECTED_ITEMS" "$STATUS" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected_logical, expected_items, status = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
facts, checks = report["facts"], dict(report["checks"])
checks["logical_total_matches_fixture"] = facts.get("logical_bytes") == expected_logical
checks["item_count_matches_fixture"] = facts.get("items") == expected_items
checks["locked_folder_reported"] = facts.get("issues", {}).get("permissionDenied") == 1
checks["app_exit_code_zero"] = status == 0
for name, ok in sorted(checks.items()):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}")
print(f"  scan: {facts.get('items')} items, {facts.get('logical_bytes')} logical bytes, {facts.get('allocated_bytes')} allocated bytes, {facts.get('treemap_tiles')} tiles")
sys.exit(0 if all(checks.values()) else 1)
PY
echo "smoke test passed"
