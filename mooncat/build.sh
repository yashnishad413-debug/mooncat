#!/bin/bash
# Builds MoonCat.app and launches it.
# Requires Xcode Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

APP="MoonCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
# -target pins the deployment target to macOS 13, same as the Xcode project, so a newer
# macOS on this machine does not hide use of APIs that 13 does not have.
swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/MoonCat" Sources/*.swift \
  -framework AppKit -framework QuartzCore -framework ServiceManagement \
  -framework Carbon -framework QuickLookUI -framework QuickLookThumbnailing \
  -framework Security -framework CryptoKit -framework UserNotifications -framework IOKit \
  -framework AVFoundation -framework PDFKit -framework Vision -framework ImageIO -framework ScreenCaptureKit

cp sprites/*.png "$APP/Contents/Resources/"
# Illustrations used in the windows (art/art_*.png and .jpg).
cp art/* "$APP/Contents/Resources/" 2>/dev/null || true
# Optional app icon: run tools/make_icon.sh once to create Resources/AppIcon.icns.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Optional sounds: put meow.wav, purr.wav and chime.wav in sounds/ (see sounds/README.txt).
if ls sounds/*.wav >/dev/null 2>&1; then
  cp sounds/*.wav "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MoonCat</string>
  <key>CFBundleIdentifier</key><string>com.yash.mooncat</string>
  <key>CFBundleName</key><string>MoonCat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Moon Cat gets excited when a download finishes. She only looks at file names and sizes in your Downloads folder.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Send to Moon Cat</string>
      </dict>
      <key>NSMessage</key>
      <string>sendToMoonCat</string>
      <key>NSPortName</key>
      <string>MoonCat</string>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.item</string>
      </array>
      <key>NSSendTypes</key>
      <array>
        <string>public.file-url</string>
        <string>NSFilenamesPboardType</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign with a stable identity so Keychain "Always Allow" survives rebuilds. An ad-hoc
# signature ("-") changes on every build, which makes macOS ask for the Keychain password
# again each time. Run tools/setup_signing.sh once to create the "MoonCat Dev" identity.
SIGN_ID="${MOONCAT_SIGN_ID:-MoonCat Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "Signed with \"$SIGN_ID\"."
else
  echo "Note: no \"$SIGN_ID\" signing identity found, using an ad-hoc signature."
  echo "      macOS will re-ask for Keychain access after each rebuild. Fix: tools/setup_signing.sh"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP — launching."
open "$APP"
