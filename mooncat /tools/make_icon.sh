#!/bin/bash
# Makes Resources/AppIcon.icns. Run once (macOS only: it needs iconutil), then ./build.sh picks it up.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf MoonCat.iconset
swift tools/make_icon.swift MoonCat.iconset
mkdir -p Resources
iconutil -c icns MoonCat.iconset -o Resources/AppIcon.icns
rm -rf MoonCat.iconset
echo "Created Resources/AppIcon.icns. Now run ./build.sh"
