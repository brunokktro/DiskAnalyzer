#!/usr/bin/env bash
# Runs the unit and integration tests. Extra arguments go to `swift test`
# (for example: scripts/test.sh --filter Treemap).
#
# With the Swift 6.4 Command Line Tools, `swift test` intermittently fails with
# "plugin for module 'TestingMacros' not found" because the compiler is not always
# given the Swift Testing macro plugin. Passing the toolchain's plugin directory
# explicitly makes it reliable; toolchains that lay plugins out differently
# (full Xcode) skip the flag and work as usual.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
EXTRA=()
if [[ -f "$PLUGIN_DIR/libTestingMacros.dylib" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
exec swift test --package-path "$ROOT" --scratch-path "${BUILD_PATH:-$ROOT/.build}" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
