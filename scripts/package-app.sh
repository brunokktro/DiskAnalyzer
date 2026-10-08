#!/usr/bin/env bash
# Builds "Disk Analyzer.app" from the Swift package. Needs only the Command Line Tools.
#
#   scripts/package-app.sh [--universal] [--output DIR]
#   scripts/package-app.sh --print-build-number    prints CFBundleVersion and exits
#
# Environment:
#   BUILD_PATH       SwiftPM scratch directory   (default: <repo>/.build)
#   BUNDLE_ID        CFBundleIdentifier          (default: org.diskanalyzer.DiskAnalyzer)
#   SOURCE_DATE_EPOCH  timestamp applied to every bundle file (default: 2024-01-01T00:00:00Z),
#                    so two packages of the same sources differ only where the toolchain does.
#   SIGN_IDENTITY    codesign identity           (default: "-", ad-hoc)
#   APP_VERSION      overrides the VERSION file  (used by the tests of --print-build-number)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${BUILD_PATH:-$ROOT/.build}"
OUTPUT="$ROOT/dist"
UNIVERSAL=0
PRINT_BUILD_NUMBER=0
BUNDLE_ID="${BUNDLE_ID:-org.diskanalyzer.DiskAnalyzer}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --output) OUTPUT="$2"; shift ;;
    --print-build-number) PRINT_BUILD_NUMBER=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "VERSION must be MAJOR.MINOR.PATCH, got '$VERSION'" >&2; exit 65; }
# CFBundleVersion must grow with every release. MAJOR*10000 + MINOR*100 + PATCH is monotonic
# as long as MINOR and PATCH stay below 100 (0.1.10 -> 110, 0.11.0 -> 1100), so that is enforced.
MAJOR=$((10#${BASH_REMATCH[1]})); MINOR=$((10#${BASH_REMATCH[2]})); PATCH=$((10#${BASH_REMATCH[3]}))
(( MINOR < 100 && PATCH < 100 )) || { echo "MINOR and PATCH must be below 100, got '$VERSION'" >&2; exit 65; }
BUILD_NUMBER=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))
if [[ $PRINT_BUILD_NUMBER -eq 1 ]]; then echo "$BUILD_NUMBER"; exit 0; fi
APP="$OUTPUT/Disk Analyzer.app"
WORK="$BUILD_PATH/package-work"

step() { printf '\n==> %s\n' "$*"; }

ARCH_FLAGS=()
if [[ $UNIVERSAL -eq 1 ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

step "Building release products ($( [[ $UNIVERSAL -eq 1 ]] && echo universal || uname -m ))"
swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product DiskAnalyzer
swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" -c release --product IconGenerator
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
ICON_BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$BUILD_PATH" -c release --show-bin-path)"
[[ -x "$BIN_DIR/DiskAnalyzer" ]] || { echo "missing binary: $BIN_DIR/DiskAnalyzer" >&2; exit 1; }

step "Rendering the app icon"
rm -rf "$WORK"
mkdir -p "$WORK"
"$ICON_BIN_DIR/IconGenerator" "$WORK/AppIcon.iconset"
iconutil --convert icns --output "$WORK/AppIcon.icns" "$WORK/AppIcon.iconset"

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskAnalyzer" "$APP/Contents/MacOS/DiskAnalyzer"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
  "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Fixed timestamps make the bundle layout reproducible. codesign hashes contents,
# not times, so stamping again after signing keeps the signature valid.
STAMP="$(TZ=UTC date -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)"
export TZ=UTC

step "Signing ($([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
find "$APP" -exec touch -h -t "$STAMP" {} +

step "Done"
echo "$APP"
echo "version $VERSION, $(lipo -archs "$APP/Contents/MacOS/DiskAnalyzer"), $(du -sh "$APP" | cut -f1)"
