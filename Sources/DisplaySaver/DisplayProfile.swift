import Foundation
import CoreGraphics
import AppKit

/// Persistent identifier and full configuration snapshot for a single display.
struct DisplayConfig: Codable, Identifiable, Equatable {
    /// Persistent UUID string from CGDisplayCreateUUIDFromDisplayID
    var uuid: String
    /// Fallback hardware identifier (vendor-model-serial)
    var hardwareID: String
    /// Friendly display name (from NSScreen.localizedName or fallback)
    var name: String
    /// Whether this is the main display (origin 0,0)
    var isMain: Bool
    /// Origin in global display coordinate space
    var originX: Int32
    var originY: Int32
    /// Logical width and height (points)
    var width: Int
    var height: Int
    /// Physical pixel width and height (for HiDPI / retina matching)
    var pixelWidth: Int
    var pixelHeight: Int
    /// Refresh rate in Hz
    var refreshRate: Double
    /// Rotation angle in degrees (0, 90, 180, 270)
    var rotation: Double
    /// If mirrored, the persistent UUID of the master display it mirrors (nil if not mirroring)
    var mirrorsUUID: String?
    /// Internal CoreGraphics mode number (ioDisplayModeID) as an additional exact-match hint
    var ioDisplayModeID: Int32

    var id: String { uuid }

    var resolutionSummary: String {
        let scaleSuffix = (pixelWidth > width && width > 0) ? " (HiDPI)" : ""
        let hz = refreshRate > 0 ? String(format: " @ %.0fHz", refreshRate) : ""
        let rot = rotation != 0 ? String(format: " • %.0f°", rotation) : ""
        let mainBadge = isMain ? " ★ Main" : ""
        return "\(width)×\(height)\(scaleSuffix)\(hz)\(rot) at (\(originX), \(originY))\(mainBadge)"
    }
}

/// A named profile containing the complete multi-monitor layout and settings.
struct DisplayProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var displays: [DisplayConfig]

    /// Sorted signature of display UUIDs in this profile for matching connected hardware sets
    var hardwareSignature: [String] {
        displays.map { $0.uuid }.sorted()
    }
}
