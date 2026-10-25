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
    @Published var newProfileName: String = ""
    @Published var showActivityLog: Bool = false
    @Published var isEditingLayout: Bool = false
    @Published var editingDisplays: [DisplayConfig] = []
    @Published var draggingDisplayUUID: String? = nil
    @Published var dragTranslation: CGSize = .zero

    private var debounceTimer: Timer?
    private var periodicCheckTimer: Timer?
    private var suppressCallbackUntil: Date = .distantPast
    private let storageURL: URL

    private init() {
        let fm = FileManager.default
        let storageDir: URL
        let devWorkspaceFolder = URL(fileURLWithPath: "/Users/jamessavoie/Documents/mac display saver", isDirectory: true)
        if fm.fileExists(atPath: devWorkspaceFolder.appendingPathComponent("Package.swift").path),
           fm.isWritableFile(atPath: devWorkspaceFolder.path) {
            storageDir = devWorkspaceFolder
        } else if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = appSupport.appendingPathComponent("DisplaySaver", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            storageDir = folder
        } else {
            storageDir = Bundle.main.bundleURL.deletingLastPathComponent()
        }
        self.storageURL = storageDir.appendingPathComponent("profiles.json")

        self.autoEnforceLayout = UserDefaults.standard.object(forKey: "autoEnforceLayout") as? Bool ?? true
        self.autoSwitchByHardwareSet = UserDefaults.standard.object(forKey: "autoSwitchByHardwareSet") as? Bool ?? true

        // Load MonitorPanel private framework for native display rotation support
        _ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)

        loadProfiles()
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
            saveCurrentAsProfile(name: "Default Layout")
            logEvent("Created initial 'Default Layout' profile from current display configuration.")
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

    var doesCurrentMatchActiveProfile: Bool {
        guard let profile = activeProfile else { return true }
        return matchesProfile(profile, against: currentDisplays)
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
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    // MARK: - Monitoring & Callbacks

    private func registerCallbacks() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
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
        logEvent("CGReconfig display=\(display) flags=0x\(String(flags.rawValue, radix: 16))")
        // Keep main/monitor displays awake during HDMI/CEC hotplug transitions (e.g. when turning a mirrored TV on or off)
        wakeMainDisplayIfNeeded()
        if flags.contains(.beginConfigurationFlag) {
            return
        }
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
        reloadProfilesIfChangedOnDisk()
        refreshCurrentDisplays()
        guard autoEnforceLayout, !isApplying, !isEditingLayout, Date() > suppressCallbackUntil else { return }
        checkAndRestoreIfNeeded(reason: "Watchdog check")
    }

    func scheduleCheckAndRestore(delay: TimeInterval = 1.0) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.reloadProfilesIfChangedOnDisk()
                self?.refreshCurrentDisplays()
                guard let self = self, self.autoEnforceLayout, !self.isEditingLayout else { return }
                self.checkAndRestoreIfNeeded(reason: "Display change detected")
            }
        }
    }

    private func checkAndRestoreIfNeeded(reason: String) {
        let currentSig = currentDisplays.map { $0.uuid }.sorted()

        // If auto-switch by connected hardware set is enabled, find a profile matching connected monitors
        if autoSwitchByHardwareSet,
           let matchedProfile = savedProfiles.first(where: { $0.hardwareSignature == currentSig }) {
            if activeProfileID != matchedProfile.id {
                activeProfileID = matchedProfile.id
                logEvent("Switched active profile to '\(matchedProfile.name)' for connected monitors.")
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
        suppressCallbackUntil = Date().addingTimeInterval(3.5)
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
        // CGConfigureDisplayMirrorOfDisplay AND CGConfigureDisplayWithDisplayMode on the mirrored slave
        // in the SAME transaction! Therefore we configure mirroring & non-mirrored displays first,
        // and then set the mirrored display's 60Hz mode in Transaction 2 after mirroring is active.
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            logEvent("Error: Could not begin CoreGraphics display configuration.")
            return
        }

        // 2a. Configure Mirroring first — always ensure the non-TV monitor is the Mirror Master!
        for saved in profile.displays {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
            if let masterUUID = saved.mirrorsUUID,
               let masterID = uuidToDisplayID[masterUUID] ?? profile.displays.first(where: { $0.uuid == masterUUID }).flatMap({ resolveDisplayID(for: $0) }) {
                if onlineIDs.contains(masterID) {
                    // If the master is accidentally mirroring the slave (or anything else), unmirror the master first!
                    if CGDisplayMirrorsDisplay(masterID) != kCGNullDirectDisplay {
                        CGConfigureDisplayMirrorOfDisplay(config, masterID, kCGNullDirectDisplay)
                    }
                    if CGDisplayMirrorsDisplay(displayID) != masterID {
                        CGConfigureDisplayMirrorOfDisplay(config, displayID, masterID)
                    }
                }
            } else {
                // Only un-mirror if this display is NOT the master of a mirror set, OR if it is mirroring another display
                let currentMirrorTarget = CGDisplayMirrorsDisplay(displayID)
                if currentMirrorTarget != kCGNullDirectDisplay && currentMirrorTarget != displayID {
                    // Check if any saved display is supposed to mirror this display; if so, we will flip the master in the loop above
                    let hasSlaves = profile.displays.contains { $0.mirrorsUUID == saved.uuid }
                    if !hasSlaves {
                        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                    }
                }
            }
        }

        // 2b. Configure Display Modes for NON-mirrored displays only in Transaction 1
        for saved in profile.displays where saved.mirrorsUUID == nil {
            guard let displayID = resolveDisplayID(for: saved) else { continue }
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
        // Always include origins for all non-mirrored displays whenever mirroring or arrangement changes
        // so macOS cannot place a secondary monitor on the wrong side when collapsing a mirror set.
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
            logEvent("Applied profile '\(profile.name)' (Step 1: Layout & Mirroring).")
            // Step 3: Transaction 2 — After mirroring settles (0.7s), enforce the exact 60Hz mode on mirrored displays!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.enforceDisplayModesPass(for: profile)
            }
        } else {
            CGCancelDisplayConfiguration(config)
            logEvent("Display configuration returned code \(result.rawValue).")
        }

        // Refresh display snapshot after a short delay to reflect applied state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
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

        var needsModeFix = false
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return }

        for saved in profile.displays {
            guard let displayID = uuidToDisplayID[saved.uuid] ?? hwToDisplayID[saved.hardwareID] else { continue }
            let curMode = CGDisplayCopyDisplayMode(displayID)
            let curHz = curMode?.refreshRate ?? 0
            let curPxW = curMode?.pixelWidth ?? 0
            let curPxH = curMode?.pixelHeight ?? 0

            if abs(curHz - saved.refreshRate) > 1.0 || curPxW != saved.pixelWidth || curPxH != saved.pixelHeight {
                if let bestMode = Self.findBestDisplayMode(for: displayID, matching: saved) {
                    CGConfigureDisplayWithDisplayMode(config, displayID, bestMode, nil)
                    needsModeFix = true
                }
            }
        }

        if needsModeFix {
            let res = CGCompleteDisplayConfiguration(config, .permanently)
            logEvent("Applied Step 2 (60Hz Mirror Mode) with result \(res.rawValue).")
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    private static func findBestDisplayMode(for displayID: CGDirectDisplayID, matching target: DisplayConfig) -> CGDisplayMode? {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        // 1. Try exact ioDisplayModeID + dimensions match
        if let exact = modes.first(where: {
            $0.ioDisplayModeID == target.ioDisplayModeID &&
            $0.width == target.width &&
            $0.height == target.height &&
            $0.pixelWidth == target.pixelWidth &&
            $0.pixelHeight == target.pixelHeight
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

    // MARK: - Profile Persistence

    func saveCurrentAsProfile(name: String) {
        refreshCurrentDisplays()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Saved Layout" : trimmed

        let profile = DisplayProfile(
            name: finalName,
            createdAt: Date(),
            updatedAt: Date(),
            displays: currentDisplays
        )
        savedProfiles.append(profile)
        activeProfileID = profile.id
        persistProfiles()
        logEvent("Saved current display configuration as '\(finalName)'.")
    }

    func updateProfile(_ profile: DisplayProfile, withCurrentDisplays: Bool = true) {
        refreshCurrentDisplays()
        guard let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if withCurrentDisplays {
            savedProfiles[idx].displays = currentDisplays
        }
        savedProfiles[idx].updatedAt = Date()
        persistProfiles()
        logEvent("Updated profile '\(savedProfiles[idx].name)' with current layout.")
    }

    // MARK: - Interactive Layout Editor

    func beginEditingLayout() {
        refreshCurrentDisplays()
        editingDisplays = currentDisplays
        draggingDisplayUUID = nil
        dragTranslation = .zero
        isEditingLayout = true
    }

    func cancelEditingLayout() {
        isEditingLayout = false
        draggingDisplayUUID = nil
        dragTranslation = .zero
    }

    func swapLeftRightInEditor() {
        let nonMirrored = editingDisplays.filter { $0.mirrorsUUID == nil }
        guard nonMirrored.count >= 2 else { return }
        for i in editingDisplays.indices {
            if editingDisplays[i].mirrorsUUID == nil && !editingDisplays[i].isMain {
                editingDisplays[i].originX = (editingDisplays[i].originX < 0)
                    ? Int32(editingDisplays.first(where: { $0.isMain })?.width ?? 2560)
                    : -Int32(editingDisplays[i].width)
                editingDisplays[i].originY = 0
            }
        }
    }

    func commitDisplayDrag(uuid: String, deltaDisplayX: CGFloat, deltaDisplayY: CGFloat) {
        guard let idx = editingDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        var moved = editingDisplays[idx]
        let rawX = CGFloat(moved.originX) + deltaDisplayX
        let rawY = CGFloat(moved.originY) + deltaDisplayY

        // Snap to edges of other non-mirrored displays (specifically the Main display or adjacent monitors)
        let others = editingDisplays.filter { $0.mirrorsUUID == nil && $0.uuid != uuid }
        var bestX = rawX
        var bestY = rawY
        let snapThreshold: CGFloat = 600 // generous snap in display pixels so dragging left/right cleanly docks edge-to-edge

        for other in others {
            let ox = CGFloat(other.originX)
            let oy = CGFloat(other.originY)
            let ow = CGFloat(other.width)
            let oh = CGFloat(other.height)
            let mw = CGFloat(moved.width)
            let mh = CGFloat(moved.height)

            // Snap to Left edge of `other`: moved.right == other.left -> moved.originX = ox - mw
            if abs((rawX + mw) - ox) < snapThreshold {
                bestX = ox - mw
                if abs(rawY - oy) < snapThreshold { bestY = oy }
            }
            // Snap to Right edge of `other`: moved.left == other.right -> moved.originX = ox + ow
            else if abs(rawX - (ox + ow)) < snapThreshold {
                bestX = ox + ow
                if abs(rawY - oy) < snapThreshold { bestY = oy }
            }
            // Snap to Top edge of `other`: moved.bottom == other.top -> moved.originY = oy - mh
            else if abs((rawY + mh) - oy) < snapThreshold {
                bestY = oy - mh
                if abs(rawX - ox) < snapThreshold { bestX = ox }
            }
            // Snap to Bottom edge of `other`: moved.top == other.bottom -> moved.originY = oy + oh
            else if abs(rawY - (oy + oh)) < snapThreshold {
                bestY = oy + oh
                if abs(rawX - ox) < snapThreshold { bestX = ox }
            }
        }

        moved.originX = Int32(bestX.rounded())
        moved.originY = Int32(bestY.rounded())

        // Normalize so the Main display always stays anchored at (0, 0)
        let mainShiftX: Int32
        let mainShiftY: Int32
        if moved.isMain {
            mainShiftX = moved.originX
            mainShiftY = moved.originY
        } else {
            mainShiftX = editingDisplays.first(where: { $0.isMain })?.originX ?? 0
            mainShiftY = editingDisplays.first(where: { $0.isMain })?.originY ?? 0
        }

        editingDisplays[idx] = moved
        for i in editingDisplays.indices {
            if editingDisplays[i].mirrorsUUID == nil {
                editingDisplays[i].originX -= mainShiftX
                editingDisplays[i].originY -= mainShiftY
            } else if let masterUUID = editingDisplays[i].mirrorsUUID,
                      let master = editingDisplays.first(where: { $0.uuid == masterUUID }) {
                editingDisplays[i].originX = master.originX
                editingDisplays[i].originY = master.originY
            }
        }
    }

    func saveAndApplyEditedLayout() {
        guard isEditingLayout else { return }
        let updatedDisplays = editingDisplays
        isEditingLayout = false
        draggingDisplayUUID = nil
        dragTranslation = .zero

        if let active = activeProfile,
           let idx = savedProfiles.firstIndex(where: { $0.id == active.id }) {
            savedProfiles[idx].displays = updatedDisplays
            savedProfiles[idx].updatedAt = Date()
            persistProfiles()
            logEvent("Saved edited layout to '\(savedProfiles[idx].name)' and applying...")
            applyProfile(savedProfiles[idx])
        } else {
            let profile = DisplayProfile(
                name: "Default Layout",
                createdAt: Date(),
                updatedAt: Date(),
                displays: updatedDisplays
            )
            savedProfiles.append(profile)
            activeProfileID = profile.id
            persistProfiles()
            logEvent("Saved edited layout as 'Default Layout' and applying...")
            applyProfile(profile)
        }
    }

    func deleteProfile(_ profile: DisplayProfile) {
        savedProfiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = savedProfiles.first?.id
        }
        persistProfiles()
        logEvent("Deleted profile '\(profile.name)'.")
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
}
