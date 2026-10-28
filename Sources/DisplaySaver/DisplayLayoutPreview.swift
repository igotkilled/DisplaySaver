import SwiftUI

/// Visual miniature diagram of a display arrangement, showing relative positions, dimensions, main display, and mirroring.
/// Can be used either for the live/editable display canvas OR as a static preview when clicking a saved setup!
struct DisplayLayoutPreview: View {
    @ObservedObject var manager: DisplayManager
    var overrideDisplays: [DisplayConfig]? = nil
    var isPreviewCard: Bool = false

    private var isInteractiveEditor: Bool {
        overrideDisplays == nil && manager.isEditingLayout
    }

    private var activeDisplays: [DisplayConfig] {
        if let overrideDisplays {
            return overrideDisplays
        }
        return manager.isEditingLayout ? manager.editingDisplays : manager.currentDisplays
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

                let padding: CGFloat = isInteractiveEditor ? 22 : 14
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

                        let isDraggingThis = isInteractiveEditor && manager.draggingDisplayUUID == disp.uuid
                        let dragX = isDraggingThis ? manager.dragTranslation.width : 0
                        let dragY = isDraggingThis ? manager.dragTranslation.height : 0

                        let mirroredPeers = activeDisplays.filter { $0.mirrorsUUID == disp.uuid }
                        let isSelectedInEditor = isInteractiveEditor && (
                            manager.selectedEditingDisplayUUID == disp.uuid ||
                            mirroredPeers.contains(where: { $0.uuid == manager.selectedEditingDisplayUUID })
                        )

                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(disp.isMain ? Color.accentColor.opacity(0.26) : Color.secondary.opacity(0.20))
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    isDraggingThis ? Color.orange : (
                                        isSelectedInEditor ? Color.cyan : (
                                            disp.isMain ? Color.accentColor : Color.secondary.opacity(0.75)
                                        )
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: (disp.isMain || isDraggingThis || isSelectedInEditor) ? 2.2 : 1.2,
                                        dash: (isInteractiveEditor && !disp.isMain && !isSelectedInEditor) ? [4, 2] : []
                                    )
                                )

                            VStack(spacing: 1.5) {
                                // Simulated menu bar on the Main display
                                if disp.isMain {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.85))
                                        .frame(height: 3.5)
                                        .padding(.horizontal, 4)
                                        .padding(.top, 2)
                                }
                                Spacer(minLength: 0)
                                Text(disp.name)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .padding(.horizontal, 4)

                                let hzText = disp.refreshRate > 0 ? " @ \(Int(disp.refreshRate.rounded()))Hz" : ""
                                Text("\(disp.width)×\(disp.height)\(hzText)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)

                                if !mirroredPeers.isEmpty {
                                    ForEach(mirroredPeers) { peer in
                                        let peerSelected = isInteractiveEditor && manager.selectedEditingDisplayUUID == peer.uuid
                                        Button {
                                            if isInteractiveEditor {
                                                manager.selectedEditingDisplayUUID = peer.uuid
                                            }
                                        } label: {
                                            Text("+ \(peer.name) (Mirror)")
                                                .font(.system(size: 7.5, weight: .semibold))
                                                .foregroundStyle(peerSelected ? .white : .orange)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(
                                                    Capsule()
                                                        .fill(peerSelected ? Color.orange : Color.orange.opacity(0.16))
                                                )
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                if isInteractiveEditor || isPreviewCard {
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
                        .zIndex(isDraggingThis ? 10 : (isSelectedInEditor ? 5 : 1))
                        .onTapGesture {
                            if isInteractiveEditor {
                                manager.selectedEditingDisplayUUID = disp.uuid
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    guard isInteractiveEditor else { return }
                                    manager.selectedEditingDisplayUUID = disp.uuid
                                    manager.draggingDisplayUUID = disp.uuid
                                    manager.dragTranslation = value.translation
                                }
                                .onEnded { value in
                                    guard isInteractiveEditor else { return }
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
        .frame(height: isInteractiveEditor ? 120 : (isPreviewCard ? 110 : 96))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    (isInteractiveEditor || isPreviewCard) ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.25),
                    lineWidth: (isInteractiveEditor || isPreviewCard) ? 1.5 : 1
                )
        )
    }
}
