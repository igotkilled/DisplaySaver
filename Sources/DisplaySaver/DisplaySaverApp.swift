import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.ensureRunningFromApplicationsFolder() {
            return
        }
        let manager = DisplayManager.shared
        let loginManager = LaunchAtLoginManager.shared

        // Use default NSStatusItem autosave ("Item-0") and standard Preferred Position key
        // so macOS ControlCenter and Bartender 7 place it in the visible menu bar area.
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position Item-0") == nil {
            UserDefaults.standard.set(260.0, forKey: "NSStatusItem Preferred Position Item-0")
        }
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible Item-0")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true

        if let button = item.button {
            updateStatusButton(button, manager: manager)
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item

        // Configure popover for single-clicking the menu bar item
        popover.contentSize = NSSize(width: 350, height: 480)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                manager: manager,
                loginManager: loginManager,
                onOpenDashboardWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.showMainWindow()
                }
            )
        )

        // Reactively update the status bar icon when state changes
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, let button = self.statusItem?.button else { return }
                self.updateStatusButton(button, manager: manager)
            }
            .store(in: &cancellables)

        // Show the main window (and Dock icon) on initial launch so the user always sees it
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon or double-clicking DisplaySaver.app in Finder opens the main window
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the background when the red close button is clicked!
        return false
    }

    private func updateStatusButton(_ button: NSStatusBarButton, manager: DisplayManager) {
        let symbolName: String
        if !manager.autoEnforceLayout {
            symbolName = "display"
        } else if manager.doesCurrentMatchActiveProfile {
            symbolName = "lock.display"
        } else {
            symbolName = "exclamationmark.triangle"
        }

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DisplaySaver")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "DisplaySaver") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let configured = img.withSymbolConfiguration(config) ?? img
            configured.isTemplate = true
            button.image = configured
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = "🖥"
        }
        button.toolTip = "DisplaySaver — Click to expand, double-click (or right-click) to open window & Dock icon"
    }

    @objc private func handleStatusBarClick(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent

        // Right-click or double-click on the menu bar icon opens the standalone window + Dock icon!
        if event?.type == .rightMouseUp || (event?.clickCount ?? 1) >= 2 {
            popover.performClose(sender)
            showMainWindow()
            return
        }

        // Single left-click toggles the menu bar popover
        if popover.isShown {
            popover.performClose(sender)
        } else {
            DisplayManager.shared.refreshCurrentDisplays()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showMainWindow() {
        DisplayManager.shared.refreshCurrentDisplays()

        // Show the app icon in the macOS Dock whenever the window is open!
        NSApp.setActivationPolicy(.regular)

        if let window = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DisplaySaver"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MenuBarView(
                manager: DisplayManager.shared,
                loginManager: LaunchAtLoginManager.shared,
                onOpenDashboardWindow: nil
            )
        )
        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // When the user clicks the red close button (X), keep DisplaySaver running in the background
        // and hide the Dock icon!
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Ensures `/Applications/DisplaySaver.app` is up-to-date and that the running process is the `/Applications/DisplaySaver.app` instance
    /// (required by macOS 27 Menu Bar & Bartender 7). Also watches the workspace build for changes and hot-reloads `/Applications/DisplaySaver.app` automatically!
    private static func ensureRunningFromApplicationsFolder() -> Bool {
        let workspaceBundleURL = URL(fileURLWithPath: "/Users/jamessavoie/Documents/mac display saver/DisplaySaver.app").standardizedFileURL
        let appsBundleURL = URL(fileURLWithPath: "/Applications/DisplaySaver.app").standardizedFileURL
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let fm = FileManager.default

        let workspaceExec = workspaceBundleURL.appendingPathComponent("Contents/MacOS/DisplaySaver")
        let appsExec = appsBundleURL.appendingPathComponent("Contents/MacOS/DisplaySaver")

        let workspaceMod = (try? fm.attributesOfItem(atPath: workspaceExec.path)[.modificationDate] as? Date) ?? .distantPast
        let appsMod = (try? fm.attributesOfItem(atPath: appsExec.path)[.modificationDate] as? Date) ?? .distantPast

        // Copy workspace bundle to /Applications if /Applications is missing or older
        if fm.fileExists(atPath: workspaceExec.path) && (!fm.fileExists(atPath: appsExec.path) || workspaceMod > appsMod) {
            try? fm.removeItem(at: appsBundleURL)
            try? fm.copyItem(at: workspaceBundleURL, to: appsBundleURL)
        } else if currentBundleURL.path != appsBundleURL.path && !currentBundleURL.path.hasPrefix("/Volumes/") {
            // For general users launching from ~/Downloads or ~/Desktop, install into /Applications automatically
            let curExec = currentBundleURL.appendingPathComponent("Contents/MacOS/DisplaySaver")
            let curMod = (try? fm.attributesOfItem(atPath: curExec.path)[.modificationDate] as? Date) ?? Date()
            if !fm.fileExists(atPath: appsExec.path) || curMod > appsMod {
                try? fm.removeItem(at: appsBundleURL)
                try? fm.copyItem(at: currentBundleURL, to: appsBundleURL)
            }
        }

        // If we were launched from the workspace (not /Applications), launch the /Applications copy and terminate this one!
        if currentBundleURL.path != appsBundleURL.path && fm.fileExists(atPath: appsExec.path) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appsBundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            return true
        }

        // We ARE running from /Applications/DisplaySaver.app!
        // Start a lightweight watcher so whenever a new build is compiled in the workspace,
        // /Applications/DisplaySaver.app automatically updates and relaunches itself!
        let initialMod = (try? fm.attributesOfItem(atPath: appsExec.path)[.modificationDate] as? Date) ?? Date()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let fileMgr = FileManager.default
            guard let latestWorkspaceMod = (try? fileMgr.attributesOfItem(atPath: workspaceExec.path)[.modificationDate] as? Date),
                  latestWorkspaceMod > initialMod.addingTimeInterval(1.0) else {
                return
            }
            try? fileMgr.removeItem(at: appsBundleURL)
            if (try? fileMgr.copyItem(at: workspaceBundleURL, to: appsBundleURL)) != nil {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", appsBundleURL.path]
                try? task.run()
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
        return false
    }
}

@main
struct DisplaySaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
