import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var manager: DisplayManager
    @ObservedObject var loginManager: LaunchAtLoginManager
    var onOpenDashboardWindow: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: Header & Lock Status
            HStack(spacing: 8) {
                Image(systemName: manager.autoEnforceLayout ? "lock.display" : "display.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(manager.autoEnforceLayout ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("DisplaySaver")
                        .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusSummaryText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    manager.refreshCurrentDisplays()
                    if let active = manager.activeProfile {
                        manager.applyProfile(active)
                    }
                } label: {
                    Label("Restore Now", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(manager.activeProfile == nil)
                .help("Immediately apply the active saved display layout")
            }

            // MARK: Visual Layout Diagram & Interactive Editor
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(manager.isEditingLayout ? "DRAG DISPLAYS TO ARRANGE" : "DISPLAY ARRANGEMENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(manager.isEditingLayout ? Color.accentColor : .secondary)

                    Spacer()

                    if manager.isEditingLayout {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                manager.swapLeftRightInEditor()
                            }
                        } label: {
                            Label("Swap L/R", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Flip secondary display between Left and Right of Main display")

                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                manager.cancelEditingLayout()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Save & Apply") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                manager.saveAndApplyEditedLayout()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                manager.beginEditingLayout()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                                Text("Edit Layout")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Manually drag displays to rearrange their order and save to the active profile")
                    }
                }

                DisplayLayoutPreview(manager: manager)
            }

            // MARK: Current Connected Displays
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CURRENT DISPLAYS (\(manager.currentDisplays.count))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        manager.refreshCurrentDisplays()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh current display state")
                }

                ForEach(manager.currentDisplays) { disp in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: disp.mirrorsUUID != nil ? "rectangle.on.rectangle" : (disp.isMain ? "star.fill" : "display"))
                            .font(.system(size: 10))
                            .foregroundStyle(disp.isMain ? .yellow : (disp.mirrorsUUID != nil ? .orange : .secondary))
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(disp.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                if let masterUUID = disp.mirrorsUUID,
                                   let master = manager.currentDisplays.first(where: { $0.uuid == masterUUID }) {
                                    Text("Mirrors \(master.name)")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(disp.resolutionSummary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // MARK: Saved Profiles Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SAVED PROFILES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()

                    if let active = manager.activeProfile {
                        Button {
                            manager.updateProfile(active, withCurrentDisplays: true)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Update '\(active.name)'")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Overwrite '\(active.name)' with the current display configuration")
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            manager.isCreatingProfile.toggle()
                            manager.newProfileName = ""
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                            Text("New")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if manager.isCreatingProfile {
                    HStack(spacing: 6) {
                        TextField("Profile name (e.g. Desk Setup)", text: $manager.newProfileName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit {
                                commitNewProfile()
                            }
                        Button("Save") {
                            commitNewProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            manager.isCreatingProfile = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }

                ForEach(manager.savedProfiles) { profile in
                    let isActive = manager.activeProfile?.id == profile.id
                    HStack(spacing: 6) {
                        Button {
                            manager.activeProfileID = profile.id
                            manager.applyProfile(profile)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                                    .font(.system(size: 12))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    Text("\(profile.displays.count) displays • Saved \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button("Apply") {
                            manager.activeProfileID = profile.id
                            manager.applyProfile(profile)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        if manager.savedProfiles.count > 1 {
                            Button {
                                manager.deleteProfile(profile)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete profile")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                }
            }

            Divider()

            // MARK: Automation Settings
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $manager.autoEnforceLayout) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Lock & Auto-Restore Display Layout")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Automatically fix arrangement, resolution & mirroring on wake or drift")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Toggle(isOn: Binding(
                    get: { loginManager.isEnabled },
                    set: { loginManager.setEnabled($0) }
                )) {
                    Text("Launch at Login")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
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
                    .font(.system(size: 10))
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
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open detach window")
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private var statusColor: Color {
        if !manager.autoEnforceLayout {
            return .orange
        }
        return manager.doesCurrentMatchActiveProfile ? .green : .yellow
    }

    private var statusSummaryText: String {
        guard let active = manager.activeProfile else {
            return "No profile saved"
        }
        if manager.doesCurrentMatchActiveProfile {
            return "Locked to '\(active.name)' • In Sync"
        } else {
            return "Drifted from '\(active.name)'"
        }
    }

    private func commitNewProfile() {
        let name = manager.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.saveCurrentAsProfile(name: name.isEmpty ? "Layout \(manager.savedProfiles.count + 1)" : name)
        manager.newProfileName = ""
        manager.isCreatingProfile = false
    }
}
