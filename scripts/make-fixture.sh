#!/usr/bin/env bash
# Writes the deterministic fixture tree to a folder for manual testing in the app.
#
#   scripts/make-fixture.sh <empty-or-new-folder> [--no-locked] [--scale N] [--bulk FOLDERS FILES]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 1 ]] || { sed -n '2,4p' "$0"; exit 64; }
exec swift run --package-path "$ROOT" --scratch-path "${BUILD_PATH:-$ROOT/.build}" FixtureGenerator "$@"
