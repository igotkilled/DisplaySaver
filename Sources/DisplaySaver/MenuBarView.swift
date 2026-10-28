import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: DisplayManager
    @ObservedObject var loginManager: LaunchAtLoginManager
    var onOpenDashboardWindow: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: Header & Lock Status
            HStack(spacing: 10) {
                Image(systemName: manager.autoEnforceLayout ? "lock.display" : "display.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(manager.autoEnforceLayout ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("DisplaySaver")
                            .font(.system(size: 14, weight: .bold))
                        Text("v1.1")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.16), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusSummaryText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .onHover { hovering in
                        manager.isHoveringHeaderStatus = hovering
                    }
                    .help(statusSummaryText)
                    .overlay(alignment: .bottomLeading) {
                        if manager.isHoveringHeaderStatus, let active = manager.activeProfile {
                            floatingTooltipBadge(text: "Locked to: \(active.name)")
                                .offset(y: 24)
                        }
                    }
                }
                .zIndex(50)

                Spacer(minLength: 8)

                Button {
                    manager.refreshCurrentDisplays()
                    if let active = manager.activeProfile {
                        manager.applyProfile(active)
                    }
                } label: {
                    Label("Restore Now", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(manager.activeProfile == nil)
                .help("Immediately apply the active saved display layout")
            }
            .zIndex(50)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    // MARK: Visual Layout Diagram & Full Interactive Editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(manager.isEditingLayout ? "EDIT DISPLAY SETUP" : "CURRENT DISPLAY ARRANGEMENT")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(manager.isEditingLayout ? Color.accentColor : .secondary)

                            Spacer()

                            if manager.isEditingLayout {
                                if manager.editingDisplays.contains(where: { $0.mirrorsUUID != nil }) {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            manager.unmirrorAllInEditor()
                                        }
                                    } label: {
                                        Label("Unmirror All", systemImage: "rectangle.split.3x1")
                                            .font(.system(size: 10.5, weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                    .controlSize(.small)
                                    .help("Stop mirroring and separate all screens into extended displays")
                                }

                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.swapLeftRightInEditor()
                                    }
                                } label: {
                                    Label("Swap L/R", systemImage: "arrow.left.arrow.right")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Flip horizontal order of extended displays")

                                Button("Cancel") {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.cancelEditingLayout()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.beginEditingLayout()
                                    }
                                } label: {
                                    Label("Edit Layout & Mirroring", systemImage: "slider.horizontal.below.square.and.square.filled")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Configure mirroring, extended displays, arrangement, resolution, and refresh rate")
                            }
                        }

                        DisplayLayoutPreview(manager: manager)

                        if manager.isEditingLayout {
                            editorControlsPanel
                        }
                    }

                    // MARK: Setup Preview & Confirmation Modal Card (when a saved setup is clicked)
                    if let previewProfile = manager.previewingProfile {
                        setupPreviewConfirmationCard(for: previewProfile)
                    }

                    // MARK: Current Connected Displays Summary (when not in Edit Mode)
                    if !manager.isEditingLayout {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("CONNECTED DISPLAYS (\(manager.currentDisplays.count))")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    manager.refreshCurrentDisplays()
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Refresh current display state")
                            }

                            ForEach(manager.currentDisplays) { disp in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: disp.mirrorsUUID != nil ? "rectangle.on.rectangle" : (disp.isMain ? "star.fill" : "display"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(disp.isMain ? .yellow : (disp.mirrorsUUID != nil ? .orange : .secondary))
                                        .frame(width: 14)

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        HStack(spacing: 6) {
                                            Text(disp.name)
                                                .font(.system(size: 12, weight: .semibold))
                                            if let masterUUID = disp.mirrorsUUID,
                                               let master = manager.currentDisplays.first(where: { $0.uuid == masterUUID }) {
                                                Text("Mirrors \(master.name)")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Text(disp.resolutionSummary)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Divider()

                    // MARK: Saved Setups Section (Up to 5 Custom Setups)
                    savedSetupsSection

                    Divider()

                    // MARK: Automation Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $manager.autoEnforceLayout) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Lock & Auto-Restore Active Setup")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Automatically fix arrangement, resolution & mirroring on wake or drift")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(isOn: Binding(
                            get: { loginManager.isEnabled },
                            set: { loginManager.setEnabled($0) }
                        )) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }

            Divider()

            // MARK: Footer & Activity Log
            if manager.showActivityLog {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RECENT ACTIVITY")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(manager.eventLog, id: \.self) { entry in
                                Text(entry)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 68)
                }
                Divider()
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.showActivityLog.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(manager.statusMessage)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Click to toggle activity log")

                Spacer()

                if let openWindow = onOpenDashboardWindow {
                    Button {
                        openWindow()
                    } label: {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open detach window")
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 452)
        .frame(minHeight: manager.isEditingLayout ? 640 : 520)
    }

    // MARK: - Xcode-Style Floating Overlay Tooltip (Zero Layout Shift!)

    @ViewBuilder
    private func floatingTooltipBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .darkGray).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            .allowsHitTesting(false)
    }

    // MARK: - Rich Display Editor Panel (Mirroring, Extended, Main, Resolution, Hz, Rotation)

    @ViewBuilder
    private var editorControlsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SELECT A DISPLAY TO CONFIGURE (OR DRAG ABOVE):")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            // Display selector pills for all connected screens (including mirrored screens!)
            HStack(spacing: 6) {
                ForEach(manager.editingDisplays) { disp in
                    let isSelected = (manager.selectedEditingDisplay?.uuid == disp.uuid)
                    Button {
                        manager.selectedEditingDisplayUUID = disp.uuid
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: disp.mirrorsUUID != nil ? "rectangle.on.rectangle" : (disp.isMain ? "star.fill" : "display"))
                                .font(.system(size: 10))
                                .foregroundStyle(isSelected ? .white : (disp.isMain ? .yellow : (disp.mirrorsUUID != nil ? .orange : .secondary)))
                            Text(disp.name)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                            if disp.mirrorsUUID != nil {
                                Text("(Mirror)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .opacity(0.9)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let selected = manager.selectedEditingDisplay {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(selected.name, systemImage: selected.mirrorsUUID != nil ? "rectangle.on.rectangle" : (selected.isMain ? "star.fill" : "display"))
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        if selected.mirrorsUUID != nil {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.setEditingDisplayRole(uuid: selected.uuid, role: .extended)
                                }
                            } label: {
                                Label("Stop Mirroring (Extend)", systemImage: "rectangle.split.2x1")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }

                    // 1. Use As (Main Display / Extended Display / Mirror of...)
                    HStack(spacing: 8) {
                        Text("Use As:")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 82, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { manager.currentRole(for: selected) },
                            set: { newRole in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.setEditingDisplayRole(uuid: selected.uuid, role: newRole)
                                }
                            }
                        )) {
                            Text("Main Display ★").tag(DisplayRoleSelection.main)
                            Text("Extended Display (Separate)").tag(DisplayRoleSelection.extended)
                            ForEach(manager.editingDisplays.filter { $0.uuid != selected.uuid && $0.mirrorsUUID != selected.uuid }) { other in
                                Text("Mirror of \(other.name)").tag(DisplayRoleSelection.mirror(masterUUID: other.uuid))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 260, alignment: .leading)
                        Spacer(minLength: 0)
                    }

                    // 2. Quick Left/Right placement buttons when display is Extended
                    if selected.mirrorsUUID == nil && !selected.isMain {
                        HStack(spacing: 8) {
                            Text("Position:")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 82, alignment: .leading)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.placeEditingDisplayHorizontally(uuid: selected.uuid, placeOnLeft: true)
                                }
                            } label: {
                                Label("Left of Main", systemImage: "arrow.left.to.line")
                                    .font(.system(size: 10.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.placeEditingDisplayHorizontally(uuid: selected.uuid, placeOnLeft: false)
                                }
                            } label: {
                                Label("Right of Main", systemImage: "arrow.right.to.line")
                                    .font(.system(size: 10.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer(minLength: 0)
                        }
                    }

                    // 3. Resolution / Scaling Picker
                    let resOptions = manager.availableResolutionOptions(for: selected)
                    let currentRes = DisplayResolutionOption(
                        width: selected.width,
                        height: selected.height,
                        pixelWidth: selected.pixelWidth,
                        pixelHeight: selected.pixelHeight
                    )
                    HStack(spacing: 8) {
                        Text("Resolution:")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 82, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { currentRes },
                            set: { newOpt in
                                manager.setEditingDisplayResolution(uuid: selected.uuid, option: newOpt)
                            }
                        )) {
                            ForEach(resOptions) { opt in
                                Text(opt.label).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 220, alignment: .leading)
                        Spacer(minLength: 0)
                    }

                    // 4. Refresh Rate Picker
                    let hzOptions = manager.availableRefreshRates(for: selected)
                    let currentHz = Double(Int(selected.refreshRate.rounded()))
                    HStack(spacing: 8) {
                        Text("Refresh Rate:")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 82, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { hzOptions.first(where: { abs($0 - currentHz) <= 1.0 }) ?? hzOptions.first ?? 60.0 },
                            set: { newHz in
                                manager.setEditingDisplayRefreshRate(uuid: selected.uuid, hz: newHz)
                            }
                        )) {
                            ForEach(hzOptions, id: \.self) { hz in
                                Text("\(Int(hz.rounded())) Hz").tag(hz)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160, alignment: .leading)
                        Spacer(minLength: 0)
                    }

                    // 5. Rotation Picker
                    HStack(spacing: 8) {
                        Text("Rotation:")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 82, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { Int(selected.rotation.rounded()) % 360 },
                            set: { deg in
                                manager.setEditingDisplayRotation(uuid: selected.uuid, rotation: Double(deg))
                            }
                        )) {
                            Text("0°").tag(0)
                            Text("90°").tag(90)
                            Text("180°").tag(180)
                            Text("270°").tag(270)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 240, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }

            // Summary + Save/Apply Bar at bottom of Edit Layout
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.accentColor)
                    Text("New Layout: \(DisplayProfile.suggestedName(for: manager.editingDisplays))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if manager.isCreatingProfile && manager.isSavingEditedAsNew {
                    newSetupNamingBox(isFromEditor: true)
                } else {
                    HStack(spacing: 8) {
                        if let active = manager.activeProfile {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.saveAndApplyEditedLayout()
                                }
                            } label: {
                                Label("Update Active Setup & Apply", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Overwrite '\(active.name)' with this edited layout and apply immediately")
                        }

                        if manager.canAddMoreProfiles {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.beginCreatingNewProfile(fromEdited: true)
                                }
                            } label: {
                                Label("Save as New Setup…", systemImage: "plus.square.on.square")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Setup Preview & Confirm Card (Shown when clicking a Saved Setup)

    @ViewBuilder
    private func setupPreviewConfirmationCard(for profile: DisplayProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 12))
                        Text("Setup Preview: \(profile.name)")
                            .font(.system(size: 12, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if profile.name != profile.layoutSummary {
                        Text(profile.layoutSummary)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.previewingProfileID = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Representative miniature display diagram (Screenshot 2 style!)
            DisplayLayoutPreview(
                manager: manager,
                overrideDisplays: profile.displays,
                isPreviewCard: true
            )

            // Compact per-monitor breakdown of this saved setup
            VStack(alignment: .leading, spacing: 3) {
                ForEach(profile.displays) { d in
                    HStack(spacing: 6) {
                        Image(systemName: d.mirrorsUUID != nil ? "rectangle.on.rectangle" : (d.isMain ? "star.fill" : "display"))
                            .font(.system(size: 10))
                            .foregroundStyle(d.isMain ? .yellow : (d.mirrorsUUID != nil ? .orange : .secondary))
                            .frame(width: 12)
                        Text(d.name)
                            .font(.system(size: 10.5, weight: .semibold))
                        if let masterUUID = d.mirrorsUUID,
                           let master = profile.displays.first(where: { $0.uuid == masterUUID }) {
                            Text("• Mirrors \(master.conciseName)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                        } else if d.isMain {
                            Text("• Main")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("• Extended")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(d.width)×\(d.height) @ \(Int(d.refreshRate.rounded()))Hz")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)

            Divider()

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.beginEditingLayout(from: profile)
                    }
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.previewingProfileID = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.activeProfileID = profile.id
                        manager.previewingProfileID = nil
                        manager.applyProfile(profile)
                    }
                } label: {
                    Label("Yes, Apply Setup", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
        )
    }

    // MARK: - Saved Setups List & Naming Prompt

    @ViewBuilder
    private var savedSetupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SAVED SETUPS (\(manager.savedProfiles.count)/\(DisplayManager.maxSavedProfiles))")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()

                if let active = manager.activeProfile, !manager.isEditingLayout {
                    Button {
                        manager.updateProfile(active, withCurrentDisplays: true)
                    } label: {
                        Label("Update Active", systemImage: "square.and.arrow.down")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Overwrite '\(active.name)' with the current live display configuration")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if manager.isCreatingProfile && !manager.isSavingEditedAsNew {
                            manager.isCreatingProfile = false
                        } else {
                            manager.beginCreatingNewProfile(fromEdited: false)
                        }
                    }
                } label: {
                    Label(manager.canAddMoreProfiles ? "New Setup" : "Max 5 Setups", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!manager.canAddMoreProfiles)
                .help(manager.canAddMoreProfiles
                      ? "Save current display arrangement as a new setup (up to 5)"
                      : "Maximum of 5 custom setups saved. Update or delete an existing setup to add another.")
            }

            if manager.isCreatingProfile && !manager.isSavingEditedAsNew {
                newSetupNamingBox(isFromEditor: false)
            }

            Text("Click a setup to preview it, or use the action buttons (Preview, Edit, Apply):")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            ForEach(manager.savedProfiles) { profile in
                let isActive = manager.activeProfile?.id == profile.id
                let isPreviewing = manager.previewingProfileID == profile.id
                let isRenaming = manager.renamingProfileID == profile.id
                let isHovered = (manager.hoveredProfileID == profile.id)
                let hasHoveredButtonInRow = (manager.hoveredButtonTag?.hasSuffix(profile.id.uuidString) == true)

                VStack(alignment: .leading, spacing: 4) {
                    if isRenaming {
                        HStack(spacing: 6) {
                            TextField("Setup name", text: $manager.renamingProfileText)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .onSubmit {
                                    manager.renameProfile(profile, to: manager.renamingProfileText)
                                }
                            Button("Auto-Name") {
                                manager.renamingProfileText = profile.layoutSummary
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .help("Fill with auto-generated layout description: \(profile.layoutSummary)")

                            Button("Layout…") {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.renamingProfileID = nil
                                    manager.beginEditingLayout(from: profile)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .help("Open this setup in the Layout & Mirroring editor")

                            Button("Save") {
                                manager.renameProfile(profile, to: manager.renamingProfileText)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .fixedSize()

                            Button("Cancel") {
                                manager.renamingProfileID = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                        }
                    } else {
                        // Single-line compact row with VLC-style rounded-box icon buttons: Preview, Edit, Apply
                        HStack(spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    manager.previewingProfileID = (manager.previewingProfileID == profile.id) ? nil : profile.id
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                                        .font(.system(size: 13, weight: .semibold))

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        HStack(spacing: 5) {
                                            Text(profile.name)
                                                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)

                                            if isActive {
                                                Text("ACTIVE")
                                                    .font(.system(size: 8.5, weight: .bold))
                                                    .padding(.horizontal, 4.5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.22), in: Capsule())
                                                    .foregroundStyle(Color.accentColor)
                                                    .fixedSize()
                                            }
                                        }

                                        Text("\(profile.displays.count) displays • Saved \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering {
                                    manager.hoveredProfileID = profile.id
                                } else if manager.hoveredProfileID == profile.id {
                                    manager.hoveredProfileID = nil
                                }
                            }
                            .help(profile.name)

                            // Action Icon Buttons in exact order: 1. Preview (eye), 2. Edit (pencil), 3. Apply (checkmark)
                            HStack(spacing: 5) {
                                // 1. Preview
                                setupActionIconButton(
                                    systemImage: isPreviewing ? "eye.fill" : "eye",
                                    tooltip: isPreviewing ? "Hide Preview" : "Preview",
                                    tag: "preview-\(profile.id.uuidString)",
                                    isHighlighted: isPreviewing,
                                    tint: .cyan
                                ) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.previewingProfileID = (manager.previewingProfileID == profile.id) ? nil : profile.id
                                    }
                                }

                                // 2. Edit
                                setupActionIconButton(
                                    systemImage: "pencil",
                                    tooltip: "Edit",
                                    tag: "edit-\(profile.id.uuidString)",
                                    isHighlighted: false,
                                    tint: .cyan
                                ) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.renamingProfileID = profile.id
                                        manager.renamingProfileText = profile.name
                                    }
                                }

                                // 3. Apply Immediately (without needing to preview first)
                                setupActionIconButton(
                                    systemImage: "checkmark",
                                    tooltip: "Apply Setup",
                                    tag: "apply-\(profile.id.uuidString)",
                                    isHighlighted: isActive && manager.doesCurrentMatchActiveProfile,
                                    tint: .green
                                ) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.activeProfileID = profile.id
                                        manager.previewingProfileID = nil
                                        manager.applyProfile(profile)
                                    }
                                }

                                if manager.savedProfiles.count > 1 {
                                    setupActionIconButton(
                                        systemImage: "trash",
                                        tooltip: "Delete",
                                        tag: "delete-\(profile.id.uuidString)",
                                        isHighlighted: false,
                                        tint: .red
                                    ) {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            manager.deleteProfile(profile)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isPreviewing ? Color.accentColor.opacity(0.16) : (isActive ? Color.accentColor.opacity(0.11) : Color.secondary.opacity(0.06)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isPreviewing ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                // Floating Xcode-style popup tooltip that overlays above the row without pushing ANY UI down!
                .overlay(alignment: .topLeading) {
                    if isHovered && !isRenaming && !hasHoveredButtonInRow {
                        floatingTooltipBadge(text: profile.name)
                            .offset(x: 20, y: -26)
                    }
                }
                .zIndex((isHovered || hasHoveredButtonInRow) ? 40 : 1)
            }
        }
    }

    @ViewBuilder
    private func setupActionIconButton(
        systemImage: String,
        tooltip: String,
        tag: String,
        isHighlighted: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (manager.hoveredButtonTag == tag)
        let activeBorderColor: Color = isHovered
            ? tint
            : (isHighlighted ? tint.opacity(0.9) : Color.primary.opacity(0.42))
        let iconColor: Color = isHovered
            ? tint
            : (isHighlighted ? tint : Color.primary.opacity(0.9))

        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            isHovered
                                ? tint.opacity(0.20)
                                : (isHighlighted ? tint.opacity(0.15) : Color.black.opacity(0.26))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(activeBorderColor, lineWidth: isHovered || isHighlighted ? 1.6 : 1.35)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                manager.hoveredButtonTag = tag
            } else if manager.hoveredButtonTag == tag {
                manager.hoveredButtonTag = nil
            }
        }
        .overlay(alignment: .top) {
            if isHovered {
                floatingTooltipBadge(text: tooltip)
                    .fixedSize()
                    .offset(y: -26)
            }
        }
        .help(tooltip)
    }

    @ViewBuilder
    private func newSetupNamingBox(isFromEditor: Bool) -> some View {
        let suggested = manager.suggestedNameForPendingSave
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Name this display setup (\(manager.savedProfiles.count + 1)/\(DisplayManager.maxSavedProfiles)):")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if manager.newProfileName != suggested {
                    Button("Use Auto-Name") {
                        manager.newProfileName = suggested
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Auto-summary: \(suggested)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField(suggested, text: $manager.newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .onSubmit {
                        commitNewProfile(isFromEditor: isFromEditor)
                    }

                Button(isFromEditor ? "Save & Apply" : "Save Setup") {
                    commitNewProfile(isFromEditor: isFromEditor)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize()

                Button("Cancel") {
                    manager.isCreatingProfile = false
                    manager.isSavingEditedAsNew = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if !manager.autoEnforceLayout {
            return .orange
        }
        return manager.doesCurrentMatchActiveProfile ? .green : .yellow
    }

    private var statusSummaryText: String {
        guard let active = manager.activeProfile else {
            return "No setup saved"
        }
        if manager.doesCurrentMatchActiveProfile {
            return "Locked to '\(active.name)' • In Sync"
        } else {
            return "Drifted from '\(active.name)'"
        }
    }

    private func commitNewProfile(isFromEditor: Bool) {
        let trimmed = manager.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? manager.suggestedNameForPendingSave : trimmed
        if isFromEditor {
            manager.saveEditedLayoutAsNewProfile(name: finalName)
        } else {
            manager.saveCurrentAsProfile(name: finalName)
            manager.newProfileName = ""
            manager.isCreatingProfile = false
        }
    }
}
