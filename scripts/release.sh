#!/usr/bin/env bash
# Builds a signed, notarized SnapShotX.dmg ready to hand to other people.
#
# One-time setup (needs a paid Apple Developer account):
#   1. Install a "Developer ID Application" certificate in your keychain.
#   2. Store notarization credentials:
#        xcrun notarytool store-credentials snapshotx-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/release.sh
#   NOTARY_PROFILE=snapshotx-notary is the default profile name; override it with that variable.
#
# Without SIGN_IDENTITY this still makes build/SnapShotX.dmg, ad-hoc signed and not notarized, which is fine
# for trying the packaging but will be blocked by Gatekeeper on other Macs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SnapShotX.app"
DMG="$ROOT/build/SnapShotX.dmg"
STAGE="$ROOT/build/dmg-stage"
PROFILE="${NOTARY_PROFILE:-snapshotx-notary}"

"$ROOT/scripts/build_app.sh" release

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SnapShotX" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "Built $DMG (not signed for distribution: set SIGN_IDENTITY to notarize)"
    exit 0
fi

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "Submitting to Apple for notarization (usually a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Built and notarized $DMG"
