import AppKit

/// The menu bar, built in code (there is no storyboard).
///
/// Viewer commands use nil targets, so they reach the key window's `ViewerWindowController`
/// through the responder chain.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(viewMenu()))
        menu.addItem(submenu(goMenu()))
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApp.windowsMenu = window
        return menu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "NooVeu")
        menu.addItem(withTitle: "About NooVeu", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide NooVeu", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NooVeu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Zoom In", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "=")
        menu.addItem(withTitle: "Zoom Out", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Pixels", action: #selector(ViewerWindowController.actualPixels(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(ViewerWindowController.zoomToFit(_:)), keyEquivalent: "9")
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Next Image", #selector(ViewerWindowController.nextImage(_:)), key(NSRightArrowFunctionKey), [.command]))
        menu.addItem(item("Previous Image", #selector(ViewerWindowController.previousImage(_:)), key(NSLeftArrowFunctionKey), [.command]))
        menu.addItem(item("First Image", #selector(ViewerWindowController.firstImage(_:)), key(NSUpArrowFunctionKey), [.command]))
        menu.addItem(item("Last Image", #selector(ViewerWindowController.lastImage(_:)), key(NSDownArrowFunctionKey), [.command]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt32(functionKey))!))
    }
}
