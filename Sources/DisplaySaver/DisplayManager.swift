import Foundation
import CoreGraphics
import AppKit
import Combine
import ObjectiveC
import IOKit
import IOKit.pwr_mgt

private func coreDisplayCreateInfoDictionary(_ display: CGDirectDisplayID) -> [String: Any]? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
        return nil
    }
    typealias CreateInfoDictFunc = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    let fn = unsafeBitCast(sym, to: CreateInfoDictFunc.self)
    return fn(display)?.takeRetainedValue() as? [String: Any]
}

/// Global C callback for CoreGraphics display reconfiguration events.
private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        DisplayManager.shared.handleDisplayReconfiguration(display: display, flags: flags)
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()
    static let maxSavedProfiles = 5

    @Published var currentDisplays: [DisplayConfig] = []
    @Published var savedProfiles: [DisplayProfile] = []
    @Published var activeProfileID: UUID? {
        didSet {
            UserDefaults.standard.set(activeProfileID?.uuidString, forKey: "activeProfileID")
        }
    }
    @Published var autoEnforceLayout: Bool {
        didSet {
            UserDefaults.standard.set(autoEnforceLayout, forKey: "autoEnforceLayout")
        }
    }
    @Published var autoSwitchByHardwareSet: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchByHardwareSet, forKey: "autoSwitchByHardwareSet")
        }
    }
    @Published var autoRestoreWindowPositions: Bool {
        didSet {
            UserDefaults.standard.set(autoRestoreWindowPositions, forKey: "autoRestoreWindowPositions")
        }
    }
    @Published var isAccessibilityTrusted: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var lastRestoredDate: Date?
    @Published var isApplying: Bool = false
    @Published var eventLog: [String] = []
    @Published var isCreatingProfile: Bool = false
    @Published var isSavingEditedAsNew: Bool = false
    @Published var newProfileName: String = ""
    @Published var showActivityLog: Bool = false
    @Published var isEditingLayout: Bool = false {
        didSet {
            AlignmentGuideWindowController.shared.syncVisibility(manager: self)
        }
    }
    @Published var showAlignmentGuide: Bool = false {
        didSet {
            AlignmentGuideWindowController.shared.syncVisibility(manager: self)
        }
    }
    @Published var arrowKeyAlignmentEnabled: Bool = true
    @Published var editingDisplays: [DisplayConfig] = []
    @Published var selectedEditingDisplayUUID: String? = nil
    @Published var draggingDisplayUUID: String? = nil
    @Published var dragTranslation: CGSize = .zero
    @Published var previewingProfileID: UUID? = nil
    @Published var renamingProfileID: UUID? = nil
    @Published var renamingProfileText: String = ""
    @Published var hoveredProfileID: UUID? = nil
    @Published var hoveredButtonTag: String? = nil
    @Published var isHoveringHeaderStatus: Bool = false

    private var debounceTimer: Timer?
    private var periodicCheckTimer: Timer?
    private var suppressCallbackUntil: Date = .distantPast
    private var lastDisplayChangeDate: Date = Date()
    private var bootWindowRestoreDeadline: Date = .distantPast
    private var areSystemScreensAsleep: Bool = false
    private var pauseWatchdogUntil: Date = .distantPast
    private var lastEditorInteractionDate: Date = .distantPast
    private let storageURL: URL

    private init() {
        let fm = FileManager.default
        let storageDir: URL
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = appSupport.appendingPathComponent("DisplaySaver", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            storageDir = folder
        } else {
            storageDir = Bundle.main.bundleURL.deletingLastPathComponent()
        }
        self.storageURL = storageDir.appendingPathComponent("profiles.json")

        self.autoEnforceLayout = UserDefaults.standard.object(forKey: "autoEnforceLayout") as? Bool ?? true
        self.autoSwitchByHardwareSet = UserDefaults.standard.object(forKey: "autoSwitchByHardwareSet") as? Bool ?? false
        self.autoRestoreWindowPositions = UserDefaults.standard.object(forKey: "autoRestoreWindowPositions") as? Bool ?? true
        self.isAccessibilityTrusted = WindowPositionManager.isAccessibilityTrusted()

        // Load MonitorPanel private framework for native display rotation support
        _ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)

        loadProfiles()
        if savedProfiles.isEmpty {
            // Seed with the user's known default 3-display layout if no local profile exists yet
            savedProfiles = Self.defaultSeededProfiles()
            if !savedProfiles.isEmpty {
                persistProfiles()
            }
        }
        if let savedIDStr = UserDefaults.standard.string(forKey: "activeProfileID"),
           let savedUUID = UUID(uuidString: savedIDStr),
           savedProfiles.contains(where: { $0.id == savedUUID }) {
            self.activeProfileID = savedUUID
        } else {
            self.activeProfileID = savedProfiles.first?.id
        }

        refreshCurrentDisplays()

        // If this is the very first launch (no saved profiles yet), automatically save the current layout!
        if savedProfiles.isEmpty && !currentDisplays.isEmpty {
            let suggested = DisplayProfile.suggestedName(for: currentDisplays)
            saveCurrentAsProfile(name: suggested)
            logEvent("Created initial '\(suggested)' setup from current display configuration.")
        }

        registerCallbacks()

        // Immediately check and enforce the saved layout on launch (e.g., right after reboot/login)
        if autoEnforceLayout {
            scheduleCheckAndRestore(delay: 0.5)
        }

        // ONLY restore windows on app startup if the Mac actually just booted/restarted (systemUptime < 5 minutes).
        // Relaunching DisplaySaver during normal desktop usage will NOT move any windows.
        let didMacJustBoot = ProcessInfo.processInfo.systemUptime < 300.0
        if didMacJustBoot {
            self.bootWindowRestoreDeadline = Date().addingTimeInterval(90.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.autoRestoreWindowPositions else { return }
                self.refreshAccessibilityStatus()
                self.restoreSavedWindowsForActiveProfile(reason: "After Mac restart", silentIfZero: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
                guard let self, self.autoRestoreWindowPositions else { return }
                self.restoreSavedWindowsForActiveProfile(reason: "Post-login window restore", silentIfZero: true)
            }
        } else {
            // Normal session launch: just snapshot current window positions if none were saved yet, never move windows!
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.refreshAccessibilityStatus()
                if self.doesCurrentMatchActiveProfile {
                    self.captureWindowPositionsForActiveProfile(silent: true)
                }
            }
        }
    }

    var activeProfile: DisplayProfile? {
        guard let id = activeProfileID else { return savedProfiles.first }
        return savedProfiles.first(where: { $0.id == id }) ?? savedProfiles.first
    }

    var previewingProfile: DisplayProfile? {
        guard let id = previewingProfileID else { return nil }
        return savedProfiles.first(where: { $0.id == id })
    }

    var canAddMoreProfiles: Bool {
        savedProfiles.count < Self.maxSavedProfiles
    }

    var selectedEditingDisplay: DisplayConfig? {
        guard isEditingLayout else { return nil }
        if let id = selectedEditingDisplayUUID,
           let disp = editingDisplays.first(where: { $0.uuid == id }) {
            return disp
        }
        return editingDisplays.first
    }

    var doesCurrentMatchActiveProfile: Bool {
        guard let profile = activeProfile else { return true }
        return matchesProfile(profile, against: currentDisplays)
    }

    var suggestedNameForPendingSave: String {
        let source = (isEditingLayout && !editingDisplays.isEmpty) ? editingDisplays : currentDisplays
        return DisplayProfile.suggestedName(for: source)
    }

    // MARK: - Logging

    func logEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] \(message)"
        eventLog.insert(entry, at: 0)
        if eventLog.count > 100 {
            eventLog.removeLast()
        }
        statusMessage = message
        let logURL = storageURL.deletingLastPathComponent().appendingPathComponent("events.log")
        if let data = (entry + "\n").data(using: .utf8) {
            let fm = FileManager.default
            if fm.fileExists(atPath: logURL.path) {
                // Cap events.log at 256 KB so it never grows unbounded over weeks of uptime
                if let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? UInt64), size > 262_144 {
                    try? data.write(to: logURL, options: .atomic)
                    return
                }
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } catch {
                        // Ignore transient file I/O errors without throwing Objective-C NSFileHandleOperationException
                    }
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    // MARK: - Monitoring & Callbacks

    private func registerCallbacks() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.areSystemScreensAsleep = true
                self?.debounceTimer?.invalidate()
                if self?.isEditingLayout == true {
                    self?.cancelEditingLayout()
                }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.areSystemScreensAsleep = true
                self?.debounceTimer?.invalidate()
                if self?.isEditingLayout == true {
                    self?.cancelEditingLayout()
                }
                self?.logEvent("Screens went to sleep — pausing display watchdog.")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.areSystemScreensAsleep = false
                self?.pauseWatchdogUntil = .distantPast
                if self?.isEditingLayout == true {
                    self?.cancelEditingLayout()
                }
                self?.logEvent("System woke from sleep — verifying display layout...")
                self?.scheduleStagedRestoreChecks(initialDelay: 1.2)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.areSystemScreensAsleep = false
                self?.pauseWatchdogUntil = .distantPast
                if self?.isEditingLayout == true {
                    self?.cancelEditingLayout()
                }
                self?.logEvent("Screens woke — verifying display layout...")
                self?.scheduleStagedRestoreChecks(initialDelay: 1.0)
            }
        }

        // Snapshot window positions right before macOS restarts or shuts down
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.areSystemScreensAsleep, self.doesCurrentMatchActiveProfile else { return }
                self.captureWindowPositionsForActiveProfile(silent: true)
            }
        }

        // ONLY during the first 90 seconds after a Mac reboot/power-on: as macOS reopens login apps,
        // move them back to the screen they were on before rebooting. Never fires during normal usage!
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor in
                guard let self,
                      Date() < self.bootWindowRestoreDeadline,
                      self.autoRestoreWindowPositions,
                      !self.areSystemScreensAsleep,
                      let bundleID else {
                    return
                }
                guard let savedWins = self.activeProfile?.savedWindows,
                      savedWins.contains(where: { $0.bundleIdentifier == bundleID }) else {
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, Date() < self.bootWindowRestoreDeadline else { return }
                    self.restoreSavedWindowsForActiveProfile(onlyForBundleID: bundleID, reason: "Post-reboot app reopen (\(bundleID))", silentIfZero: true)
                }
            }
        }

        // Run a responsive periodic watchdog every 4 seconds so any refresh rate (e.g. TV 30Hz -> 60Hz) or mirroring drift is auto-corrected immediately
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.periodicWatchdogCheck()
            }
        }
    }

    func handleDisplayReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        areSystemScreensAsleep = false
        lastDisplayChangeDate = Date()
        logEvent("CGReconfig display=\(display) flags=0x\(String(flags.rawValue, radix: 16))")
        // Keep main/monitor displays awake during HDMI/CEC hotplug transitions (e.g. when turning a mirrored TV on or off)
        wakeMainDisplayIfNeeded()
        if flags.contains(.beginConfigurationFlag) {
            return
        }
        pauseWatchdogUntil = .distantPast
        // If the layout editor was left open unattended (>20s since last click) when hardware reconfigured, auto-close it so we can auto-restore!
        if isEditingLayout && Date().timeIntervalSince(lastEditorInteractionDate) > 20.0 {
            cancelEditingLayout()
        }
        refreshCurrentDisplays()
        guard Date() > suppressCallbackUntil else { return }
        scheduleStagedRestoreChecks(initialDelay: 0.5)
    }

    /// Schedules multiple staggered verification passes after wake or HDMI/DisplayPort hotplug so slow-waking TVs/monitors are caught and locked.
    func scheduleStagedRestoreChecks(initialDelay: TimeInterval = 0.5) {
        scheduleCheckAndRestore(delay: initialDelay)
        for extraDelay in [2.2, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + extraDelay) { [weak self] in
                guard let self, !self.areSystemScreensAsleep, self.autoEnforceLayout, !self.isEditingLayout, !self.isApplying else { return }
                self.reloadProfilesIfChangedOnDisk()
                self.refreshCurrentDisplays()
                if !self.doesCurrentMatchActiveProfile {
                    self.checkAndRestoreIfNeeded(reason: "Post-wake verification")
                }
            }
        }
    }

    private func wakeMainDisplayIfNeeded() {
        var assertionID: IOPMAssertionID = 0
        let reason = "DisplaySaver keeping monitors active during TV power transition" as CFString
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        ) == kIOReturnSuccess {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                IOPMAssertionRelease(assertionID)
            }
        }
        // Also pulse user activity on IODisplayWrangler so a TV standby signal doesn't blank the monitor
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        if entry != IO_OBJECT_NULL {
            IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanFalse)
            IOObjectRelease(entry)
        }
    }

    private var storageFileModDate: Date = .distantPast

    func reloadProfilesIfChangedOnDisk() {
        let curMod = (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.modificationDate] as? Date) ?? .distantPast
        if curMod > storageFileModDate {
            loadProfiles()
        }
    }

    private func periodicWatchdogCheck() {
        refreshAccessibilityStatus()
        guard !areSystemScreensAsleep, Date() >= pauseWatchdogUntil else { return }
        // Auto-exit Edit Layout if it was left open without user interaction for > 90 seconds so auto-restore is never blocked indefinitely
        if isEditingLayout && Date().timeIntervalSince(lastEditorInteractionDate) > 90.0 {
            cancelEditingLayout()
        }
        reloadProfilesIfChangedOnDisk()
        refreshCurrentDisplays()
        guard !isApplying, !isEditingLayout, Date() > suppressCallbackUntil else { return }

        if autoEnforceLayout {
            checkAndRestoreIfNeeded(reason: "Watchdog check")
        }

        // Passive recording ONLY (never moves windows!):
        // When displays are stable and no display changes or boot restores have occurred recently,
        // quietly record current window positions so we know where everything was if the Mac reboots or screens change.
        if doesCurrentMatchActiveProfile,
           Date() > bootWindowRestoreDeadline,
           Date().timeIntervalSince(lastDisplayChangeDate) > 15.0,
           Date().timeIntervalSince(lastRestoredDate ?? .distantPast) > 15.0 {
            recordStableWindowPositionsOnWatchdog()
        }
    }

    func scheduleCheckAndRestore(delay: TimeInterval = 1.0) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.areSystemScreensAsleep else { return }
                self.reloadProfilesIfChangedOnDisk()
                self.refreshCurrentDisplays()
                guard self.autoEnforceLayout, !self.isEditingLayout else { return }
                self.checkAndRestoreIfNeeded(reason: "Display change detected")
            }
        }
    }

    private func checkAndRestoreIfNeeded(reason: String) {
        guard !areSystemScreensAsleep, Date() >= pauseWatchdogUntil else { return }

        // Only defer if the Main display itself is asleep; if so, retry in 2.0s instead of dropping the restore!
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            scheduleCheckAndRestore(delay: 2.0)
            return
        }

        let currentSig = currentDisplays.map { $0.uuid }.sorted()

        // If auto-switch by connected hardware set is enabled and the user only has 1 profile per hardware set
        if autoSwitchByHardwareSet {
            let matchingProfiles = savedProfiles.filter { $0.hardwareSignature == currentSig }
            if matchingProfiles.count == 1, let matchedProfile = matchingProfiles.first {
                if activeProfileID != matchedProfile.id {
                    activeProfileID = matchedProfile.id
                    logEvent("Switched active setup to '\(matchedProfile.name)' for connected monitors.")
                }
            }
        }

        guard let targetProfile = activeProfile else { return }

        // Only auto-restore if at least one display from the profile is currently connected
        let connectedUUIDs = Set(currentDisplays.map { $0.uuid })
        let profileUUIDs = Set(targetProfile.displays.map { $0.uuid })
        guard !connectedUUIDs.intersection(profileUUIDs).isEmpty else {
            return
        }

        if !matchesProfile(targetProfile, against: currentDisplays) {
            logEvent("\(reason): Layout drifted from '\(targetProfile.name)'. Restoring...")
            applyProfile(targetProfile)
        }
    }

    // MARK: - Inspecting Displays

    func refreshCurrentDisplays() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            currentDisplays = []
            return
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else {
            return
        }

        // Map displayID -> UUID string first so we can resolve mirror master UUIDs
        var idToUUID: [CGDirectDisplayID: String] = [:]
        for id in displayIDs {
            idToUUID[id] = Self.uuidString(for: id)
        }

        var configs: [DisplayConfig] = []
        for id in displayIDs {
            let uuid = idToUUID[id] ?? "\(id)"
            let hwID = Self.hardwareID(for: id)
            let name = Self.displayName(for: id)
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let rotation = CGDisplayRotation(id)
            let isMain = CGDisplayIsMain(id) != 0

            let mirrorMasterID = CGDisplayMirrorsDisplay(id)
            let mirrorsUUID: String?
            if mirrorMasterID != kCGNullDirectDisplay && mirrorMasterID != id {
                mirrorsUUID = idToUUID[mirrorMasterID] ?? Self.uuidString(for: mirrorMasterID)
            } else {
                mirrorsUUID = nil
            }

            let config = DisplayConfig(
                uuid: uuid,
                hardwareID: hwID,
                name: name,
                isMain: isMain,
                originX: Int32(bounds.origin.x.rounded()),
                originY: Int32(bounds.origin.y.rounded()),
                width: mode?.width ?? Int(bounds.width.rounded()),
                height: mode?.height ?? Int(bounds.height.rounded()),
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width.rounded()),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height.rounded()),
                refreshRate: mode?.refreshRate ?? 0,
                rotation: rotation,
                mirrorsUUID: mirrorsUUID,
                ioDisplayModeID: mode?.ioDisplayModeID ?? 0
            )
            configs.append(config)
        }

        // Sort consistently: Main display first, then by originX, then name
        configs.sort { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.originX != b.originX { return a.originX < b.originX }
            return a.name < b.name
        }

        self.currentDisplays = configs
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, cfUUID) as String? {
            return str
        }
        return hardwareID(for: displayID)
    }

    static func hardwareID(for displayID: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "ext"
        return String(format: "%@-%04x-%04x-%08x", builtin, vendor, model, serial)
    }

    static func displayName(for displayID: CGDirectDisplayID) -> String {
        if let dict = coreDisplayCreateInfoDictionary(displayID),
           let names = dict["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.values.first,
           !name.isEmpty {
            return name
        }
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            return screen.localizedName
        }
        return CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "Display \(displayID)"
    }

    // MARK: - Profile Comparison

    func matchesProfile(_ profile: DisplayProfile, against current: [DisplayConfig]) -> Bool {
        for saved in profile.displays {
            guard let live = current.first(where: { $0.uuid == saved.uuid || $0.hardwareID == saved.hardwareID }) else {
                // If a display in the profile is currently unplugged, skip comparing that display
                continue
            }

            // Compare mirroring state
            if saved.mirrorsUUID != live.mirrorsUUID {
                return false
            }

            // Compare origin (only for non-mirrored displays or primary displays, as mirrored slaves share master origin)
            if saved.mirrorsUUID == nil {
                if abs(saved.originX - live.originX) > 1 || abs(saved.originY - live.originY) > 1 {
                    return false
                }
            }

            // Compare resolution and refresh rate across all displays (including mirrored TV/monitors so 60Hz doesn't drop to 30Hz)
            if saved.width != live.width || saved.height != live.height {
                return false
            }
            if saved.pixelWidth != live.pixelWidth || saved.pixelHeight != live.pixelHeight {
                return false
            }
            if saved.refreshRate > 0 && live.refreshRate > 0 && abs(saved.refreshRate - live.refreshRate) > 1.0 {
                return false
            }

            // Compare rotation
            if abs(saved.rotation - live.rotation) > 1.0 {
                return false
            }
        }
        return true
    }

    // MARK: - Restoring / Applying a Display Profile

    func applyProfile(_ profile: DisplayProfile) {
        guard !isApplying else { return }
        isApplying = true
        suppressCallbackUntil = Date().addingTimeInterval(4.0)
        defer { isApplying = false }

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            logEvent("Failed to enumerate online displays.")
            return
        }
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &onlineIDs, &count) == .success else {
            return
        }

        // Map online displays by UUID and hardwareID
        var uuidToDisplayID: [String: CGDirectDisplayID] = [:]
        var hwToDisplayID: [String: CGDirectDisplayID] = [:]
        for id in onlineIDs {
            uuidToDisplayID[Self.uuidString(for: id)] = id
            hwToDisplayID[Self.hardwareID(for: id)] = id
        }

        func resolveDisplayID(for config: DisplayConfig) -> CGDirectDisplayID? {
            if let id = uuidToDisplayID[config.uuid] { return id }
            if let id = hwToDisplayID[config.hardwareID] { return id }
            return nil
        }

        // Check BEFORE modifying displays whether the desktop screen arrangement/mirroring/bounds actually got switched around!
        // If all non-mirrored desktop screens are ALREADY in their saved positions and sizes (e.g., only a TV's refresh rate
        // needed a nudge after waking from sleep), we do NOT touch any app windows!
        let didScreensSwitchAround: Bool = {
            for saved in profile.displays where saved.mirrorsUUID == nil {
                guard let displayID = resolveDisplayID(for: saved) else {
                    return true
                }
                let mirrorTarget = CGDisplayMirrorsDisplay(displayID)
                if mirrorTarget != kCGNullDirectDisplay && mirrorTarget != displayID {
                    return true
                }
                let bounds = CGDisplayBounds(displayID)
                let curX = Int32(bounds.origin.x.rounded())
                let curY = Int32(bounds.origin.y.rounded())
                let curW = Int(bounds.width.rounded())
                let curH = Int(bounds.height.rounded())
                if abs(curX - saved.originX) > 2 || abs(curY - saved.originY) > 2 || abs(curW - saved.width) > 2 || abs(curH - saved.height) > 2 {
                    return true
                }
            }
            return false
        }()

        // Step 1: Apply rotation changes via MonitorPanel if any display rotation differs
        for saved in profile.displays {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
            let currentRot = CGDisplayRotation(displayID)
            if abs(currentRot - saved.rotation) > 1.0 {
                Self.setRotation(Int32(saved.rotation.rounded()), for: displayID)
            }
        }

        // Step 2: Transaction 1 — Configure Mirroring, Non-Mirrored Display Modes, and Arrangement Origins.
        // IMPORTANT: CoreGraphics returns error 1010 (kCGErrorInvalidOperation) if you call
        // CGConfigureDisplayMirrorOfDisplay AND CGConfigureDisplayWithDisplayMode on a mirrored slave
        // in the SAME transaction! Therefore we configure mirroring & non-transitioning displays first,
        // and then enforce exact modes and origins on all displays in Transaction 2 (0.8s later).
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            logEvent("Error: Could not begin CoreGraphics display configuration.")
            return
        }

        // Track which displays are changing mirror state in Transaction 1 so we don't set their display mode in the same transaction
        var mirrorTransitioningIDs = Set<CGDirectDisplayID>()

        // 2a. Configure Mirroring first
        for saved in profile.displays {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
            if let masterUUID = saved.mirrorsUUID,
               let masterID = uuidToDisplayID[masterUUID] ?? profile.displays.first(where: { $0.uuid == masterUUID }).flatMap({ resolveDisplayID(for: $0) }) {
                if onlineIDs.contains(masterID) {
                    if CGDisplayMirrorsDisplay(masterID) != kCGNullDirectDisplay {
                        CGConfigureDisplayMirrorOfDisplay(config, masterID, kCGNullDirectDisplay)
                        mirrorTransitioningIDs.insert(masterID)
                    }
                    if CGDisplayMirrorsDisplay(displayID) != masterID {
                        CGConfigureDisplayMirrorOfDisplay(config, displayID, masterID)
                        mirrorTransitioningIDs.insert(displayID)
                    }
                }
            } else {
                let currentMirrorTarget = CGDisplayMirrorsDisplay(displayID)
                if currentMirrorTarget != kCGNullDirectDisplay && currentMirrorTarget != displayID {
                    let hasSlaves = profile.displays.contains { $0.mirrorsUUID == saved.uuid }
                    if !hasSlaves {
                        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                        mirrorTransitioningIDs.insert(displayID)
                    }
                }
            }
        }

        // 2b. Configure Display Modes for displays that are NOT mirroring and NOT currently transitioning out of mirror mode
        for saved in profile.displays where saved.mirrorsUUID == nil {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
            guard !mirrorTransitioningIDs.contains(displayID),
                  CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else {
                continue
            }
            let curMode = CGDisplayCopyDisplayMode(displayID)
            let modeAlreadyMatches = (curMode?.width == saved.width) &&
                (curMode?.height == saved.height) &&
                (curMode?.pixelWidth == saved.pixelWidth) &&
                (curMode?.pixelHeight == saved.pixelHeight) &&
                (saved.refreshRate == 0 || abs((curMode?.refreshRate ?? 0) - saved.refreshRate) <= 1.0)

            if !modeAlreadyMatches, let bestMode = Self.findBestDisplayMode(for: displayID, matching: saved) {
                CGConfigureDisplayWithDisplayMode(config, displayID, bestMode, nil)
            }
        }

        // 2c. Configure Display Origins (Arrangement & Main Display at 0,0)
        let sortedForOrigin = profile.displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return false
        }
        for saved in sortedForOrigin where saved.mirrorsUUID == nil {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
            CGConfigureDisplayOrigin(config, displayID, saved.originX, saved.originY)
        }

        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result == .success {
            lastRestoredDate = Date()
            logEvent("Applied setup '\(profile.name)' (Step 1: Layout & Mirroring).")
            // Step 3: After mirroring/unmirroring settles, enforce exact modes & origins in isolated transactions,
            // setting Master/Extended modes first (+0.7s) and Mirrored Slave modes (e.g. TV 60Hz) after (+1.4s & +2.8s)!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.enforceDisplayModesPass(for: profile)
            }
        } else {
            CGCancelDisplayConfiguration(config)
            if result.rawValue == 1014 {
                pauseWatchdogUntil = Date().addingTimeInterval(10.0)
                logEvent("Displays are asleep (code 1014) — retrying after wake.")
            } else {
                logEvent("Display configuration returned code \(result.rawValue).")
                // Still run the isolated per-display mode & mirroring pass in 0.7s in case a combined transaction was rejected
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    self?.enforceDisplayModesPass(for: profile)
                }
            }
        }

        // Refresh display snapshot after a short delay to reflect applied state.
        // ONLY restore app window positions if the desktop screens actually got switched around!
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.refreshCurrentDisplays()
            if didScreensSwitchAround && self.autoRestoreWindowPositions {
                self.restoreSavedWindowsForActiveProfile(
                    reason: "Screens switched around — restored displaced windows",
                    silentIfZero: true,
                    onlyMoveCrossScreenDisplaced: true
                )
            }
        }
        if didScreensSwitchAround {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
                guard let self, self.autoRestoreWindowPositions else { return }
                self.restoreSavedWindowsForActiveProfile(
                    reason: "Screens settled — restored displaced windows",
                    silentIfZero: true,
                    onlyMoveCrossScreenDisplaced: true
                )
            }
        }
    }

    // MARK: - App Window Position Snapshot & Restoration

    func refreshAccessibilityStatus() {
        let trusted = WindowPositionManager.isAccessibilityTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }
    }

    func requestAccessibilityPermission() {
        WindowPositionManager.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    /// Manually or automatically snapshots all open application window positions into the active setup.
    func captureWindowPositionsForActiveProfile(silent: Bool = false) {
        refreshAccessibilityStatus()
        guard let active = activeProfile,
              let idx = savedProfiles.firstIndex(where: { $0.id == active.id }) else {
            return
        }
        let currentWins = WindowPositionManager.captureCurrentWindows(displays: currentDisplays)
        guard !currentWins.isEmpty else {
            if !silent {
                logEvent("No open app windows found to snapshot.")
            }
            return
        }

        let existingWins = savedProfiles[idx].savedWindows ?? []
        let merged = WindowPositionManager.mergeSnapshots(existing: existingWins, current: currentWins)
        savedProfiles[idx].savedWindows = merged
        persistProfiles()

        if !silent {
            let screenCount = Set(currentWins.map { $0.displayUUID }).count
            logEvent("Saved \(currentWins.count) window position(s) across \(screenCount) screen(s) for '\(active.name)'.")
        }
    }

    /// Restores open application windows back to the displays and positions saved in the active setup.
    func restoreSavedWindowsForActiveProfile(
        onlyForBundleID: String? = nil,
        reason: String = "Manual window restore",
        silentIfZero: Bool = false,
        onlyMoveCrossScreenDisplaced: Bool = true
    ) {
        refreshAccessibilityStatus()
        guard let active = activeProfile,
              let savedWins = active.savedWindows,
              !savedWins.isEmpty else {
            if !silentIfZero {
                logEvent("No saved window positions for '\(activeProfile?.name ?? "active setup")' yet.")
            }
            return
        }

        let (movedCount, needsPermission) = WindowPositionManager.restoreWindows(
            savedWins,
            displays: currentDisplays,
            onlyForBundleID: onlyForBundleID,
            onlyMoveCrossScreenDisplaced: onlyMoveCrossScreenDisplaced
        )

        if needsPermission {
            if !silentIfZero {
                logEvent("Accessibility permission needed to move app windows across screens.")
                requestAccessibilityPermission()
            }
            return
        }

        if movedCount > 0 {
            logEvent("\(reason): Restored \(movedCount) app window(s) to their saved screens.")
        } else if !silentIfZero {
            logEvent("All open app windows are already on their saved screens.")
        }
    }

    private func recordStableWindowPositionsOnWatchdog() {
        guard let active = activeProfile,
              let idx = savedProfiles.firstIndex(where: { $0.id == active.id }) else {
            return
        }
        let currentWins = WindowPositionManager.captureCurrentWindows(displays: currentDisplays)
        guard !currentWins.isEmpty else { return }

        let existingWins = savedProfiles[idx].savedWindows ?? []
        let merged = WindowPositionManager.mergeSnapshots(existing: existingWins, current: currentWins)
        if !areWindowSnapshotsApproximatelyEqual(existingWins, merged) {
            savedProfiles[idx].savedWindows = merged
            persistProfiles()
        }
    }

    private func areWindowSnapshotsApproximatelyEqual(_ a: [SavedWindowPosition], _ b: [SavedWindowPosition]) -> Bool {
        guard a.count == b.count else { return false }
        for (w1, w2) in zip(a, b) {
            if w1.bundleIdentifier != w2.bundleIdentifier ||
               w1.windowNumber != w2.windowNumber ||
               w1.isFullScreen != w2.isFullScreen ||
               w1.displayUUID != w2.displayUUID ||
               w1.windowTitle != w2.windowTitle ||
               abs(w1.x - w2.x) > 10 ||
               abs(w1.y - w2.y) > 10 ||
               abs(w1.width - w2.width) > 14 ||
               abs(w1.height - w2.height) > 14 {
                return false
            }
        }
        return true
    }

    private func enforceDisplayModesPass(for profile: DisplayProfile) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &onlineIDs, &count) == .success else { return }

        var uuidToDisplayID: [String: CGDirectDisplayID] = [:]
        var hwToDisplayID: [String: CGDirectDisplayID] = [:]
        for id in onlineIDs {
            uuidToDisplayID[Self.uuidString(for: id)] = id
            hwToDisplayID[Self.hardwareID(for: id)] = id
        }

        func resolveID(_ saved: DisplayConfig) -> CGDirectDisplayID? {
            uuidToDisplayID[saved.uuid] ?? hwToDisplayID[saved.hardwareID]
        }

        let sortedForOrigin = profile.displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return false
        }

        // 1. Verify mirroring state first in its own dedicated transaction if any mirrored slave lost mirroring during wake
        var didFixMirror = false
        for saved in profile.displays where saved.mirrorsUUID != nil {
            guard let displayID = resolveID(saved),
                  let masterUUID = saved.mirrorsUUID,
                  let masterID = uuidToDisplayID[masterUUID] ?? profile.displays.first(where: { $0.uuid == masterUUID }).flatMap({ resolveID($0) }),
                  onlineIDs.contains(masterID) else {
                continue
            }
            if CGDisplayMirrorsDisplay(displayID) != masterID {
                var mConfigRef: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&mConfigRef) == .success, let mConfig = mConfigRef {
                    CGConfigureDisplayMirrorOfDisplay(mConfig, displayID, masterID)
                    if CGCompleteDisplayConfiguration(mConfig, .permanently) == .success {
                        didFixMirror = true
                        logEvent("Re-locked mirroring for '\(saved.name)'.")
                    } else {
                        CGCancelDisplayConfiguration(mConfig)
                    }
                }
            }
        }

        // 2. Verify origins for non-mirrored displays in a dedicated origin transaction
        var oConfigRef: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&oConfigRef) == .success, let oConfig = oConfigRef {
            var needsOriginFix = false
            for saved in sortedForOrigin where saved.mirrorsUUID == nil {
                guard let displayID = resolveID(saved) else { continue }
                let bounds = CGDisplayBounds(displayID)
                let curX = Int32(bounds.origin.x.rounded())
                let curY = Int32(bounds.origin.y.rounded())
                if abs(curX - saved.originX) > 1 || abs(curY - saved.originY) > 1 {
                    CGConfigureDisplayOrigin(oConfig, displayID, saved.originX, saved.originY)
                    needsOriginFix = true
                }
            }
            if needsOriginFix {
                _ = CGCompleteDisplayConfiguration(oConfig, .permanently)
            } else {
                CGCancelDisplayConfiguration(oConfig)
            }
        }

        // 3. Enforce display modes on NON-MIRRORED (Master & Extended) displays first, each in its own isolated transaction
        // so one display's mode quirk can never block another display!
        var didChangeMasterMode = didFixMirror
        for saved in sortedForOrigin where saved.mirrorsUUID == nil {
            guard let displayID = resolveID(saved) else { continue }
            let curMode = CGDisplayCopyDisplayMode(displayID)
            let curHz = curMode?.refreshRate ?? 0
            let curW = curMode?.width ?? 0
            let curH = curMode?.height ?? 0
            let curPxW = curMode?.pixelWidth ?? 0
            let curPxH = curMode?.pixelHeight ?? 0

            if abs(curHz - saved.refreshRate) > 1.0 || curW != saved.width || curH != saved.height || curPxW != saved.pixelWidth || curPxH != saved.pixelHeight {
                if let bestMode = Self.findBestDisplayMode(for: displayID, matching: saved) {
                    var dConfigRef: CGDisplayConfigRef?
                    if CGBeginDisplayConfiguration(&dConfigRef) == .success, let dConfig = dConfigRef {
                        CGConfigureDisplayWithDisplayMode(dConfig, displayID, bestMode, nil)
                        let res = CGCompleteDisplayConfiguration(dConfig, .permanently)
                        if res == .success {
                            didChangeMasterMode = true
                        } else {
                            CGCancelDisplayConfiguration(dConfig)
                        }
                    }
                }
            }
        }

        // 4. Enforce display modes on MIRRORED SLAVE displays (e.g. LG TV SSCR2 @ 60Hz).
        // Because macOS CoreDisplay automatically resets a mirrored slave to 30Hz ~120ms after a master mode/mirror change,
        // we apply the slave mode in its own transaction (immediately if master didn't change, or +0.55s after master changed,
        // plus a follow-up lock check at +1.4s).
        let applyMirroredSlaveModes: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            for saved in profile.displays where saved.mirrorsUUID != nil {
                guard let displayID = self.onlineDisplayID(for: saved.uuid, hardwareID: saved.hardwareID) else { continue }
                let curMode = CGDisplayCopyDisplayMode(displayID)
                let curHz = curMode?.refreshRate ?? 0
                let curW = curMode?.width ?? 0
                let curH = curMode?.height ?? 0
                let curPxW = curMode?.pixelWidth ?? 0
                let curPxH = curMode?.pixelHeight ?? 0

                if abs(curHz - saved.refreshRate) > 1.0 || curW != saved.width || curH != saved.height || curPxW != saved.pixelWidth || curPxH != saved.pixelHeight {
                    if let bestMode = Self.findBestDisplayMode(for: displayID, matching: saved) {
                        var sConfigRef: CGDisplayConfigRef?
                        if CGBeginDisplayConfiguration(&sConfigRef) == .success, let sConfig = sConfigRef {
                            CGConfigureDisplayWithDisplayMode(sConfig, displayID, bestMode, nil)
                            let res = CGCompleteDisplayConfiguration(sConfig, .permanently)
                            if res == .success {
                                self.logEvent("Locked '\(saved.name)' to \(Int(bestMode.refreshRate.rounded()))Hz (\(bestMode.width)×\(bestMode.height)).")
                            } else {
                                CGCancelDisplayConfiguration(sConfig)
                            }
                        }
                    }
                }
            }
            self.refreshCurrentDisplays()
        }

        if didChangeMasterMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                applyMirroredSlaveModes()
            }
        } else {
            applyMirroredSlaveModes()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            applyMirroredSlaveModes()
        }
    }

    private static func findBestDisplayMode(for displayID: CGDirectDisplayID, matching target: DisplayConfig) -> CGDisplayMode? {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        // Helper: true when the mode is a native hardware mode (not a 0x200000 Simulscan mirror-capped 30Hz mode)
        func isNativeNonSimulscan(_ m: CGDisplayMode) -> Bool {
            (m.ioFlags & 0x200000) == 0
        }

        // 1. Try exact ioDisplayModeID + dimensions + refresh rate match (preferring non-Simulscan if target is >= 59Hz)
        if target.ioDisplayModeID != 0,
           let exact = modes.first(where: {
               $0.ioDisplayModeID == target.ioDisplayModeID &&
               $0.width == target.width &&
               $0.height == target.height &&
               $0.pixelWidth == target.pixelWidth &&
               $0.pixelHeight == target.pixelHeight &&
               (target.refreshRate == 0 || abs($0.refreshRate - target.refreshRate) <= 1.5)
           }) {
            return exact
        }

        // 2. Match logical width/height AND target refresh rate first (within 1.5Hz), preferring native non-Simulscan modes
        // and matching pixelWidth/pixelHeight. This prevents a mirrored TV from getting trapped in 5120x2880@30Hz when 60Hz is 2560x1440!
        let logicalModes = modes.filter {
            $0.width == target.width &&
            $0.height == target.height &&
            $0.isUsableForDesktopGUI()
        }

        if target.refreshRate > 0 {
            let hzMatched = logicalModes.filter { abs($0.refreshRate - target.refreshRate) <= 1.5 }
            if !hzMatched.isEmpty {
                let sortedHz = hzMatched.sorted { a, b in
                    let aExactPx = (a.pixelWidth == target.pixelWidth && a.pixelHeight == target.pixelHeight)
                    let bExactPx = (b.pixelWidth == target.pixelWidth && b.pixelHeight == target.pixelHeight)
                    if aExactPx != bExactPx { return aExactPx }
                    let aNative = isNativeNonSimulscan(a)
                    let bNative = isNativeNonSimulscan(b)
                    if aNative != bNative { return aNative }
                    return abs(a.refreshRate - target.refreshRate) < abs(b.refreshRate - target.refreshRate)
                }
                if let bestHz = sortedHz.first {
                    return bestHz
                }
            }
        }

        // 3. Fallback: match logical width/height and pixel width/height with closest refresh rate
        let pxCandidates = logicalModes.filter {
            $0.pixelWidth == target.pixelWidth &&
            $0.pixelHeight == target.pixelHeight
        }
        if let best = pxCandidates.min(by: { abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate) }) {
            return best
        }

        // 4. Final fallback: match logical width and height and closest refresh rate
        return logicalModes.min(by: { abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate) })
    }

    private static func setRotation(_ degree: Int32, for displayID: CGDirectDisplayID) {
        guard let mgrClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return }
        let mgr = mgrClass.init()
        let dispSel = NSSelectorFromString("displayWithID:")
        guard mgr.responds(to: dispSel) else { return }

        typealias DisplayWithIDFunc = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
        let imp = mgr.method(for: dispSel)
        let fn = unsafeBitCast(imp, to: DisplayWithIDFunc.self)
        guard let mpDisplay = fn(mgr, dispSel, Int32(displayID)) else { return }

        let setRotSel = NSSelectorFromString("setOrientation:")
        guard mpDisplay.responds(to: setRotSel) else { return }
        typealias SetOrientationFunc = @convention(c) (AnyObject, Selector, Int32) -> Void
        let rotImp = mpDisplay.method(for: setRotSel)
        let rotFn = unsafeBitCast(rotImp, to: SetOrientationFunc.self)
        rotFn(mpDisplay, setRotSel, degree)
    }

    // MARK: - Querying Available Display Modes for the Editor

    private func onlineDisplayID(for uuid: String, hardwareID: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &onlineIDs, &count) == .success else { return nil }
        for id in onlineIDs {
            if Self.uuidString(for: id) == uuid || Self.hardwareID(for: id) == hardwareID {
                return id
            }
        }
        return nil
    }

    func availableResolutionOptions(for disp: DisplayConfig) -> [DisplayResolutionOption] {
        var optionsSet = Set<DisplayResolutionOption>()
        let currentOption = DisplayResolutionOption(
            width: disp.width,
            height: disp.height,
            pixelWidth: disp.pixelWidth,
            pixelHeight: disp.pixelHeight
        )
        optionsSet.insert(currentOption)

        if let displayID = onlineDisplayID(for: disp.uuid, hardwareID: disp.hardwareID) {
            let cfOpts: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(displayID, cfOpts) as? [CGDisplayMode] {
                for m in modes where m.isUsableForDesktopGUI() && m.width >= 1280 && m.height >= 720 {
                    optionsSet.insert(
                        DisplayResolutionOption(
                            width: m.width,
                            height: m.height,
                            pixelWidth: m.pixelWidth,
                            pixelHeight: m.pixelHeight
                        )
                    )
                }
            }
        }

        return optionsSet.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI && !b.isHiDPI }
            return a.pixelWidth > b.pixelWidth
        }
    }

    func availableRefreshRates(for disp: DisplayConfig) -> [Double] {
        var rates = Set<Int>()
        if disp.refreshRate > 0 {
            rates.insert(Int(disp.refreshRate.rounded()))
        }

        if let displayID = onlineDisplayID(for: disp.uuid, hardwareID: disp.hardwareID) {
            let cfOpts: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(displayID, cfOpts) as? [CGDisplayMode] {
                let matching = modes.filter {
                    $0.isUsableForDesktopGUI() &&
                    $0.width == disp.width &&
                    $0.height == disp.height &&
                    $0.pixelWidth == disp.pixelWidth &&
                    $0.pixelHeight == disp.pixelHeight
                }
                let pool = matching.isEmpty ? modes.filter { $0.isUsableForDesktopGUI() && $0.width == disp.width && $0.height == disp.height } : matching
                for m in pool {
                    let hz = Int(m.refreshRate.rounded())
                    if hz > 0 {
                        rates.insert(hz)
                    }
                }
            }
        }

        if rates.isEmpty {
            rates = [60]
        }
        return rates.sorted(by: >).map { Double($0) }
    }

    // MARK: - Profile Persistence (Up to 5 Custom Setups)

    func beginCreatingNewProfile(fromEdited: Bool = false) {
        guard canAddMoreProfiles else {
            logEvent("Maximum of \(Self.maxSavedProfiles) custom setups reached. Update or delete an existing setup first.")
            return
        }
        if !fromEdited {
            refreshCurrentDisplays()
        }
        isSavingEditedAsNew = fromEdited
        newProfileName = DisplayProfile.suggestedName(for: fromEdited ? editingDisplays : currentDisplays)
        isCreatingProfile = true
    }

    func saveCurrentAsProfile(name: String) {
        guard canAddMoreProfiles else {
            logEvent("Maximum of \(Self.maxSavedProfiles) custom setups reached.")
            return
        }
        refreshCurrentDisplays()
        let suggested = DisplayProfile.suggestedName(for: currentDisplays)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? suggested : trimmed

        let wins = WindowPositionManager.captureCurrentWindows(displays: currentDisplays)
        let profile = DisplayProfile(
            name: finalName,
            createdAt: Date(),
            updatedAt: Date(),
            displays: currentDisplays,
            savedWindows: wins.isEmpty ? nil : wins
        )
        savedProfiles.append(profile)
        activeProfileID = profile.id
        persistProfiles()
        logEvent("Saved display setup '\(finalName)' (\(wins.count) app windows recorded).")
    }

    func saveEditedLayoutAsNewProfile(name: String) {
        guard isEditingLayout else { return }
        guard canAddMoreProfiles else {
            logEvent("Maximum of \(Self.maxSavedProfiles) setups reached.")
            return
        }
        let updatedDisplays = editingDisplays
        let suggested = DisplayProfile.suggestedName(for: updatedDisplays)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? suggested : trimmed

        showAlignmentGuide = false
        isEditingLayout = false
        isCreatingProfile = false
        isSavingEditedAsNew = false
        draggingDisplayUUID = nil
        dragTranslation = .zero

        let profile = DisplayProfile(
            name: finalName,
            createdAt: Date(),
            updatedAt: Date(),
            displays: updatedDisplays
        )
        savedProfiles.append(profile)
        activeProfileID = profile.id
        persistProfiles()
        logEvent("Saved new setup '\(finalName)' and applying...")
        applyProfile(profile)
    }

    func updateProfile(_ profile: DisplayProfile, withCurrentDisplays: Bool = true) {
        refreshCurrentDisplays()
        guard let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if withCurrentDisplays {
            let previousDisplays = savedProfiles[idx].displays
            var sanitized = currentDisplays
            // Never accidentally overwrite a display's saved target refresh rate with a lower drifted refresh rate
            // when clicking Update Active (explicit refresh rate changes are made in Edit Layout & Mirroring).
            for i in sanitized.indices {
                if let prev = previousDisplays.first(where: { $0.uuid == sanitized[i].uuid || $0.hardwareID == sanitized[i].hardwareID }),
                   sanitized[i].refreshRate > 0,
                   sanitized[i].refreshRate < prev.refreshRate - 1.0,
                   sanitized[i].width == prev.width,
                   sanitized[i].height == prev.height {
                    sanitized[i].refreshRate = prev.refreshRate
                    sanitized[i].pixelWidth = prev.pixelWidth
                    sanitized[i].pixelHeight = prev.pixelHeight
                    sanitized[i].ioDisplayModeID = prev.ioDisplayModeID
                }
            }
            savedProfiles[idx].displays = sanitized
            let wins = WindowPositionManager.captureCurrentWindows(displays: currentDisplays)
            if !wins.isEmpty {
                savedProfiles[idx].savedWindows = WindowPositionManager.mergeSnapshots(
                    existing: savedProfiles[idx].savedWindows ?? [],
                    current: wins
                )
            }
        }
        savedProfiles[idx].updatedAt = Date()
        persistProfiles()
        logEvent("Updated setup '\(savedProfiles[idx].name)' with current layout & window positions.")
    }

    func renameProfile(_ profile: DisplayProfile, to newName: String) {
        guard let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? savedProfiles[idx].layoutSummary : trimmed
        savedProfiles[idx].name = finalName
        savedProfiles[idx].updatedAt = Date()
        renamingProfileID = nil
        renamingProfileText = ""
        persistProfiles()
        logEvent("Renamed setup to '\(finalName)'.")
    }

    // MARK: - Interactive Layout Editor

    func beginEditingLayout(from profile: DisplayProfile? = nil) {
        refreshCurrentDisplays()
        lastEditorInteractionDate = Date()
        previewingProfileID = nil
        isCreatingProfile = false
        isSavingEditedAsNew = false
        if let profile {
            editingDisplays = profile.displays
        } else if let active = activeProfile {
            // Start from the active profile's intended settings for all connected displays so a drifted 30Hz TV
            // isn't accidentally copied into the editor when tweaking arrangement!
            var merged: [DisplayConfig] = []
            for cur in currentDisplays {
                if let saved = active.displays.first(where: { $0.uuid == cur.uuid || $0.hardwareID == cur.hardwareID }) {
                    merged.append(saved)
                } else {
                    merged.append(cur)
                }
            }
            editingDisplays = merged.isEmpty ? currentDisplays : merged
        } else {
            editingDisplays = currentDisplays
        }
        draggingDisplayUUID = nil
        dragTranslation = .zero
        // Default selection: prefer any mirrored display so the user immediately sees how to unmirror it, else Main display
        if let mirrored = editingDisplays.first(where: { $0.mirrorsUUID != nil }) {
            selectedEditingDisplayUUID = mirrored.uuid
        } else {
            selectedEditingDisplayUUID = editingDisplays.first(where: { $0.isMain })?.uuid ?? editingDisplays.first?.uuid
        }
        isEditingLayout = true
    }

    func cancelEditingLayout() {
        showAlignmentGuide = false
        isEditingLayout = false
        isCreatingProfile = false
        isSavingEditedAsNew = false
        draggingDisplayUUID = nil
        dragTranslation = .zero
    }

    func currentRole(for disp: DisplayConfig) -> DisplayRoleSelection {
        if let masterUUID = disp.mirrorsUUID {
            return .mirror(masterUUID: masterUUID)
        } else if disp.isMain {
            return .main
        } else {
            return .extended
        }
    }

    /// Unmirrors all currently mirrored displays in the editor and places them side-by-side as independent extended screens.
    func unmirrorAllInEditor() {
        var maxX = editingDisplays
            .filter { $0.mirrorsUUID == nil }
            .map { $0.originX + Int32($0.width) }
            .max() ?? 0

        for i in editingDisplays.indices {
            if editingDisplays[i].mirrorsUUID != nil {
                editingDisplays[i].mirrorsUUID = nil
                editingDisplays[i].isMain = false
                editingDisplays[i].originX = maxX
                editingDisplays[i].originY = 0
                maxX += Int32(editingDisplays[i].width)
            }
        }
        normalizeEditorOrigins()
    }

    /// Sets the role of a display in the editor: Main Display, Extended Display (stops mirroring!), or Mirror of another display.
    func setEditingDisplayRole(uuid: String, role: DisplayRoleSelection) {
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }

        switch role {
        case .extended:
            let wasMirrored = (editingDisplays[idx].mirrorsUUID != nil)
            let wasMain = editingDisplays[idx].isMain
            editingDisplays[idx].mirrorsUUID = nil

            if wasMirrored {
                // Place freshly unmirrored display cleanly at the right edge of existing non-mirrored displays
                let maxX = editingDisplays
                    .enumerated()
                    .filter { $0.offset != idx && $0.element.mirrorsUUID == nil }
                    .map { $0.element.originX + Int32($0.element.width) }
                    .max() ?? 0
                editingDisplays[idx].isMain = false
                editingDisplays[idx].originX = maxX
                editingDisplays[idx].originY = 0
            } else if wasMain {
                // If the user switched the Main display to Extended, promote another non-mirrored display to Main
                if let otherIdx = editingDisplays.indices.first(where: { $0 != idx && editingDisplays[$0].mirrorsUUID == nil }) {
                    editingDisplays[idx].isMain = false
                    editingDisplays[otherIdx].isMain = true
                }
            }
            normalizeEditorOrigins()

        case .main:
            let wasMirrored = (editingDisplays[idx].mirrorsUUID != nil)
            editingDisplays[idx].mirrorsUUID = nil
            if wasMirrored {
                let maxX = editingDisplays
                    .enumerated()
                    .filter { $0.offset != idx && $0.element.mirrorsUUID == nil }
                    .map { $0.element.originX + Int32($0.element.width) }
                    .max() ?? 0
                editingDisplays[idx].originX = maxX
                editingDisplays[idx].originY = 0
            }
            for i in editingDisplays.indices {
                editingDisplays[i].isMain = (i == idx)
            }
            normalizeEditorOrigins()

        case .mirror(let masterUUID):
            guard masterUUID != uuid,
                  let masterIdx = editingDisplays.firstIndex(where: { $0.uuid == masterUUID }) else {
                return
            }
            // Ensure the target master display is not mirroring anything itself
            if editingDisplays[masterIdx].mirrorsUUID != nil {
                editingDisplays[masterIdx].mirrorsUUID = nil
            }
            // If this display was Main, transfer Main status to the master display
            if editingDisplays[idx].isMain {
                editingDisplays[idx].isMain = false
                editingDisplays[masterIdx].isMain = true
            }
            // Redirect any third display that was mirroring `uuid` so it mirrors `masterUUID` instead
            for i in editingDisplays.indices where editingDisplays[i].mirrorsUUID == uuid {
                editingDisplays[i].mirrorsUUID = masterUUID
            }
            editingDisplays[idx].mirrorsUUID = masterUUID
            editingDisplays[idx].originX = editingDisplays[masterIdx].originX
            editingDisplays[idx].originY = editingDisplays[masterIdx].originY
            normalizeEditorOrigins(packHorizontalGaps: true)
        }
    }

    func setEditingDisplayResolution(uuid: String, option: DisplayResolutionOption) {
        lastEditorInteractionDate = Date()
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        editingDisplays[idx].width = option.width
        editingDisplays[idx].height = option.height
        editingDisplays[idx].pixelWidth = option.pixelWidth
        editingDisplays[idx].pixelHeight = option.pixelHeight

        // Ensure refreshRate is valid for the new resolution
        let rates = availableRefreshRates(for: editingDisplays[idx])
        if let currentHz = rates.first(where: { abs($0 - editingDisplays[idx].refreshRate) <= 1.0 }) {
            editingDisplays[idx].refreshRate = currentHz
        } else if let maxHz = rates.first {
            editingDisplays[idx].refreshRate = maxHz
        }

        if let displayID = onlineDisplayID(for: editingDisplays[idx].uuid, hardwareID: editingDisplays[idx].hardwareID),
           let bestMode = Self.findBestDisplayMode(for: displayID, matching: editingDisplays[idx]) {
            editingDisplays[idx].ioDisplayModeID = bestMode.ioDisplayModeID
            editingDisplays[idx].pixelWidth = bestMode.pixelWidth
            editingDisplays[idx].pixelHeight = bestMode.pixelHeight
        }

        normalizeEditorOrigins(packHorizontalGaps: true)
    }

    func setEditingDisplayRefreshRate(uuid: String, hz: Double) {
        lastEditorInteractionDate = Date()
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        editingDisplays[idx].refreshRate = hz
        if let displayID = onlineDisplayID(for: editingDisplays[idx].uuid, hardwareID: editingDisplays[idx].hardwareID),
           let bestMode = Self.findBestDisplayMode(for: displayID, matching: editingDisplays[idx]) {
            editingDisplays[idx].ioDisplayModeID = bestMode.ioDisplayModeID
            editingDisplays[idx].pixelWidth = bestMode.pixelWidth
            editingDisplays[idx].pixelHeight = bestMode.pixelHeight
        }
    }

    func setEditingDisplayRotation(uuid: String, rotation: Double) {
        lastEditorInteractionDate = Date()
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        let oldRot = Int(editingDisplays[idx].rotation.rounded()) % 360
        let newRot = Int(rotation.rounded()) % 360
        let wasPortrait = (oldRot == 90 || oldRot == 270)
        let isPortrait = (newRot == 90 || newRot == 270)

        var disp = editingDisplays[idx]
        disp.rotation = rotation
        if wasPortrait != isPortrait {
            let oldW = disp.width
            disp.width = disp.height
            disp.height = oldW
            let oldPxW = disp.pixelWidth
            disp.pixelWidth = disp.pixelHeight
            disp.pixelHeight = oldPxW
        }
        editingDisplays[idx] = disp
        if wasPortrait != isPortrait {
            normalizeEditorOrigins(packHorizontalGaps: true)
        }
    }

    /// Moves an extended display directly to the left or right of the Main display in 1 click (preserving any calibrated vertical height offset).
    func placeEditingDisplayHorizontally(uuid: String, placeOnLeft: Bool) {
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        if editingDisplays[idx].mirrorsUUID != nil {
            editingDisplays[idx].mirrorsUUID = nil
        }
        guard !editingDisplays[idx].isMain else { return }

        if placeOnLeft {
            let minX = editingDisplays
                .enumerated()
                .filter { $0.offset != idx && $0.element.mirrorsUUID == nil }
                .map { $0.element.originX }
                .min() ?? 0
            editingDisplays[idx].originX = minX - Int32(editingDisplays[idx].width)
        } else {
            let maxX = editingDisplays
                .enumerated()
                .filter { $0.offset != idx && $0.element.mirrorsUUID == nil }
                .map { $0.element.originX + Int32($0.element.width) }
                .max() ?? 0
            editingDisplays[idx].originX = maxX
        }
        normalizeEditorOrigins(packHorizontalGaps: true)
    }

    /// Vertical screen/window alignment offset relative to the Main display:
    /// Positive (`+Higher ↑`) = pressing Up Arrow moves windows & alignment line UP on this monitor (`originY > 0`)
    /// Negative (`-Lower ↓`) = pressing Down Arrow moves windows & alignment line DOWN on this monitor (`originY < 0`)
    func deskHeightOffset(for disp: DisplayConfig) -> Int {
        let mainY = editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })?.originY ?? 0
        return Int(disp.originY - mainY)
    }

    func setEditingDisplayDeskHeightOffset(uuid: String, higherByPixels: Int) {
        lastEditorInteractionDate = Date()
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        guard !editingDisplays[idx].isMain && editingDisplays[idx].mirrorsUUID == nil else { return }
        let mainY = editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })?.originY ?? 0
        let clamped = min(max(higherByPixels, -600), 600)
        editingDisplays[idx].originY = mainY + Int32(clamped)
        normalizeEditorOrigins()
    }

    func nudgeEditingDisplayDeskHeight(uuid: String, deltaHigherPixels: Int) {
        guard let disp = editingDisplays.first(where: { $0.uuid == uuid }) else { return }
        let current = deskHeightOffset(for: disp)
        setEditingDisplayDeskHeightOffset(uuid: uuid, higherByPixels: current + deltaHigherPixels)
    }

    /// Moves the active extended display in the layout editor using keyboard arrow keys:
    /// - Up / Down (`dyHigher`): nudges vertical desk height by 1px (or 10px with Shift)
    /// - Left / Right (`dx`): moves Left / Right of Main (or nudges horizontal offset when stacked vertically)
    func handleEditorArrowKey(dx: Int, dyHigher: Int) {
        guard isEditingLayout && arrowKeyAlignmentEnabled else { return }

        let targetUUID: String
        if let sel = selectedEditingDisplay, !sel.isMain && sel.mirrorsUUID == nil {
            targetUUID = sel.uuid
        } else if let ext = editingDisplays.first(where: { !$0.isMain && $0.mirrorsUUID == nil }) {
            selectedEditingDisplayUUID = ext.uuid
            targetUUID = ext.uuid
        } else {
            return
        }

        if dyHigher != 0 {
            nudgeEditingDisplayDeskHeight(uuid: targetUUID, deltaHigherPixels: dyHigher)
        }

        if dx != 0, let idx = editingDisplays.firstIndex(where: { $0.uuid == targetUUID }) {
            let disp = editingDisplays[idx]
            let mainH = editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })?.height ?? 1440
            let isStackedVertically = abs(Int(disp.originY)) >= min(disp.height, mainH) - 50
            if isStackedVertically {
                editingDisplays[idx].originX += Int32(dx)
                normalizeEditorOrigins()
            } else {
                placeEditingDisplayHorizontally(uuid: targetUUID, placeOnLeft: dx < 0)
            }
        }
    }

    func swapLeftRightInEditor() {
        let nonMirrored = editingDisplays
            .filter { $0.mirrorsUUID == nil }
            .sorted { $0.originX < $1.originX }
        guard nonMirrored.count >= 2 else { return }

        // Reverse the horizontal order of non-mirrored displays while preserving calibrated vertical height offsets
        let reversed = Array(nonMirrored.reversed())
        var currentX: Int32 = 0
        var newXByUUID: [String: Int32] = [:]
        for disp in reversed {
            newXByUUID[disp.uuid] = currentX
            currentX += Int32(disp.width)
        }

        for i in editingDisplays.indices {
            if let nx = newXByUUID[editingDisplays[i].uuid] {
                editingDisplays[i].originX = nx
            }
        }
        normalizeEditorOrigins()
    }

    private func normalizeEditorOrigins(packHorizontalGaps: Bool = false) {
        // Ensure exactly one non-mirrored display is marked isMain
        if !editingDisplays.contains(where: { $0.isMain && $0.mirrorsUUID == nil }) {
            if let firstNonMirroredIdx = editingDisplays.indices.first(where: { editingDisplays[$0].mirrorsUUID == nil }) {
                editingDisplays[firstNonMirroredIdx].isMain = true
            }
        }

        if packHorizontalGaps {
            // Sort non-mirrored displays left-to-right and pack them edge-to-edge
            let sortedIndices = editingDisplays.indices
                .filter { editingDisplays[$0].mirrorsUUID == nil }
                .sorted { a, b in
                    if editingDisplays[a].originX != editingDisplays[b].originX {
                        return editingDisplays[a].originX < editingDisplays[b].originX
                    }
                    return editingDisplays[a].name < editingDisplays[b].name
                }
            var runningX: Int32 = 0
            for idx in sortedIndices {
                editingDisplays[idx].originX = runningX
                runningX += Int32(editingDisplays[idx].width)
            }
        }

        let mainX = editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })?.originX ?? 0
        let mainY = editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })?.originY ?? 0

        for i in editingDisplays.indices {
            if editingDisplays[i].mirrorsUUID == nil {
                editingDisplays[i].originX -= mainX
                editingDisplays[i].originY -= mainY
            }
        }

        for i in editingDisplays.indices {
            if let masterUUID = editingDisplays[i].mirrorsUUID,
               let master = editingDisplays.first(where: { $0.uuid == masterUUID }) {
                editingDisplays[i].originX = master.originX
                editingDisplays[i].originY = master.originY
            }
        }
    }

    func commitDisplayDrag(uuid: String, deltaDisplayX: CGFloat, deltaDisplayY: CGFloat) {
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        var moved = editingDisplays[idx]
        let rawX = CGFloat(moved.originX) + deltaDisplayX
        let rawY = CGFloat(moved.originY) + deltaDisplayY

        // Snap horizontally to adjacent edges so there are no cursor dead-zones,
        // while preserving fine vertical height offsets (only snapping Y flush within 16px!).
        let others = editingDisplays.filter { $0.mirrorsUUID == nil && $0.uuid != uuid }
        var bestX = rawX
        var bestY = rawY
        let snapXThreshold: CGFloat = 600
        let snapYFlushThreshold: CGFloat = 16

        for other in others {
            let ox = CGFloat(other.originX)
            let oy = CGFloat(other.originY)
            let ow = CGFloat(other.width)
            let oh = CGFloat(other.height)
            let mw = CGFloat(moved.width)
            let mh = CGFloat(moved.height)

            if abs((rawX + mw) - ox) < snapXThreshold {
                bestX = ox - mw
                if abs(rawY - oy) < snapYFlushThreshold { bestY = oy }
                bestY = min(max(bestY, oy - mh + 200), oy + oh - 200)
            } else if abs(rawX - (ox + ow)) < snapXThreshold {
                bestX = ox + ow
                if abs(rawY - oy) < snapYFlushThreshold { bestY = oy }
                bestY = min(max(bestY, oy - mh + 200), oy + oh - 200)
            } else if abs((rawY + mh) - oy) < 300 {
                bestY = oy - mh
                if abs(rawX - ox) < snapXThreshold { bestX = ox }
            } else if abs(rawY - (oy + oh)) < 300 {
                bestY = oy + oh
                if abs(rawX - ox) < snapXThreshold { bestX = ox }
            }
        }

        moved.originX = Int32(bestX.rounded())
        moved.originY = Int32(bestY.rounded())
        editingDisplays[idx] = moved
        normalizeEditorOrigins()
    }

    func saveAndApplyEditedLayout() {
        guard isEditingLayout else { return }
        let updatedDisplays = editingDisplays
        showAlignmentGuide = false
        isEditingLayout = false
        isCreatingProfile = false
        isSavingEditedAsNew = false
        draggingDisplayUUID = nil
        dragTranslation = .zero

        if let active = activeProfile,
           let idx = savedProfiles.firstIndex(where: { $0.id == active.id }) {
            savedProfiles[idx].displays = updatedDisplays
            savedProfiles[idx].updatedAt = Date()
            persistProfiles()
            logEvent("Updated '\(savedProfiles[idx].name)' and applying layout...")
            applyProfile(savedProfiles[idx])
        } else {
            let suggested = DisplayProfile.suggestedName(for: updatedDisplays)
            let profile = DisplayProfile(
                name: suggested,
                createdAt: Date(),
                updatedAt: Date(),
                displays: updatedDisplays
            )
            savedProfiles.append(profile)
            activeProfileID = profile.id
            persistProfiles()
            logEvent("Saved setup as '\(suggested)' and applying...")
            applyProfile(profile)
        }

        // Re-record window coordinates once the updated display origins have settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            self.refreshCurrentDisplays()
            self.captureWindowPositionsForActiveProfile(silent: true)
        }
    }

    func deleteProfile(_ profile: DisplayProfile) {
        savedProfiles.removeAll { $0.id == profile.id }
        if previewingProfileID == profile.id {
            previewingProfileID = nil
        }
        if activeProfileID == profile.id {
            activeProfileID = savedProfiles.first?.id
        }
        persistProfiles()
        logEvent("Deleted setup '\(profile.name)'.")
    }

    private func persistProfiles() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(savedProfiles)
            try data.write(to: storageURL, options: .atomic)
            storageFileModDate = (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.modificationDate] as? Date) ?? Date()
        } catch {
            logEvent("Failed to save profiles: \(error.localizedDescription)")
        }
    }

    private func loadProfiles() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            savedProfiles = try decoder.decode([DisplayProfile].self, from: data)
            storageFileModDate = (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.modificationDate] as? Date) ?? Date()
        } catch {
            logEvent("Failed to load profiles: \(error.localizedDescription)")
        }
    }

    private static func defaultSeededProfiles() -> [DisplayProfile] {
        let displays = [
            DisplayConfig(
                uuid: "F400DB1E-B756-48BA-8941-DF947C4931F9",
                hardwareID: "ext-1e6d-5c7d-0002033d",
                name: "LG ULTRAGEAR+",
                isMain: true,
                originX: 0,
                originY: 0,
                width: 2560,
                height: 1440,
                pixelWidth: 2560,
                pixelHeight: 1440,
                refreshRate: 240,
                rotation: 0,
                mirrorsUUID: nil,
                ioDisplayModeID: 91
            ),
            DisplayConfig(
                uuid: "8574B588-0982-4ADB-B482-F118D4112E16",
                hardwareID: "ext-1e6d-c0c8-01010101",
                name: "LG TV SSCR2",
                isMain: false,
                originX: 0,
                originY: 0,
                width: 2560,
                height: 1440,
                pixelWidth: 2560,
                pixelHeight: 1440,
                refreshRate: 60,
                rotation: 0,
                mirrorsUUID: "F400DB1E-B756-48BA-8941-DF947C4931F9",
                ioDisplayModeID: 82
            ),
            DisplayConfig(
                uuid: "19F675CB-30A2-4692-AAC0-62BF060285B4",
                hardwareID: "ext-1e6d-5bb3-0002a63c",
                name: "LG ULTRAGEAR",
                isMain: false,
                originX: -2560,
                originY: 0,
                width: 2560,
                height: 1440,
                pixelWidth: 2560,
                pixelHeight: 1440,
                refreshRate: 72,
                rotation: 0,
                mirrorsUUID: nil,
                ioDisplayModeID: 50
            )
        ]
        return [
            DisplayProfile(
                id: UUID(uuidString: "5B505EC3-4836-4D77-B8AF-7E519EAB2159") ?? UUID(),
                name: DisplayProfile.suggestedName(for: displays),
                createdAt: Date(),
                updatedAt: Date(),
                displays: displays
            )
        ]
    }
}
