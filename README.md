# HyperDock for Apple Silicon

**English** | [简体中文](README.zh-CN.md)

A native Apple Silicon reimplementation of HyperDock's Dock-hover window previews.
Hover a running application's Dock icon to see its open windows—including minimized
windows and windows on other Spaces—then click a preview to switch to it.

This project was created through reverse engineering and behavioural observation of
the discontinued HyperDock 1.8. It is an independent Swift implementation, not the
original HyperDock source code. See [Original HyperDock notice](ORIGINAL_HYPERDOCK_NOTICE.md).

| | |
|---|---|
| **Version** | 0.5 |
| **Platform** | macOS 26.0+, Apple Silicon (`arm64`) |
| **Bundle ID** | `com.hyperdock.HyperDock` |
| **Languages** | English, Simplified Chinese |

## Features

- Dock-hover bubbles with fixed-size, aspect-fitted window thumbnails
- Windows from other Spaces and minimized/hidden windows
- Full-size preview on hover
- Click to raise a window; hover close button; plus button for a new window
- Keyboard navigation and scroll gestures within the preview bubble
- Five appearances: Automatic, Classic, Vibrant Light, Vibrant Dark, and native Liquid Glass
- Adjustable preview size, columns, animation, labels, timing, and live refresh
- Optional instant reveal for an auto-hidden Dock
- Menu-bar controls, launch at login, and a global Settings shortcut

The project intentionally does **not** include HyperDock's window snapping, tiling,
modifier-drag window management, or per-application Dock click actions.

The Liquid Glass theme uses the system glass renderer, so its transparency and contrast
follow the Liquid Glass choice in **System Settings → Appearance** rather than a separate
in-app opacity value.

## Original HyperDock assets

The repository includes artwork extracted from HyperDock 1.8 under
`Sources/HyperDock/Resources/OriginalHyperDock/`. The four legacy appearance themes
currently use the original close-button images; Liquid Glass is entirely code-native and
does not use any of these images at runtime.

The original artwork remains copyright © 2018 Christian Baumgart, all rights reserved,
and is **not** covered by this project's MIT License. See the
[asset and provenance notice](ORIGINAL_HYPERDOCK_NOTICE.md) and the copyright file stored
with the assets. A native SF Symbols fallback keeps the project buildable if the old
close-button files are removed.

## Requirements and permissions

- macOS 26.0 or later on Apple Silicon
- Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- **Accessibility**: required to read Dock tiles and raise or close windows
- **Screen Recording**: optional, for thumbnails and window titles

## Build and install

The downloadable 0.5 DMG is locally signed but not Apple-notarized. If Gatekeeper blocks
the downloaded image, right-click it and choose **Open**, or clear its quarantine flag:

```bash
xattr -d com.apple.quarantine ~/Downloads/HyperDock.dmg
```

```bash
# Recommended once: creates a stable local identity so TCC permissions survive rebuilds
./scripts/setup-signing.sh

# Generate, build, sign, and install /Applications/HyperDock.app
./scripts/build.sh

# Release build
CONFIG=Release ./scripts/build.sh

# Launch through Launch Services
open /Applications/HyperDock.app
```

Do not launch the executable directly from a terminal: that can make macOS attribute
privacy permission behaviour to the terminal rather than to the app.

Run tests with `swift test`.

## Project layout

```
Sources/HyperDock/
├── App/          # lifecycle and menu-bar item
├── Core/         # preferences, permissions, localization, app actions
├── Dock/         # Dock hover detection and optional auto-hide tweak
├── Settings/     # settings and onboarding
├── System/       # Accessibility and macOS window/Space integration
├── Thumbnails/   # ScreenCaptureKit capture and cache
├── UI/           # preview bubble, cards, and full-size preview
└── Windows/      # window discovery and model
```

The Xcode project is generated from `project.yml`; generated projects, build products,
and the original preference-pane research copy are intentionally ignored.

## License

The independently written source code is available under the [MIT License](LICENSE).
The HyperDock name and any original HyperDock artwork remain the property of their
respective owner and are not licensed under MIT.
