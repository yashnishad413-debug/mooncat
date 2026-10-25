import Foundation

// Optional automatic updates through Sparkle.
//
// Without Sparkle this file does nothing: `isAvailable` is false and the menu hides the item.
// To switch it on:
//   1. Add the Sparkle framework to the app (Xcode: File ▸ Add Package Dependencies ▸
//      https://github.com/sparkle-project/Sparkle) and make sure the swiftc/Xcode build can import it.
//   2. Generate keys with Sparkle's `generate_keys`, and put the public key in Info.plist as SUPublicEDKey.
//   3. Host an appcast.xml (made by Sparkle's `generate_appcast`) and put its address in Info.plist as SUFeedURL.
//   4. Sign every release zip with your private key.

#if canImport(Sparkle)
import Sparkle

final class MoonCatUpdater {
    static let shared = MoonCatUpdater()
    static let isAvailable = true
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts the updater only if the feed address and key are in Info.plist.
    func start() {
        let info = Bundle.main.infoDictionary
        guard info?["SUFeedURL"] != nil, info?["SUPublicEDKey"] != nil else { return }
        controller.startUpdater()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
#else
final class MoonCatUpdater {
    static let shared = MoonCatUpdater()
    static let isAvailable = false
    private init() {}
    func start() {}
    func checkForUpdates() {}
}
#endif
