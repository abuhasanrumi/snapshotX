#!/usr/bin/env bash
# Builds SnapKit and wraps the binary in a proper .app bundle at build/SnapKit.app.
# Usage: scripts/build_app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SnapKit.app"
BUNDLE_ID="com.snapkit.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SnapKit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SnapKit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign with an identifier-only designated requirement. The default ad-hoc requirement is the
# binary's hash, which changes every build and makes macOS forget the Screen Recording grant each time.
codesign --force --sign - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" \
    "$APP"

echo "Built $APP"
