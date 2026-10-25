import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private var plistURL: URL {
        let launchAgents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return launchAgents.appendingPathComponent("com.jamessavoie.DisplaySaver.plist")
    }

    private init() {
        refreshStatus()
        // Default to Launch at Login enabled on first setup unless explicitly disabled by the user
        if UserDefaults.standard.object(forKey: "hasConfiguredLaunchAtLogin") == nil {
            UserDefaults.standard.set(true, forKey: "hasConfiguredLaunchAtLogin")
            setEnabled(true)
        }
    }

    func refreshStatus() {
        if SMAppService.mainApp.status == .enabled {
            isEnabled = true
        } else {
            isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                isEnabled = true
                return
            } catch {
                // Fallback to user LaunchAgent plist if not code-signed for SMAppService
                installLaunchAgentPlist()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgentPlist()
            isEnabled = false
        }
    }

    private func installLaunchAgentPlist() {
        let appsExecPath = "/Applications/DisplaySaver.app/Contents/MacOS/DisplaySaver"
        let executablePath = FileManager.default.fileExists(atPath: appsExecPath)
            ? appsExecPath
            : (Bundle.main.executablePath ?? appsExecPath)
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let plistContent: [String: Any] = [
            "Label": "com.jamessavoie.DisplaySaver",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
            isEnabled = true
        }
    }

    private func removeLaunchAgentPlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
