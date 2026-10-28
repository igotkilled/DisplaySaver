import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var didSetupUI = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if Self.ensureRunningFromApplicationsFolder() {
            return
        }
        setupUIIfNeeded()
    }

    func setupUIIfNeeded() {
        guard !didSetupUI else { return }
        didSetupUI = true
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
        popover.contentSize = NSSize(width: 468, height: 640)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let popoverHosting = NSHostingController(
            rootView: MenuBarView(
                manager: manager,
                loginManager: loginManager,
                onOpenDashboardWindow: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.showMainWindow()
                }
            )
        )
        popover.contentViewController = popoverHosting

        // Reactively update the status bar icon and window size when state changes
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if let button = self.statusItem?.button {
                    self.updateStatusButton(button, manager: manager)
                }
                self.adjustWindowHeightIfNeeded(manager: manager)
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
            contentRect: NSRect(x: 0, y: 0, width: 468, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DisplaySaver"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(
            rootView: MenuBarView(
                manager: DisplayManager.shared,
                loginManager: LaunchAtLoginManager.shared,
                onOpenDashboardWindow: nil
            )
        )
        window.contentViewController = hosting
        window.minSize = NSSize(width: 468, height: 560)
        window.setContentSize(NSSize(width: 468, height: 640))
        window.center()
        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func adjustWindowHeightIfNeeded(manager: DisplayManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let needsExpanded = manager.isEditingLayout || manager.previewingProfileID != nil
            let targetHeight: CGFloat = needsExpanded ? 760 : 640
            self.popover.contentSize = NSSize(width: 468, height: targetHeight)
            if let window = self.mainWindow {
                var frame = window.frame
                let currentContentH = window.contentRect(forFrameRect: frame).height
                if needsExpanded && currentContentH < 740 {
                    let delta = targetHeight - currentContentH
                    frame.origin.y -= delta
                    frame.size.height += delta
                    if frame.size.width < 468 {
                        frame.size.width = 468
                    }
                    window.setFrame(frame, display: true, animate: true)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // When the user clicks the red close button (X), keep DisplaySaver running in the background
        // and hide the Dock icon!
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Ensures `/Applications/DisplaySaver.app` is used when launched from Downloads/Documents without blocking main thread on iCloud Drive I/O.
    private static func ensureRunningFromApplicationsFolder() -> Bool {
        let appsBundleURL = URL(fileURLWithPath: "/Applications/DisplaySaver.app").standardizedFileURL
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL

        // If we are ALREADY running from /Applications/DisplaySaver.app, never touch iCloud Drive!
        if currentBundleURL.path == appsBundleURL.path {
            return false
        }

        let fm = FileManager.default
        let appsExec = appsBundleURL.appendingPathComponent("Contents/MacOS/DisplaySaver")

        if !currentBundleURL.path.hasPrefix("/Volumes/") {
            let curExec = currentBundleURL.appendingPathComponent("Contents/MacOS/DisplaySaver")
            let curMod = (try? fm.attributesOfItem(atPath: curExec.path)[.modificationDate] as? Date) ?? Date()
            let appsMod = (try? fm.attributesOfItem(atPath: appsExec.path)[.modificationDate] as? Date) ?? .distantPast
            if !fm.fileExists(atPath: appsExec.path) || curMod > appsMod {
                try? fm.removeItem(at: appsBundleURL)
                try? fm.copyItem(at: currentBundleURL, to: appsBundleURL)
            }
        }

        if fm.fileExists(atPath: appsExec.path) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appsBundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            return true
        }
        return false
    }
}

@main
struct DisplaySaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Ensure UI setup & display monitoring always start on the next main runloop tick
        // even if macOS 27.2 delays or skips SwiftUI Settings-only lifecycle callbacks.
        DispatchQueue.main.async {
            AppDelegate.shared?.setupUIIfNeeded()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
