import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowPositionManager {
    private static let ignoredBundleIDs: Set<String> = [
        "com.jamessavoie.DisplaySaver",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.loginwindow"
    ]

    /// Returns whether DisplaySaver has macOS Accessibility permission to move other apps' windows.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user with the native macOS Accessibility dialog and opens System Settings > Accessibility.
    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures all normal on-screen application windows (including multiple windows of the same app, e.g. Vivaldi,
    /// each tagged with its unique macOS CGWindowID) and maps each to its owning display.
    static func captureCurrentWindows(displays: [DisplayConfig]) -> [SavedWindowPosition] {
        let activeDisplays = displays.filter { $0.mirrorsUUID == nil }
        let candidateDisplays = activeDisplays.isEmpty ? displays : activeDisplays
        guard !candidateDisplays.isEmpty else { return [] }

        var results: [SavedWindowPosition] = []
        var capturedWindowIDs = Set<UInt32>()
        var capturedBundleIDsWithAX = Set<String>()

        // 1. Primary path when Accessibility is trusted: query AXUIElement windows with unique CGWindowID (_AXUIElementGetWindow)
        if isAccessibilityTrusted() {
            for app in NSWorkspace.shared.runningApplications {
                guard app.activationPolicy == .regular,
                      !app.isTerminated,
                      !app.isHidden,
                      let bundleID = app.bundleIdentifier,
                      !ignoredBundleIDs.contains(bundleID) else {
                    continue
                }
                let appName = app.localizedName ?? bundleID
                let axWindows = liveAXWindows(for: app.processIdentifier, bundleID: bundleID)
                guard !axWindows.isEmpty else { continue }

                for (idx, win) in axWindows.enumerated() {
                    let disp = bestDisplay(for: win.frame, in: candidateDisplays)
                    let rel = relativeRect(for: win.frame, in: disp)
                    if win.windowNumber != 0 {
                        capturedWindowIDs.insert(win.windowNumber)
                    }
                    results.append(
                        SavedWindowPosition(
                            bundleIdentifier: bundleID,
                            appName: appName,
                            windowNumber: win.windowNumber != 0 ? win.windowNumber : nil,
                            isFullScreen: win.isFullScreen,
                            windowTitle: win.title,
                            windowIndex: idx,
                            displayUUID: disp.uuid,
                            x: Double(win.frame.origin.x),
                            y: Double(win.frame.origin.y),
                            width: Double(win.frame.size.width),
                            height: Double(win.frame.size.height),
                            relativeX: rel.origin.x,
                            relativeY: rel.origin.y,
                            relativeWidth: rel.size.width,
                            relativeHeight: rel.size.height,
                            capturedAt: Date()
                        )
                    )
                }
                capturedBundleIDsWithAX.insert(bundleID)
            }
        }

        // 2. Supplement via CGWindowListCopyWindowInfo (also catches windows on other Spaces or before Accessibility is granted)
        if let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            var pidToApp: [pid_t: NSRunningApplication] = [:]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated && !app.isHidden {
                pidToApp[app.processIdentifier] = app
            }

            var perBundleIndex: [String: Int] = [:]
            for r in results {
                perBundleIndex[r.bundleIdentifier] = max(perBundleIndex[r.bundleIdentifier, default: 0], r.windowIndex + 1)
            }

            for info in windowInfoList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let app = pidToApp[pid],
                      let bundleID = app.bundleIdentifier,
                      !ignoredBundleIDs.contains(bundleID),
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
                    continue
                }

                let winNum = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
                if winNum != 0 && capturedWindowIDs.contains(winNum) {
                    continue
                }
                // If AX already inspected this app, only supplement if CGWindowList found a genuinely large window with a distinct ID
                if capturedBundleIDsWithAX.contains(bundleID) && winNum == 0 {
                    continue
                }

                var rect = CGRect.zero
                guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect),
                      rect.width >= 200, rect.height >= 120 else {
                    continue
                }
                let title = (info[kCGWindowName as String] as? String) ?? ""

                // Skip Finder's desktop wallpaper backing window (empty title spanning whole monitor/desktop)
                if bundleID == "com.apple.finder" && title.isEmpty && rect.width >= 2500 && rect.height >= 1350 {
                    continue
                }
                // Skip thin browser toolbar/status strip helper windows
                if capturedBundleIDsWithAX.contains(bundleID) && title.isEmpty {
                    continue
                }

                let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
                guard alpha > 0.05 else { continue }

                let idx = perBundleIndex[bundleID, default: 0]
                perBundleIndex[bundleID] = idx + 1

                let appName = app.localizedName ?? (info[kCGWindowOwnerName as String] as? String) ?? bundleID
                let disp = bestDisplay(for: rect, in: candidateDisplays)
                let rel = relativeRect(for: rect, in: disp)

                if winNum != 0 {
                    capturedWindowIDs.insert(winNum)
                }

                results.append(
                    SavedWindowPosition(
                        bundleIdentifier: bundleID,
                        appName: appName,
                        windowNumber: winNum != 0 ? winNum : nil,
                        isFullScreen: false,
                        windowTitle: title,
                        windowIndex: idx,
                        displayUUID: disp.uuid,
                        x: Double(rect.origin.x),
                        y: Double(rect.origin.y),
                        width: Double(rect.size.width),
                        height: Double(rect.size.height),
                        relativeX: rel.origin.x,
                        relativeY: rel.origin.y,
                        relativeWidth: rel.size.width,
                        relativeHeight: rel.size.height,
                        capturedAt: Date()
                    )
                )
            }
        }

        return results
    }

    /// Merges newly captured windows with previously saved windows so apps that aren't open yet (e.g. still launching after reboot)
    /// retain their saved screen assignment, while running apps always reflect their exact current open windows.
    static func mergeSnapshots(
        existing: [SavedWindowPosition],
        current: [SavedWindowPosition]
    ) -> [SavedWindowPosition] {
        guard !current.isEmpty else { return existing }
        let runningRegularBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap { $0.bundleIdentifier }
        )
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        let preserved = existing.filter {
            !runningRegularBundleIDs.contains($0.bundleIdentifier) && $0.capturedAt > cutoff
        }
        return current + preserved
    }

    /// Restores saved window positions across displays using the macOS Accessibility API.
    /// - Parameter onlyMoveCrossScreenDisplaced: When `true` (used for all automatic restores), windows that are ALREADY on
    ///   their saved monitor are left 100% untouched—only windows that got pushed onto the wrong monitor are moved back!
    @discardableResult
    static func restoreWindows(
        _ savedWindows: [SavedWindowPosition],
        displays: [DisplayConfig],
        onlyForBundleID: String? = nil,
        onlyMoveCrossScreenDisplaced: Bool = true
    ) -> (movedCount: Int, needsPermission: Bool) {
        guard !savedWindows.isEmpty else { return (0, false) }
        guard isAccessibilityTrusted() else {
            return (0, true)
        }

        let activeDisplays = displays.filter { $0.mirrorsUUID == nil }
        let candidateDisplays = activeDisplays.isEmpty ? displays : activeDisplays
        guard !candidateDisplays.isEmpty else { return (0, false) }

        var uuidToDisplay: [String: DisplayConfig] = [:]
        for d in candidateDisplays {
            uuidToDisplay[d.uuid] = d
        }

        let groupedByBundle = Dictionary(grouping: savedWindows, by: { $0.bundleIdentifier })
        var movedCount = 0

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  !ignoredBundleIDs.contains(bundleID) else {
                continue
            }
            if let filterBundle = onlyForBundleID, bundleID != filterBundle {
                continue
            }
            guard let savedForApp = groupedByBundle[bundleID], !savedForApp.isEmpty else {
                continue
            }

            let liveWindows = liveAXWindows(for: app.processIdentifier, bundleID: bundleID)
            guard !liveWindows.isEmpty else { continue }

            // Track matched pairs: (liveWindowIndex, savedWindow)
            var matchedPairs: [(Int, SavedWindowPosition)] = []
            var unmatchedLiveIndices = Array(liveWindows.indices)
            var remainingSaved = savedForApp

            // PASS 1: Exact macOS CGWindowID (`windowNumber`) match!
            // Within the same login session (across sleep/wake or screen hotplug), every window keeps its exact CGWindowID,
            // so two windows of Vivaldi (e.g. wid=134 on UltraGear+ and wid=133 on UltraGear) NEVER get mixed up even if tab titles change!
            var matchedAnyByWindowNumber = false
            for liveIdx in liveWindows.indices {
                let liveWid = liveWindows[liveIdx].windowNumber
                guard liveWid != 0 else { continue }
                if let savedIdx = remainingSaved.firstIndex(where: { $0.windowNumber == liveWid }) {
                    let matchedSaved = remainingSaved.remove(at: savedIdx)
                    matchedPairs.append((liveIdx, matchedSaved))
                    unmatchedLiveIndices.removeAll { $0 == liveIdx }
                    matchedAnyByWindowNumber = true
                }
            }

            // PASS 2: Reboot / Relaunched App Matching (ONLY when no CGWindowIDs matched because the Mac or app restarted!)
            // If `matchedAnyByWindowNumber` is true, any unmatched window is simply a brand-new window opened since the last snapshot,
            // so we intentionally leave it right where the user opened it!
            if !matchedAnyByWindowNumber {
                // 2a. Match by exact non-empty windowTitle first
                for liveIdx in unmatchedLiveIndices {
                    let title = liveWindows[liveIdx].title
                    guard !title.isEmpty else { continue }
                    if let savedIdx = remainingSaved.firstIndex(where: { $0.windowTitle == title }) {
                        let matchedSaved = remainingSaved.remove(at: savedIdx)
                        matchedPairs.append((liveIdx, matchedSaved))
                        unmatchedLiveIndices.removeAll { $0 == liveIdx }
                    }
                }

                // 2b. For remaining windows (e.g. browser tabs whose titles updated on reload):
                // First anchor any window that is ALREADY on a display that has an unmatched saved slot for this app
                // (picking the closest size match on that display) so windows already on the right monitor never get swapped!
                for liveIdx in unmatchedLiveIndices {
                    let liveWin = liveWindows[liveIdx]
                    let curDisp = bestDisplay(for: liveWin.frame, in: candidateDisplays)
                    let sameScreenCandidates = remainingSaved.enumerated().filter { $0.element.displayUUID == curDisp.uuid }
                    if let bestSameScreen = sameScreenCandidates.min(by: { a, b in
                        sizeDifference(liveWin.frame.size, a.element) < sizeDifference(liveWin.frame.size, b.element)
                    }) {
                        let matchedSaved = remainingSaved.remove(at: bestSameScreen.offset)
                        matchedPairs.append((liveIdx, matchedSaved))
                        unmatchedLiveIndices.removeAll { $0 == liveIdx }
                    }
                }

                // 2c. Finally, match any displaced windows (e.g. herded onto one screen after reboot) by closest window size!
                for liveIdx in unmatchedLiveIndices {
                    guard !remainingSaved.isEmpty else { break }
                    let liveWin = liveWindows[liveIdx]
                    let bestIdx = remainingSaved.indices.min(by: { i, j in
                        sizeDifference(liveWin.frame.size, remainingSaved[i]) < sizeDifference(liveWin.frame.size, remainingSaved[j])
                    }) ?? 0
                    let matchedSaved = remainingSaved.remove(at: bestIdx)
                    matchedPairs.append((liveIdx, matchedSaved))
                }
            }

            // Apply moves ONLY where needed
            for (liveIdx, targetSaved) in matchedPairs {
                let liveWin = liveWindows[liveIdx]
                // Ensure the target monitor is actually connected right now
                guard uuidToDisplay[targetSaved.displayUUID] != nil else { continue }

                let currentDisp = bestDisplay(for: liveWin.frame, in: candidateDisplays)

                // CRITICAL: During automatic restores, if this window is ALREADY on its saved monitor, DO NOT TOUCH IT!
                if onlyMoveCrossScreenDisplaced && currentDisp.uuid == targetSaved.displayUUID {
                    continue
                }

                // Do not attempt to drag a native fullscreen Space window via AXPosition
                if liveWin.isFullScreen {
                    continue
                }

                let targetRect = resolvedFrame(for: targetSaved, uuidToDisplay: uuidToDisplay)
                let dx = abs(liveWin.frame.origin.x - targetRect.origin.x)
                let dy = abs(liveWin.frame.origin.y - targetRect.origin.y)
                let dw = abs(liveWin.frame.size.width - targetRect.size.width)
                let dh = abs(liveWin.frame.size.height - targetRect.size.height)

                if currentDisp.uuid != targetSaved.displayUUID || dx > 12 || dy > 12 || dw > 16 || dh > 16 {
                    if setAXWindowFrame(liveWin.element, to: targetRect) {
                        movedCount += 1
                    }
                }
            }
        }

        return (movedCount, false)
    }

    private static func sizeDifference(_ liveSize: CGSize, _ saved: SavedWindowPosition) -> Double {
        abs(Double(liveSize.width) - saved.width) + abs(Double(liveSize.height) - saved.height)
    }

    // MARK: - Private AX Helpers

    private struct LiveAXWindow {
        let element: AXUIElement
        let windowNumber: UInt32
        let isFullScreen: Bool
        let title: String
        let frame: CGRect
    }

    private static func liveAXWindows(for pid: pid_t, bundleID: String) -> [LiveAXWindow] {
        let appElem = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return []
        }

        var result: [LiveAXWindow] = []
        for win in axWindows {
            // Skip minimized windows
            var minVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success,
               let isMin = minVal as? Bool, isMin {
                continue
            }

            // Read native fullscreen attribute WITHOUT skipping the window!
            // Skipping fullscreen windows previously caused Vivaldi's second window (e.g. fullscreen YouTube on UltraGear)
            // to be omitted from the list and confused with Vivaldi's window on UltraGear+.
            var isFS = false
            var fsVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsVal) == .success,
               let fsBool = fsVal as? Bool {
                isFS = fsBool
            }

            // Check subrole (accept standard, dialog, or fullscreen windows; skip floating tooltips/overlays)
            var subroleVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleVal) == .success,
               let subrole = subroleVal as? String {
                let allowedSubroles: Set<String> = [
                    kAXStandardWindowSubrole as String,
                    kAXDialogSubrole as String,
                    "AXFullScreenWindow"
                ]
                if !isFS && !allowedSubroles.contains(subrole) {
                    continue
                }
            }

            guard let pt = axPoint(for: win),
                  let sz = axSize(for: win),
                  sz.width >= 200, sz.height >= 120 else {
                continue
            }

            var titleVal: CFTypeRef?
            let title: String
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal) == .success,
               let str = titleVal as? String {
                title = str
            } else {
                title = ""
            }

            // Exclude Finder's desktop background window (empty title covering the entire monitor/desktop)
            if bundleID == "com.apple.finder" && title.isEmpty && sz.width >= 2500 && sz.height >= 1350 {
                continue
            }

            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(win, &wid)

            result.append(
                LiveAXWindow(
                    element: win,
                    windowNumber: wid,
                    isFullScreen: isFS,
                    title: title,
                    frame: CGRect(origin: pt, size: sz)
                )
            )
        }
        return result
    }

    private static func axPoint(for element: AXUIElement) -> CGPoint? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &val) == .success,
              let axVal = val else {
            return nil
        }
        var pt = CGPoint.zero
        if AXValueGetValue(axVal as! AXValue, .cgPoint, &pt) {
            return pt
        }
        return nil
    }

    private static func axSize(for element: AXUIElement) -> CGSize? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &val) == .success,
              let axVal = val else {
            return nil
        }
        var sz = CGSize.zero
        if AXValueGetValue(axVal as! AXValue, .cgSize, &sz) {
            return sz
        }
        return nil
    }

    private static func setAXWindowFrame(_ element: AXUIElement, to rect: CGRect) -> Bool {
        var pt = rect.origin
        var sz = rect.size
        guard let posVal = AXValueCreate(.cgPoint, &pt),
              let sizeVal = AXValueCreate(.cgSize, &sz) else {
            return false
        }
        let r1 = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        let r2 = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        return r1 == .success || r2 == .success
    }

    private static func bestDisplay(for windowRect: CGRect, in displays: [DisplayConfig]) -> DisplayConfig {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        for d in displays {
            let dRect = CGRect(x: CGFloat(d.originX), y: CGFloat(d.originY), width: CGFloat(d.width), height: CGFloat(d.height))
            if dRect.contains(center) {
                return d
            }
        }
        var best = displays[0]
        var bestArea: CGFloat = -1
        for d in displays {
            let dRect = CGRect(x: CGFloat(d.originX), y: CGFloat(d.originY), width: CGFloat(d.width), height: CGFloat(d.height))
            let inter = windowRect.intersection(dRect)
            let area = inter.isNull ? 0 : (inter.width * inter.height)
            if area > bestArea {
                bestArea = area
                best = d
            }
        }
        return best
    }

    private static func relativeRect(for windowRect: CGRect, in display: DisplayConfig) -> CGRect {
        let dw = max(1.0, CGFloat(display.width))
        let dh = max(1.0, CGFloat(display.height))
        let rx = (windowRect.origin.x - CGFloat(display.originX)) / dw
        let ry = (windowRect.origin.y - CGFloat(display.originY)) / dh
        let rw = windowRect.size.width / dw
        let rh = windowRect.size.height / dh
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    private static func resolvedFrame(
        for saved: SavedWindowPosition,
        uuidToDisplay: [String: DisplayConfig]
    ) -> CGRect {
        if let disp = uuidToDisplay[saved.displayUUID] {
            let dw = Double(max(1, disp.width))
            let dh = Double(max(1, disp.height))
            let w = min(dw, max(200.0, saved.relativeWidth * dw))
            let h = min(dh, max(120.0, saved.relativeHeight * dh))
            var x = Double(disp.originX) + saved.relativeX * dw
            var y = Double(disp.originY) + saved.relativeY * dh

            let minX = Double(disp.originX)
            let maxX = Double(disp.originX + Int32(disp.width)) - min(w, 120.0)
            let minY = Double(disp.originY)
            let maxY = Double(disp.originY + Int32(disp.height)) - min(h, 80.0)
            x = max(minX, min(maxX, x))
            y = max(minY, min(maxY, y))

            return CGRect(x: x, y: y, width: w, height: h)
        }
        return CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
    }
}
