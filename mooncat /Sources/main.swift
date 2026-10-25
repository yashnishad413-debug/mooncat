// MoonCat — a little cat that lives on your Mac desktop.
// Native AppKit app: transparent, borderless, always-on-top window.
// Build with ./build.sh (needs Xcode Command Line Tools).

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Converter.selfCheck()
let controller = PetController()
MainMenu.install(target: controller)
app.run()
