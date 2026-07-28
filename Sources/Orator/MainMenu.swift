import Cocoa

@MainActor
enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(rootItem(title: "Orator", submenu: appMenu(appDelegate: appDelegate)))
        mainMenu.addItem(rootItem(title: "File", submenu: fileMenu(appDelegate: appDelegate)))
        mainMenu.addItem(rootItem(title: "Edit", submenu: editMenu()))
        mainMenu.addItem(rootItem(title: "Speech", submenu: speechMenu(appDelegate: appDelegate)))

        let windowMenu = windowMenu()
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(rootItem(title: "Window", submenu: windowMenu))

        mainMenu.addItem(rootItem(title: "Help", submenu: helpMenu(appDelegate: appDelegate)))
        return mainMenu
    }

    private static func appMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Orator")
        menu.addItem(item(
            title: "About Orator",
            action: "orderFrontStandardAboutPanel:"
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Settings…",
            action: "openOratorSettings",
            keyEquivalent: ",",
            target: appDelegate
        ))
        menu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        menu.addItem(rootItem(title: "Services", submenu: servicesMenu))

        menu.addItem(.separator())
        menu.addItem(item(title: "Hide Orator", action: "hide:", keyEquivalent: "h"))
        menu.addItem(item(
            title: "Hide Others",
            action: "hideOtherApplications:",
            keyEquivalent: "h",
            modifiers: [.command, .option]
        ))
        menu.addItem(item(title: "Show All", action: "unhideAllApplications:"))
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Quit Orator",
            action: "quit",
            keyEquivalent: "q",
            target: appDelegate
        ))
        return menu
    }

    private static func fileMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item(title: "Open Reader…", action: "openReader", target: appDelegate))
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Export Selection to Audio…",
            action: "exportSelectionToAudio",
            target: appDelegate
        ))
        menu.addItem(item(
            title: "Export Clipboard to Audio…",
            action: "exportClipboardToAudio",
            target: appDelegate
        ))
        menu.addItem(item(
            title: "Export File to Audio…",
            action: "exportFileToAudio",
            target: appDelegate
        ))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item(title: "Undo", action: "undo:", keyEquivalent: "z"))
        menu.addItem(item(
            title: "Redo",
            action: "redo:",
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(item(title: "Cut", action: "cut:", keyEquivalent: "x"))
        menu.addItem(item(title: "Copy", action: "copy:", keyEquivalent: "c"))
        menu.addItem(item(title: "Paste", action: "paste:", keyEquivalent: "v"))
        menu.addItem(item(title: "Delete", action: "delete:"))
        menu.addItem(item(title: "Select All", action: "selectAll:", keyEquivalent: "a"))
        return menu
    }

    private static func speechMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Speech")
        menu.addItem(item(
            title: "Speak Clipboard",
            action: "speakClipboardText",
            target: appDelegate
        ))
        menu.addItem(item(
            title: "Pause / Resume",
            action: "pauseResumeSpeaking",
            target: appDelegate
        ))
        menu.addItem(item(title: "Stop", action: "stopSpeaking", target: appDelegate))
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Add Clipboard to Queue",
            action: "addClipboardToQueue",
            target: appDelegate
        ))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item(
            title: "Minimize",
            action: "performMiniaturize:",
            keyEquivalent: "m"
        ))
        menu.addItem(item(title: "Zoom", action: "performZoom:"))
        menu.addItem(.separator())
        menu.addItem(item(title: "Bring All to Front", action: "arrangeInFront:"))
        return menu
    }

    private static func helpMenu(appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item(title: "Orator Help", action: "openOratorHelp", target: appDelegate))
        return menu
    }

    private static func rootItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    private static func item(
        title: String,
        action: String,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: title,
            action: NSSelectorFromString(action),
            keyEquivalent: keyEquivalent
        )
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        return menuItem
    }
}
