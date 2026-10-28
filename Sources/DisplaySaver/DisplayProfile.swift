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

    /// Concise display name for auto-generated layout summaries (e.g. "ULTRAGEAR+", "ULTRAGEAR", "LG TV").
    var conciseName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.contains("TV") {
            // Shorten e.g. "LG TV SSCR2" -> "LG TV"
            if let range = trimmed.range(of: "TV", options: .caseInsensitive) {
                let prefix = String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
                return prefix
            }
        }
        if upper.hasPrefix("LG ULTRAGEAR") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

/// Represents a selectable resolution/scaling mode for a display in the layout editor.
struct DisplayResolutionOption: Identifiable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var isHiDPI: Bool {
        pixelWidth > width && width > 0
    }

    var id: String {
        "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)"
    }

    var label: String {
        if isHiDPI {
            return "\(width) × \(height) (HiDPI)"
        } else {
            return "\(width) × \(height)"
        }
    }
}

/// Role of a display in the multi-monitor layout editor.
enum DisplayRoleSelection: Hashable {
    case main
    case extended
    case mirror(masterUUID: String)
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

    /// Human-readable summary of the arrangement (e.g. "ULTRAGEAR Left, ULTRAGEAR+ & LG TV Mirrored Right")
    var layoutSummary: String {
        Self.suggestedName(for: displays)
    }

    /// Generates a descriptive summary name for a given set of displays based on left-to-right order and mirroring.
    static func suggestedName(for displays: [DisplayConfig]) -> String {
        guard !displays.isEmpty else { return "Custom Layout" }

        let nonMirrored = displays
            .filter { $0.mirrorsUUID == nil }
            .sorted { a, b in
                if a.originX != b.originX { return a.originX < b.originX }
                if a.originY != b.originY { return a.originY < b.originY }
                return a.name < b.name
            }

        guard !nonMirrored.isEmpty else {
            return displays.map { $0.conciseName }.joined(separator: " & ") + " Mirrored"
        }

        if nonMirrored.count == 1 {
            let primary = nonMirrored[0]
            let slaves = displays.filter { $0.mirrorsUUID == primary.uuid }
            if slaves.isEmpty {
                return "\(primary.conciseName) Only"
            } else {
                let allNames = ([primary] + slaves).map { $0.conciseName }.joined(separator: " & ")
                return "\(allNames) Mirrored"
            }
        }

        // Determine position labels from left to right (or top to bottom if stacked vertically)
        let minX = nonMirrored.map { $0.originX }.min() ?? 0
        let maxX = nonMirrored.map { $0.originX }.max() ?? 0
        let minY = nonMirrored.map { $0.originY }.min() ?? 0
        let maxY = nonMirrored.map { $0.originY }.max() ?? 0
        let primarilyVertical = (maxY - minY) > (maxX - minX)

        func positionLabel(index: Int, count: Int) -> String {
            if primarilyVertical {
                if count == 2 { return index == 0 ? "Top" : "Bottom" }
                if count == 3 { return index == 0 ? "Top" : (index == 1 ? "Middle" : "Bottom") }
                return "Pos \(index + 1)"
            } else {
                if count == 2 { return index == 0 ? "Left" : "Right" }
                if count == 3 { return index == 0 ? "Left" : (index == 1 ? "Center" : "Right") }
                if index == 0 { return "Far Left" }
                if index == count - 1 { return "Far Right" }
                return "Center \(index)"
            }
        }

        var parts: [String] = []
        for (idx, disp) in nonMirrored.enumerated() {
            let pos = positionLabel(index: idx, count: nonMirrored.count)
            let slaves = displays.filter { $0.mirrorsUUID == disp.uuid }
            if slaves.isEmpty {
                parts.append("\(disp.conciseName) \(pos)")
            } else {
                let slaveNames = slaves.map { $0.conciseName }.joined(separator: " & ")
                parts.append("\(disp.conciseName) & \(slaveNames) Mirrored \(pos)")
            }
        }

        return parts.joined(separator: ", ")
    }
}
