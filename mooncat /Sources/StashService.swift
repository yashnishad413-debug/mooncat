import AppKit

/// Handles the Finder's "Send to Moon Cat" service (declared as NSServices in Info.plist).
/// After the first install you may need to run `/System/Library/CoreServices/pbs -update`
/// (or log out and in) before the item shows up in Finder's right-click ▸ Services menu.
final class StashServiceProvider: NSObject {
    static let shared = StashServiceProvider()
    var onFiles: (([URL]) -> Void)?

    @objc func sendToMoonCat(_ pboard: NSPasteboard,
                             userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            error.pointee = "I didn't get any files." as NSString
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFiles?(urls)
        }
    }
}
