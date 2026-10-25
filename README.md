# DisplaySaver for macOS

**DisplaySaver** is a lightweight, native macOS menu bar utility that saves your multi-monitor arrangement, resolutions, refresh rates, scaling (HiDPI), orientations, and mirroring settings—and automatically locks and restores them whenever macOS tries to rearrange your screens on reboot, wake from sleep, or TV/HDMI hotplug events.

---

## ✨ Features

- **Automatic Display Layout Lock**: Listens to `CoreGraphics` display reconfiguration callbacks, system/screen wake events, and a background watchdog to automatically restore your saved layout if macOS shifts monitor origins, drops refresh rates (e.g., 60Hz → 30Hz on mirrored TVs), or breaks mirroring.
- **Two-Phase Mirror & Refresh Rate Restoration**: Safely restores hardware mirror sets (ensuring your primary monitor remains the Mirror Master at full refresh rate, such as 240Hz, while locking mirrored TVs/secondary displays to their target 60Hz native mode without triggering CoreGraphics `1010` transaction conflicts).
- **HDMI / TV Power-Transition Protection**: Prevents secondary or primary monitors from blanking out when a mirrored TV is turned off or on.
- **Interactive Drag-and-Drop Layout Editor**: Click **Edit Layout** right inside the menu bar popover or app window to visually drag monitors around (with magnetic edge-to-edge snapping and one-click **Swap L/R**) and save directly to your active profile.
- **Multiple Named Profiles**: Save different monitor setups (e.g., *Desk Setup*, *TV Mirror*, *Gaming*) and switch between them with one click.
- **Smart Menu Bar & Dock Integration**:
  - Single-click the menu bar icon (`lock.display`) to open the quick popover.
  - Double-click (or right-click) the menu bar icon to open the standalone **DisplaySaver** window with a Dock icon.
  - Closing the window via the red close button (`✕`) hides the Dock icon while keeping DisplaySaver running silently in the background.
  - Full compatibility with **Bartender** and **macOS 27** (automatically installs and runs from `/Applications/DisplaySaver.app`).
- **Launch at Login**: Built-in toggle to start automatically when you log in.

---

## 📦 Installation

### Option 1: Download Prebuilt Installer (`.dmg` or `.pkg`)
Download the latest release from the [**Releases**](../../releases) page:
- **`DisplaySaver-1.0.0.dmg`** *(Recommended)*: Open the disk image and drag **DisplaySaver.app** into your **Applications** folder.
- **`DisplaySaver-1.0.0-Installer.pkg`**: Double-click to run the standard macOS Installer wizard, which installs **DisplaySaver.app** directly into `/Applications`.

### Option 2: Build from Source
Requires macOS 13.0+ and Xcode Command Line Tools (`swiftc`).

```bash
git clone https://github.com/igotkilled/DisplaySaver.git
cd DisplaySaver
./build.sh
```

To build both the `.dmg` disk image and `.pkg` installer package locally:
```bash
./package.sh
```

---

## 🛠 How It Works

DisplaySaver uses native macOS frameworks (`CoreGraphics`, `CoreDisplay`, `IOKit`, and `MonitorPanel`) to query and persist each display's:
- Persistent `CFUUID` (`CGDisplayCreateUUIDFromDisplayID`) & fallback hardware vendor/model/serial ID (`ext-vendor-model-serial`)
- Global coordinate origin `(originX, originY)` and Main display status `(0, 0)`
- Logical resolution (`width × height`), physical pixel resolution (`pixelWidth × pixelHeight` for HiDPI), and `ioDisplayModeID`
- Refresh rate (`Hz`) and rotation (`0°`, `90°`, `180°`, `270°`)
- Mirror master UUID (`CGDisplayMirrorsDisplay` / `CGConfigureDisplayMirrorOfDisplay`)

Profiles are stored as human-readable JSON in `~/Library/Application Support/DisplaySaver/profiles.json`.

---

## 📄 License

Released under the [MIT License](LICENSE).
