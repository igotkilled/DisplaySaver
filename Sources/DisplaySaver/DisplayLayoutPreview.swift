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
                let maxX = items.map { CGFloat($0.originX) + CGFloat(max($0.width, 1)) }.max() ?? 1920
                let totalWidth = max(maxX - minX, 1)

                let baseMaxH = items.map { CGFloat(max($0.height, 1)) }.max() ?? 1440
                let mainOriginY = items.first(where: { $0.isMain })?.originY ?? 0
                let maxAbsOffsetY = items.map { abs(CGFloat($0.originY - mainOriginY)) }.max() ?? 0
                let isVerticallyStacked = maxAbsOffsetY >= baseMaxH * 0.75

                let padX: CGFloat = isInteractiveEditor ? 20 : 14
                let padY: CGFloat = isInteractiveEditor ? 14 : 10
                let availW = max(geo.size.width - padX * 2, 10)
                let availH = max(geo.size.height - padY * 2, 10)

                // Keep monitor box scale constant during desk-height alignment so rectangles NEVER shrink or smoosh together!
                let minY = items.map { CGFloat($0.originY) }.min() ?? 0
                let maxY = items.map { CGFloat($0.originY) + CGFloat(max($0.height, 1)) }.max() ?? 1080
                let stackedTotalH = max(maxY - minY, 1)

                let scale: CGFloat = isVerticallyStacked
                    ? min(availW / totalWidth, availH / stackedTotalH)
                    : min(availW / totalWidth, (availH * 0.66) / baseMaxH)

                let renderedW = totalWidth * scale
                let offsetX = (geo.size.width - renderedW) / 2.0
                let centerY = geo.size.height / 2.0
                let visualVerticalMultiplier: CGFloat = 3.2

                ZStack(alignment: .topLeading) {
                    ForEach(items) { disp in
                        let w = max(CGFloat(disp.width) * scale, 28)
                        let h = max(CGFloat(disp.height) * scale, 20)
                        let baseX = offsetX + (CGFloat(disp.originX) - minX) * scale

                        let boxCenterY: CGFloat = {
                            if isVerticallyStacked {
                                let renderedH = stackedTotalH * scale
                                let offsetY = (geo.size.height - renderedH) / 2.0
                                return offsetY + (CGFloat(disp.originY) - minY) * scale + h / 2.0
                            } else if disp.isMain {
                                return centerY
                            } else {
                                // Positive `upPx` (from pressing Up Arrow ↑) moves the selected screen UP in the preview!
                                let upPx = CGFloat(disp.originY - mainOriginY)
                                let maxTravel = max((geo.size.height - h) / 2.0 - 6, 4)
                                let rawShift = -upPx * scale * visualVerticalMultiplier
                                let clampedShift = min(max(rawShift, -maxTravel), maxTravel)
                                return centerY + clampedShift
                            }
                        }()
                        let baseY = boxCenterY - h / 2.0

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

                                if isInteractiveEditor || isPreviewCard || (!disp.isMain && disp.originY != 0) {
                                    let upPx = Int(disp.originY - mainOriginY)
                                    let heightNote: String = {
                                        guard !disp.isMain && upPx != 0 else { return "" }
                                        return upPx > 0 ? " • +\(upPx)px↑" : " • \(upPx)px↓"
                                    }()
                                    Text("(\(disp.originX), \(disp.originY))\(heightNote)")
                                        .font(.system(size: 7, weight: (!disp.isMain && upPx != 0) ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle((!disp.isMain && upPx != 0) ? Color.cyan : .secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
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
                                    let effectiveScaleY = isVerticallyStacked ? scale : (scale * visualVerticalMultiplier)
                                    let deltaDisplayY = -value.translation.height / max(effectiveScaleY, 0.0001)
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

                    // Miniature cyan reference line when Cross-Screen Alignment Ruler is active
                    if isInteractiveEditor && manager.showAlignmentGuide {
                        let lineY = centerY
                        Path { path in
                            path.move(to: CGPoint(x: offsetX, y: lineY))
                            path.addLine(to: CGPoint(x: offsetX + renderedW, y: lineY))
                        }
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                        .zIndex(20)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: isInteractiveEditor ? 132 : (isPreviewCard ? 112 : 102))
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
