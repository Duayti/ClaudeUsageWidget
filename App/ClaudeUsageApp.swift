import AppKit
import SwiftUI

/// Host app: macOS only registers a widget if it ships inside an app.
/// Opening it (Dock, Finder or a click on the widget through `claudeusage://panel`) shows ONE window
/// with the usage panel; if it is already open, it is brought to the front. On launch it runs the updater once.
@main
@MainActor
enum ClaudeUsageApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = PanelStore()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showPanel()
        store.refresh()     // updater in the background; when done it reloads and refreshes the widgets
    }

    /// Click on the widget: `claudeusage://panel?model=Opus%205.5`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let request = PanelLink.request(from: url) { store.apply(request) }
        }
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !store.updating { store.reload() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func refreshNow(_ sender: Any?) { store.refresh() }

    /// Name shown in the window title and the app menu.
    private static var appName: String { String(localized: "Claude Usage") }

    private func showPanel() {
        if window == nil {
            let host = NSHostingController(rootView: PanelView(store: store))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = Self.appName
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 900, height: 640))
            w.contentMinSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ClaudeUsageWidgetPanel")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let name = Self.appName

        let app = NSMenu(title: name)
        app.addItem(withTitle: String(localized: "About \(name)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let update = app.addItem(withTitle: String(localized: "Update Now"), action: #selector(refreshNow(_:)), keyEquivalent: "r")
        update.target = self
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide \(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit \(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        for sub in [app, edit, window] {
            let item = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            item.submenu = sub
            main.addItem(item)
        }
        return main
    }
}
