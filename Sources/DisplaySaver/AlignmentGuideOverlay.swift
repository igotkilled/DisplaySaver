import SwiftUI
import AppKit
import CoreGraphics

/// Displays a click-through, real-time horizontal alignment line across all non-mirrored monitors
/// so the user can visually match physical desk height differences across bezels before/while saving.
@MainActor
final class AlignmentGuideWindowController {
    static let shared = AlignmentGuideWindowController()

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    private init() {}

    func syncVisibility(manager: DisplayManager) {
        guard manager.isEditingLayout && manager.showAlignmentGuide else {
            hideAll()
            return
        }

        var activeScreenIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            // Skip hardware-mirrored slave screens
            let mirrorMaster = CGDisplayMirrorsDisplay(displayID)
            if mirrorMaster != kCGNullDirectDisplay && mirrorMaster != displayID {
                continue
            }

            let uuid = DisplayManager.uuidString(for: displayID)
            let hwID = DisplayManager.hardwareID(for: displayID)

            // Skip screens configured as mirrored in the editor
            if let edited = manager.editingDisplays.first(where: { $0.uuid == uuid || $0.hardwareID == hwID }),
               edited.mirrorsUUID != nil {
                continue
            }

            activeScreenIDs.insert(displayID)

            if let existing = overlayWindows[displayID] {
                if existing.frame != screen.frame {
                    existing.setFrame(screen.frame, display: true)
                }
                existing.orderFrontRegardless()
            } else {
                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                window.contentView = NSHostingView(
                    rootView: AlignmentGuideScreenView(
                        manager: manager,
                        displayUUID: uuid,
                        hardwareID: hwID
                    )
                )
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                overlayWindows[displayID] = window
            }
        }

        // Remove overlays for any screens no longer active
        for (id, win) in overlayWindows where !activeScreenIDs.contains(id) {
            win.orderOut(nil)
            overlayWindows.removeValue(forKey: id)
        }
    }

    func hideAll() {
        guard !overlayWindows.isEmpty else { return }
        for (_, win) in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

private struct AlignmentGuideScreenView: View {
    @ObservedObject var manager: DisplayManager
    let displayUUID: String
    let hardwareID: String

    var body: some View {
        GeometryReader { geo in
            if let mainDisp = manager.editingDisplays.first(where: { $0.isMain && $0.mirrorsUUID == nil })
                ?? manager.editingDisplays.first(where: { $0.mirrorsUUID == nil }),
               let thisDisp = manager.editingDisplays.first(where: { $0.uuid == displayUUID || $0.hardwareID == hardwareID }),
               thisDisp.mirrorsUUID == nil {

                // Reference global Y in CoreGraphics points (measured downward from Main display's top bezel)
                let mainRefY: CGFloat = min(max(CGFloat(mainDisp.height) * 0.34, 240), 580)
                let deltaOriginY = CGFloat(thisDisp.originY - mainDisp.originY)
                // Local distance downward from THIS monitor's physical top bezel once `thisDisp.originY` is applied:
                let primaryLocalY = mainRefY - deltaOriginY
                let secondaryLocalY = primaryLocalY + 300

                let higherPx = Int(thisDisp.originY - mainDisp.originY)
                let offsetSummary: String = {
                    if thisDisp.uuid == mainDisp.uuid {
                        return "★ \(thisDisp.conciseName) • Reference"
                    } else if higherPx > 0 {
                        return "\(thisDisp.conciseName) • +\(higherPx)px Higher ↑"
                    } else if higherPx < 0 {
                        return "\(thisDisp.conciseName) • \(higherPx)px Lower ↓"
                    } else {
                        return "\(thisDisp.conciseName) • Level (0px)"
                    }
                }()

                ZStack(alignment: .topLeading) {
                    // Secondary parallel reference track (300pt lower)
                    if secondaryLocalY > 40 && secondaryLocalY < geo.size.height - 40 {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: secondaryLocalY))
                            path.addLine(to: CGPoint(x: geo.size.width, y: secondaryLocalY))
                        }
                        .stroke(Color.black.opacity(0.45), lineWidth: 3)

                        Path { path in
                            path.move(to: CGPoint(x: 0, y: secondaryLocalY))
                            path.addLine(to: CGPoint(x: geo.size.width, y: secondaryLocalY))
                        }
                        .stroke(
                            Color.cyan.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.5, dash: [10, 6])
                        )
                    }

                    // Primary solid laser alignment line across the entire display
                    let clampedY = min(max(primaryLocalY, 16), geo.size.height - 16)

                    // Dark contrast halo so the cyan line stands out on white or dark windows
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .frame(width: geo.size.width, height: 5)
                        .position(x: geo.size.width / 2.0, y: clampedY)

                    // Crisp glowing cyan core line
                    Rectangle()
                        .fill(Color.cyan)
                        .frame(width: geo.size.width, height: 2.5)
                        .shadow(color: Color.cyan.opacity(0.9), radius: 4)
                        .position(x: geo.size.width / 2.0, y: clampedY)

                    // Left bezel target marker + badge
                    HStack(spacing: 6) {
                        Text("◀")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.cyan)
                            .shadow(color: .black, radius: 2)

                        bezelBadge(text: "ALIGN ACROSS BEZEL • \(offsetSummary)")
                    }
                    .position(x: 195, y: max(clampedY - 22, 24))

                    // Right bezel target marker + badge
                    HStack(spacing: 6) {
                        bezelBadge(text: "\(offsetSummary) • ALIGN ACROSS BEZEL")

                        Text("▶")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Color.cyan)
                            .shadow(color: .black, radius: 2)
                    }
                    .position(x: max(geo.size.width - 195, 220), y: max(clampedY - 22, 24))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func bezelBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.cyan.opacity(0.9), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
    }
}
