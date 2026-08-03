# HyperDock

**English** | [简体中文](README.zh-CN.md)

Hover a Dock icon to preview every open window of that app — including minimized ones and windows on other Spaces — then click through to the one you want.

HyperDock is a menu-bar (agent) app for macOS: no Dock tile of its own, runs in the background, and opens Settings from the menu-bar icon or a global hotkey.

| | |
|---|---|
| **Version** | 1.0.0 |
| **Platform** | macOS 26.0+, Apple Silicon (`arm64`) |
| **Bundle ID** | `com.hyperdock.HyperDock` |
| **Languages** | English, Simplified Chinese |

---

## Features

### Window previews
- Hover any Dock icon to show a bubble of live window thumbnails
- Include windows from all Spaces, minimized/hidden windows, and (optionally) palettes
- Full-size preview when you hover a card longer
- Click a card to raise that window; optional close button per card
- Space indicator for off-Space windows

### Dock item shortcuts
- Bind modifier + mouse button (left / middle / right) to actions such as Quit, Hide, New Window, Show All Windows, Minimize All, Relaunch
- Global rules for every Dock icon, plus per-app overrides

### Window management
- **Edge snap** while dragging with the move modifiers held (disables system drag-to-edge tiling while active so the two do not fight)
- **Keyboard snap** (default ⌃⌥ + arrows / Return / keypad / `G` for grid tile)
- **Move** windows by dragging with modifiers (default ⌃⌥)
- **Resize** windows by dragging with modifiers (default ⌃⌥⇧)
- Configurable tile grid (columns, rows, gap)

### Appearance & behaviour
- Light / Dark / Automatic theme
- Bubble size, previews per row, animation, triangle pointer, highlight gradient
- Launch at login, hide menu-bar icon (restored on next launch), open Settings from anywhere (default ⌃⌥⌘H)

---

## Requirements

- **macOS 26.0** or later
- **Apple Silicon** Mac
- **Xcode** with command-line tools (for building from source)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`)

### Permissions

| Permission | Required? | Purpose |
|---|---|---|
| **Accessibility** | Yes | Read Dock tiles; raise, close, move, and resize windows |
| **Screen Recording** | Optional | Live thumbnails and window titles |

Without Accessibility, HyperDock cannot operate. Without Screen Recording, previews still work for switching, but thumbnails and titles are limited.

Grant both in **System Settings → Privacy & Security**. The first launch shows a welcome flow that walks through this.

---

## Install (from source)

```bash
# Optional but recommended: stable local signing so Accessibility / Screen Recording
# survive rebuilds (otherwise every rebuild can reset TCC grants for ad-hoc signed apps)
./scripts/setup-signing.sh

# Build (Debug) and install to /Applications/HyperDock.app
./scripts/build.sh

# Or a Release build
CONFIG=Release ./scripts/build.sh

# Launch via Launch Services (do not run the binary from a shell)
open /Applications/HyperDock.app
```

> **Important:** Starting the binary from a terminal inherits the *terminal’s* TCC grants, so permissions will look granted when they are not. Always use `open` or double-click the app.

### Release package (DMG)

```bash
./scripts/release.sh
```

Produces `dist/HyperDock.dmg`. If a **Developer ID Application** certificate and Notary credentials (`HyperDockNotary` profile) are available, the script also signs and notarizes for distribution. Otherwise it packages a locally signed image suitable for your own machines.

GitHub Actions builds on `main` publish the same DMG on [Releases](../../releases). Those CI builds are typically **ad-hoc signed** (no Developer ID on the runner). After downloading a DMG from the browser or AirDrop, Gatekeeper may block it because of the quarantine flag. Clear it before opening:

```bash
xattr -d com.apple.quarantine /path/to/HyperDock.dmg
```

Then open the disk image and drag HyperDock into Applications as usual.

### App icon

```bash
swift scripts/make-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Sources/HyperDock/Resources/AppIcon.icns
```

---

## Usage

1. Install and open HyperDock.
2. Complete the welcome steps and grant **Accessibility** (and optionally **Screen Recording**).
3. Hover Dock icons to open the preview bubble; click a window card to switch to it.
4. Open Settings from the menu-bar icon, or with the global hotkey (default **⌃⌥⌘H**).
5. If the menu-bar icon is hidden, launch HyperDock again (or use the hotkey) to restore access.

---

## Project layout

```
hyperdock/
├── project.yml                 # XcodeGen project definition
├── scripts/
│   ├── build.sh                # Generate project, build, install, sign
│   ├── release.sh              # Release build + DMG (+ optional notarize)
│   ├── setup-signing.sh        # Local self-signed identity for stable TCC
│   └── make-icon.swift         # Generate AppIcon.iconset
├── Sources/HyperDock/
│   ├── App/                    # Entry point, status item
│   ├── Core/                   # Preferences, permissions, localization, login item
│   ├── Dock/                   # Dock watching, shortcuts, Dock tweaks
│   ├── Settings/               # Settings + welcome UI
│   ├── System/                 # Accessibility (AX), CGS private SPI, Mission Control
│   ├── Thumbnails/             # ScreenCaptureKit thumbnails
│   ├── UI/                     # Preview bubble, tiles, full-size preview
│   ├── Windows/                # Snap, grid, window index, actions
│   └── Resources/              # Info.plist, entitlements, icon, strings
└── Tests/HyperDockTests/       # Contract tests (lifecycle, input)
```

The Xcode project is **generated** on every build (`xcodegen generate`). Do not commit `HyperDock.xcodeproj/`, `.build/`, or `dist/` — they are gitignored.

---

## Development

```bash
# Generate the Xcode project only
xcodegen generate

# Build with the script (recommended)
./scripts/build.sh

# Open in Xcode after generating
open HyperDock.xcodeproj
```

### Notes

- **App Sandbox is off.** Sandboxed processes cannot use Accessibility against other apps.
- **Signing:** `scripts/build.sh` prefers the “HyperDock Local Signing” identity from `setup-signing.sh`, then falls back to ad-hoc. Certificate-based signing keeps TCC grants across rebuilds.
- **Swift 6**, default actor isolation `MainActor`, strict concurrency.
- Interface language can follow the system or force English / Simplified Chinese (no restart).

---

## Settings overview

| Pane | Contents |
|---|---|
| **General** | Launch at login, previews on/off, activation delay, include filters, order, hover behaviour, reset all |
| **Appearance** | Theme, labels, bubble layout, animation |
| **Dock Items** | Modifier + click shortcuts (global and per-app) |
| **Window Management** | Edge snap, keyboard snap, move/resize modifiers, tile grid |
| **Advanced** | Pause HyperDock, timing, thumbnail quality/live refresh, Dock autohide speed, settings hotkey |
| **About** | Version, language, permission status |

---

## Uninstall

1. Quit HyperDock from the menu-bar icon (or disable launch at login in Settings).
2. Remove the app: `rm -rf /Applications/HyperDock.app`
3. Optional cleanup:

```bash
# Preferences
defaults delete com.hyperdock.HyperDock 2>/dev/null || true
```

If you used “Reveal a hidden Dock instantly”, turn that option off before quitting so Dock defaults can be restored, or reset settings from **General → Reset All Settings…**.

---

## License

This project is licensed under the [MIT License](LICENSE).
