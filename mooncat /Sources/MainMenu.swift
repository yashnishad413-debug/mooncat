import AppKit

/// MoonCat is an accessory app (no Dock icon, no visible menu bar), but a main menu
/// still has to exist so that ⌘, ⌘W ⌘Q and the text-editing shortcuts (⌘C ⌘V ⌘A ⌘Z)
/// work while one of her windows is in front.
enum MainMenu {
    static func install(target: PetController) {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Moon Cat")
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(PetController.openPreferences), keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(prefs)
        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Moon Cat", action: #selector(PetController.quit), keyEquivalent: "q")
        quit.target = target
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        // Edit menu (text fields need these to accept paste, undo, select all)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}
