# Releasing MoonCat

## With a paid Apple Developer account ($99/year)
1. In Xcode (Settings ▸ Accounts ▸ Manage Certificates) create a **Developer ID Application** certificate.
2. Create an app-specific password at appleid.apple.com and store it once:
   `xcrun notarytool store-credentials "mooncat-notary" --apple-id you@example.com --team-id TEAMID --password <app-specific-password>`
3. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `build.sh` (and `Info.plist` for Xcode builds).
4. Try it without changing anything: `DEV_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=mooncat-notary ./release/release.sh --dry-run`
5. Run it for real (drop `--dry-run`). You get `release-output/MoonCat-<version>.zip` and a `.sha256` file.
6. Publish the zip on a GitHub release (or anywhere). People unzip it and drag it to Applications.

## Without a paid account
You can still share the app, but macOS will warn about an unidentified developer.
- Zip `MoonCat.app` (`ditto -c -k --keepParent MoonCat.app MoonCat.zip`) and share it.
- The person who receives it right-clicks the app ▸ **Open** ▸ **Open** the first time, or runs
  `xattr -dr com.apple.quarantine /Applications/MoonCat.app`.
- `build.sh` already signs ad-hoc, which is enough to run on your own Mac.

## Automatic updates (optional)
`Sources/Updater.swift` does nothing until Sparkle is added; the steps are in that file's header.
Sparkle needs a hosted `appcast.xml`, so skip it if you only share the app by hand.

## Entitlements
`MoonCat.entitlements` is deliberately empty: MoonCat is not sandboxed and needs no special
entitlements. Do not add the App Sandbox without redesigning the Treasure Box, the Finder service and Downloads watcher.
