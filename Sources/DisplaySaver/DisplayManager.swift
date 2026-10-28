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
    @Published var statusMessage: String = "Ready"
    @Published var lastRestoredDate: Date?
    @Published var isApplying: Bool = false
    @Published var eventLog: [String] = []
    @Published var isCreatingProfile: Bool = false
    @Published var isSavingEditedAsNew: Bool = false
    @Published var newProfileName: String = ""
    @Published var showActivityLog: Bool = false
    @Published var isEditingLayout: Bool = false
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
    private var areSystemScreensAsleep: Bool = false
    private var pauseWatchdogAfterSleepError: Bool = false
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
                self?.pauseWatchdogAfterSleepError = false
                self?.logEvent("System woke from sleep — verifying display layout...")
                self?.scheduleCheckAndRestore(delay: 2.0)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.areSystemScreensAsleep = false
                self?.pauseWatchdogAfterSleepError = false
                self?.logEvent("Screens woke — verifying display layout...")
                self?.scheduleCheckAndRestore(delay: 1.5)
            }
        }

        // Also run a lightweight periodic watchdog every 15 seconds in case a monitor silently shifts
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.periodicWatchdogCheck()
            }
        }
    }

    func handleDisplayReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !areSystemScreensAsleep else { return }
        logEvent("CGReconfig display=\(display) flags=0x\(String(flags.rawValue, radix: 16))")
        // Keep main/monitor displays awake during HDMI/CEC hotplug transitions (e.g. when turning a mirrored TV on or off)
        wakeMainDisplayIfNeeded()
        if flags.contains(.beginConfigurationFlag) {
            return
        }
        pauseWatchdogAfterSleepError = false
        refreshCurrentDisplays()
        guard Date() > suppressCallbackUntil else { return }
        scheduleCheckAndRestore(delay: 0.5)
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
        guard !areSystemScreensAsleep, !pauseWatchdogAfterSleepError else { return }
        reloadProfilesIfChangedOnDisk()
        refreshCurrentDisplays()
        guard autoEnforceLayout, !isApplying, !isEditingLayout, Date() > suppressCallbackUntil else { return }
        checkAndRestoreIfNeeded(reason: "Watchdog check")
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
        guard !areSystemScreensAsleep, !pauseWatchdogAfterSleepError else { return }

        // Never attempt to reconfigure displays while any display is asleep!
        // Calling CGCompleteDisplayConfiguration while screens are asleep blocks for 10s and returns error 1014.
        var onlineCount: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &onlineCount) == .success, onlineCount > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
            if CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount) == .success {
                if ids.contains(where: { CGDisplayIsAsleep($0) != 0 }) {
                    return
                }
            }
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
            // Step 3: Transaction 2 — After mirroring/unmirroring settles (0.8s), enforce exact modes & origins on all displays!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.enforceDisplayModesPass(for: profile)
            }
        } else {
            CGCancelDisplayConfiguration(config)
            if result.rawValue == 1014 {
                pauseWatchdogAfterSleepError = true
                logEvent("Displays are asleep (code 1014) — pausing watchdog until wake.")
            } else {
                logEvent("Display configuration returned code \(result.rawValue).")
            }
        }

        // Refresh display snapshot after a short delay to reflect applied state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshCurrentDisplays()
        }
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

        var needsSecondPass = false
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return }

        let sortedForOrigin = profile.displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return false
        }

        for saved in sortedForOrigin {
            guard let displayID = uuidToDisplayID[saved.uuid] ?? hwToDisplayID[saved.hardwareID] else { continue }

            // Check display mode & refresh rate
            let curMode = CGDisplayCopyDisplayMode(displayID)
            let curHz = curMode?.refreshRate ?? 0
            let curW = curMode?.width ?? 0
            let curH = curMode?.height ?? 0
            let curPxW = curMode?.pixelWidth ?? 0
            let curPxH = curMode?.pixelHeight ?? 0

            if abs(curHz - saved.refreshRate) > 1.0 || curW != saved.width || curH != saved.height || curPxW != saved.pixelWidth || curPxH != saved.pixelHeight {
                if let bestMode = Self.findBestDisplayMode(for: displayID, matching: saved) {
                    CGConfigureDisplayWithDisplayMode(config, displayID, bestMode, nil)
                    needsSecondPass = true
                }
            }

            // Also verify origin for non-mirrored displays (especially if a display was just unmirrored in Step 1!)
            if saved.mirrorsUUID == nil {
                let bounds = CGDisplayBounds(displayID)
                let curX = Int32(bounds.origin.x.rounded())
                let curY = Int32(bounds.origin.y.rounded())
                if abs(curX - saved.originX) > 1 || abs(curY - saved.originY) > 1 {
                    CGConfigureDisplayOrigin(config, displayID, saved.originX, saved.originY)
                    needsSecondPass = true
                }
            }
        }

        if needsSecondPass {
            let res = CGCompleteDisplayConfiguration(config, .permanently)
            logEvent("Applied Step 2 (Modes & Arrangement) with result \(res.rawValue).")
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    private static func findBestDisplayMode(for displayID: CGDirectDisplayID, matching target: DisplayConfig) -> CGDisplayMode? {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        // 1. Try exact ioDisplayModeID + dimensions + refresh rate match
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

        // 2. Match logical width/height, pixel width/height (HiDPI), and closest refresh rate
        let candidates = modes.filter {
            $0.width == target.width &&
            $0.height == target.height &&
            $0.pixelWidth == target.pixelWidth &&
            $0.pixelHeight == target.pixelHeight &&
            $0.isUsableForDesktopGUI()
        }
        if let best = candidates.min(by: { abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate) }) {
            return best
        }

        // 3. Fallback: match logical width and height and closest refresh rate
        let logicalCandidates = modes.filter {
            $0.width == target.width &&
            $0.height == target.height &&
            $0.isUsableForDesktopGUI()
        }
        return logicalCandidates.min(by: { abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate) })
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

        let profile = DisplayProfile(
            name: finalName,
            createdAt: Date(),
            updatedAt: Date(),
            displays: currentDisplays
        )
        savedProfiles.append(profile)
        activeProfileID = profile.id
        persistProfiles()
        logEvent("Saved display setup '\(finalName)'.")
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
            savedProfiles[idx].displays = currentDisplays
        }
        savedProfiles[idx].updatedAt = Date()
        persistProfiles()
        logEvent("Updated setup '\(savedProfiles[idx].name)' with current layout.")
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
        previewingProfileID = nil
        isCreatingProfile = false
        isSavingEditedAsNew = false
        if let profile {
            editingDisplays = profile.displays
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
        }

        normalizeEditorOrigins(packHorizontalGaps: true)
    }

    func setEditingDisplayRefreshRate(uuid: String, hz: Double) {
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        editingDisplays[idx].refreshRate = hz
        if let displayID = onlineDisplayID(for: editingDisplays[idx].uuid, hardwareID: editingDisplays[idx].hardwareID),
           let bestMode = Self.findBestDisplayMode(for: displayID, matching: editingDisplays[idx]) {
            editingDisplays[idx].ioDisplayModeID = bestMode.ioDisplayModeID
        }
    }

    func setEditingDisplayRotation(uuid: String, rotation: Double) {
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

    /// Moves an extended display directly to the left or right of the Main display in 1 click.
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
            editingDisplays[idx].originY = 0
        } else {
            let maxX = editingDisplays
                .enumerated()
                .filter { $0.offset != idx && $0.element.mirrorsUUID == nil }
                .map { $0.element.originX + Int32($0.element.width) }
                .max() ?? 0
            editingDisplays[idx].originX = maxX
            editingDisplays[idx].originY = 0
        }
        normalizeEditorOrigins(packHorizontalGaps: true)
    }

    func swapLeftRightInEditor() {
        let nonMirrored = editingDisplays
            .filter { $0.mirrorsUUID == nil }
            .sorted { $0.originX < $1.originX }
        guard nonMirrored.count >= 2 else { return }

        // Reverse the horizontal order of non-mirrored displays while keeping Main anchored at (0, 0)
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
                editingDisplays[i].originY = 0
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

        // Snap to edges of other non-mirrored displays
        let others = editingDisplays.filter { $0.mirrorsUUID == nil && $0.uuid != uuid }
        var bestX = rawX
        var bestY = rawY
        let snapThreshold: CGFloat = 600

        for other in others {
            let ox = CGFloat(other.originX)
            let oy = CGFloat(other.originY)
            let ow = CGFloat(other.width)
            let oh = CGFloat(other.height)
            let mw = CGFloat(moved.width)
            let mh = CGFloat(moved.height)

            if abs((rawX + mw) - ox) < snapThreshold {
                bestX = ox - mw
                if abs(rawY - oy) < snapThreshold { bestY = oy }
            } else if abs(rawX - (ox + ow)) < snapThreshold {
                bestX = ox + ow
                if abs(rawY - oy) < snapThreshold { bestY = oy }
            } else if abs((rawY + mh) - oy) < snapThreshold {
                bestY = oy - mh
                if abs(rawX - ox) < snapThreshold { bestX = ox }
            } else if abs(rawY - (oy + oh)) < snapThreshold {
                bestY = oy + oh
                if abs(rawX - ox) < snapThreshold { bestX = ox }
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
