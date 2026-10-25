#!/bin/bash
# Signs, notarizes and packages MoonCat.app for sharing.
#
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="mooncat-notary" \
#   ./release/release.sh [--dry-run]
#
# One-time setup of the notary profile (needs a paid Apple Developer account):
#   xcrun notarytool store-credentials "mooncat-notary" \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# No paid account? Skip this script. See release/README_RELEASE.md ("Without a paid account").
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MoonCat.app"
OUT="$ROOT/release-output"
ENT="$ROOT/release/MoonCat.entitlements"

if [ -z "${DEV_ID:-}" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "Set DEV_ID (your 'Developer ID Application: ...' identity) and NOTARY_PROFILE first." >&2
  echo "See the comments at the top of this script." >&2
  exit 1
fi

run() {
  echo "+ $*"
  if [ "$DRY" -eq 0 ]; then "$@"; fi
}

# ./build.sh builds and then launches the app; quit it again, we only want the bundle.
echo "Building..."
if [ "$DRY" -eq 0 ]; then
  (cd "$ROOT" && ./build.sh)
  pkill -x MoonCat 2>/dev/null || true
else
  echo "+ ./build.sh"
fi

if [ "$DRY" -eq 0 ]; then
  [ -d "$APP" ] || { echo "MoonCat.app was not built." >&2; exit 1; }
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
else
  VERSION="DRY"
fi

mkdir -p "$OUT"
NOTARY_ZIP="$OUT/MoonCat-$VERSION-notarize.zip"
FINAL_ZIP="$OUT/MoonCat-$VERSION.zip"

run codesign --force --deep --options runtime --timestamp --entitlements "$ENT" --sign "$DEV_ID" "$APP"
run codesign --verify --deep --strict --verbose=2 "$APP"
run ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
run xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
run xcrun stapler staple "$APP"
run spctl --assess --type execute --verbose=2 "$APP"
run ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
if [ "$DRY" -eq 0 ]; then
  (cd "$OUT" && shasum -a 256 "MoonCat-$VERSION.zip" > "MoonCat-$VERSION.zip.sha256")
  rm -f "$NOTARY_ZIP"
  echo "Done: $FINAL_ZIP"
else
  echo "Dry run finished. Nothing was changed."
fi
