import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainWindowController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let c = controller ?? MainWindowController()
        controller = c
        buildMenu(for: c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let u = pendingURL { pendingURL = nil; c.open(folder: u) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let c = controller else { pendingURL = url; return }
        c.open(folder: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu(for controller: MainWindowController) {
        let main = NSMenu()

        // Explicit targets; the responder chain leaves these dead otherwise.
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = controller
        }

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "Open Folder…", #selector(MainWindowController.openFolder), "o")
        add(fileMenu, "Rescan", #selector(MainWindowController.rescan), "r")
        fileMenu.addItem(.separator())
        add(fileMenu, "Export Contact Sheet…", #selector(MainWindowController.exportSheet), "e")
        add(fileMenu, "Export CSV…", #selector(MainWindowController.exportCSV), "E")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Stereo Panel", #selector(MainWindowController.toggleStereo), "k")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(string: """
            Batch mastering QA.

            Loudness follows EBU R128 / ITU-R BS.1770-4: K-weighted, gated integrated \
            LUFS, loudness range, and 4x oversampled true peak. Verified against \
            ffmpeg's ebur128 to within 0.05 LU.

            Correlation is per-block Pearson across L/R. +1 is mono, 0 is decorrelated, \
            below 0 means the low end partly cancels when a club system sums to mono.

            Double-click a row to open it in Nyquist.
            """, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: credits,
        ])
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
