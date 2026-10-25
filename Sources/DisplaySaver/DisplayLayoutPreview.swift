import SwiftUI

/// Visual miniature diagram of the display arrangement, showing relative positions, dimensions, main display, and mirroring.
/// When `manager.isEditingLayout` is true, allows dragging displays interactively to rearrange them!
struct DisplayLayoutPreview: View {
    @ObservedObject var manager: DisplayManager

    private var activeDisplays: [DisplayConfig] {
        manager.isEditingLayout ? manager.editingDisplays : manager.currentDisplays
    }

    private var nonMirroredDisplays: [DisplayConfig] {
        activeDisplays.filter { $0.mirrorsUUID == nil }
    }

    var body: some View {
        GeometryReader { geo in
            let items = nonMirroredDisplays.isEmpty ? activeDisplays : nonMirroredDisplays
            if items.isEmpty {
                Text("No displays detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let minX = items.map { CGFloat($0.originX) }.min() ?? 0
                let minY = items.map { CGFloat($0.originY) }.min() ?? 0
                let maxX = items.map { CGFloat($0.originX) + CGFloat(max($0.width, 1)) }.max() ?? 1920
                let maxY = items.map { CGFloat($0.originY) + CGFloat(max($0.height, 1)) }.max() ?? 1080

                let totalWidth = max(maxX - minX, 1)
                let totalHeight = max(maxY - minY, 1)

                let padding: CGFloat = manager.isEditingLayout ? 24 : 14
                let availW = max(geo.size.width - padding * 2, 10)
                let availH = max(geo.size.height - padding * 2, 10)
                let scale = min(availW / totalWidth, availH / totalHeight)

                let renderedW = totalWidth * scale
                let renderedH = totalHeight * scale
                let offsetX = (geo.size.width - renderedW) / 2.0
                let offsetY = (geo.size.height - renderedH) / 2.0

                ZStack(alignment: .topLeading) {
                    ForEach(items) { disp in
                        let w = max(CGFloat(disp.width) * scale, 28)
                        let h = max(CGFloat(disp.height) * scale, 20)
                        let baseX = offsetX + (CGFloat(disp.originX) - minX) * scale
                        let baseY = offsetY + (CGFloat(disp.originY) - minY) * scale

                        let isDraggingThis = manager.isEditingLayout && manager.draggingDisplayUUID == disp.uuid
                        let dragX = isDraggingThis ? manager.dragTranslation.width : 0
                        let dragY = isDraggingThis ? manager.dragTranslation.height : 0

                        let mirroredPeers = activeDisplays.filter { $0.mirrorsUUID == disp.uuid }

                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(disp.isMain ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.20))
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    isDraggingThis ? Color.orange : (disp.isMain ? Color.accentColor : Color.secondary.opacity(0.7)),
                                    style: StrokeStyle(
                                        lineWidth: (disp.isMain || isDraggingThis) ? 2.0 : 1.2,
                                        dash: (manager.isEditingLayout && !disp.isMain) ? [4, 2] : []
                                    )
                                )

                            VStack(spacing: 1) {
                                // Simulated menu bar on the Main display
                                if disp.isMain {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.8))
                                        .frame(height: 3)
                                        .padding(.horizontal, 3)
                                        .padding(.top, 2)
                                }
                                Spacer(minLength: 0)
                                Text(disp.name)
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 3)
                                Text("\(disp.width)×\(disp.height)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                if !mirroredPeers.isEmpty {
                                    Text("+ \(mirroredPeers.map { $0.name }.joined(separator: ", ")) (Mirror)")
                                        .font(.system(size: 7.5, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .padding(.horizontal, 2)
                                }
                                if manager.isEditingLayout {
                                    Text("(\(disp.originX), \(disp.originY))")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(width: w, height: h)
                        .shadow(color: isDraggingThis ? .black.opacity(0.35) : .clear, radius: 5)
                        .position(x: baseX + w / 2.0 + dragX, y: baseY + h / 2.0 + dragY)
                        .zIndex(isDraggingThis ? 10 : 1)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard manager.isEditingLayout else { return }
                                    manager.draggingDisplayUUID = disp.uuid
                                    manager.dragTranslation = value.translation
                                }
                                .onEnded { value in
                                    guard manager.isEditingLayout else { return }
                                    let deltaDisplayX = value.translation.width / max(scale, 0.0001)
                                    let deltaDisplayY = value.translation.height / max(scale, 0.0001)
                                    manager.draggingDisplayUUID = nil
                                    manager.dragTranslation = .zero
                                    manager.commitDisplayDrag(
                                        uuid: disp.uuid,
                                        deltaDisplayX: deltaDisplayX,
                                        deltaDisplayY: deltaDisplayY
                                    )
                                }
                        )
                    }
                }
            }
        }
        .frame(height: manager.isEditingLayout ? 115 : 92)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(manager.isEditingLayout ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2), lineWidth: manager.isEditingLayout ? 1.5 : 1)
        )
    }
}
