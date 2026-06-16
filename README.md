# Portal

Portal is a LAN-based input handoff tool for people who work on a Windows machine and want to control a nearby Mac without reaching for a second keyboard and mouse.

It is not remote desktop. Portal forwards input events over the local network and injects them on macOS so the Mac behaves like a directly connected machine.

## What Portal does

- Lets a Windows workstation drive a Mac over the same LAN
- Uses edge-based cursor handoff instead of a modal remote session
- Shows a native macOS control app for setup, pairing, status, and layout
- Ships a Windows companion app and installer package
- Includes fast local installer sharing from the Mac app

## Current status

Portal is an active experimental project.

Today it is best described as:

- a working local-network prototype
- focused on macOS + Windows workflows
- optimized for low-latency cursor and keyboard handoff
- still evolving in packaging, security, and product polish

## How it works

1. The Mac app starts a local listener on your network.
2. The Windows app connects to the Mac using its IP address and port.
3. When your cursor reaches the configured screen edge on Windows, Portal switches control to the Mac.
4. Moving back to the return edge hands control to Windows again.

## Repository layout

```text
mac/PortalMac/          Swift macOS app
windows/                Windows build, packaging, and install scripts
script/                 Cross-machine build and helper scripts
docs/                   Project notes and release audits
dist/                   Local build output (ignored by git)
```

## Features

### macOS app

- Native SwiftUI desktop interface
- Live connection and activity status
- Windows companion installer sharing
- LAN scan flow for Windows candidates
- Display arrangement preview
- Accessibility permission onboarding

### Windows companion

- Connects to a Mac listener by IP and port
- Sends mouse, keyboard, and scroll events
- Supports packaging into an installable Windows bundle

## Requirements

### Mac

- macOS 13 or newer
- Accessibility permission for Portal
- Same local network as the Windows machine

### Windows

- Windows 10 or newer
- .NET 8 SDK if you want to build from source
- Same local network as the Mac

## Quick start

### 1. Build and run the Mac app

From the repository root:

```bash
./script/build_and_run.sh
```

The app bundle is created at:

```text
dist/Portal.app
```

When Portal launches, grant Accessibility access if macOS asks for it.

### 2. Build the Windows app

On Windows, from this repository:

```powershell
.\windows\build-windows-exe.ps1
```

The executable will be created at:

```text
dist\windows\PortalWindows.exe
```

### 3. Connect Windows to the Mac

- Open `Portal` on the Mac
- Note the Mac IP and listener port
- Open the Windows companion
- Enter the Mac IP and port
- Start the companion

### 4. Use edge handoff

Move the cursor to the configured edge on Windows to transfer control to the Mac. Move to the return edge on the Mac to switch back.

## Windows installer flow

Portal can serve the Windows installer directly from the Mac app.

### Build the installer package on Windows

```powershell
.\windows\package-windows-installer.ps1
```

This creates:

```text
dist\Portal-Windows-installer.zip
```

### Install on Windows

Unzip the package and run:

```powershell
.\install-portal.ps1 -Launch
```

Optional flags:

```powershell
.\install-portal.ps1 -NoDesktopShortcut -NoStartupShortcut
```

## Development

### Run macOS tests

```bash
cd mac/PortalMac
swift test
```

### Remote Windows build from the Mac

Prepare the Windows machine once:

```powershell
.\windows\setup-remote-build.ps1
```

Then from the Mac:

```bash
./script/build_windows_remote.sh user@windows-ip
```

Or save the target:

```bash
export PORTAL_WIN_TARGET=user@windows-ip
./script/build_windows_remote.sh
```

Restart the visible Windows app:

```bash
PORTAL_WIN_TARGET=user@windows-ip ./script/restart_windows_omerkunul.sh
```

Build and restart together:

```bash
PORTAL_WIN_TARGET=user@windows-ip ./script/build_and_restart_windows_omerkunul.sh
```

## Permissions and system behavior

Portal relies on macOS Accessibility APIs to inject input on the Mac side.

The current prototype also includes an optional AWDL tuning flow to reduce Wi‑Fi latency side effects. That path is useful for local testing, but it is one of the reasons the current app is not suitable for Mac App Store distribution in its present form.

See:

- [docs/mac-app-store-readiness.md](docs/mac-app-store-readiness.md)

## Limitations

- This is not an encrypted transport yet
- Multi-monitor behavior is still being refined
- Keyboard mapping is intentionally narrow today
- Clipboard and file transfer are not complete product features yet
- The Windows executable must be built on Windows because it targets `net8.0-windows`

## Open source plan

Portal is being published as an open source project so the architecture, experiments, and cross-platform control model can evolve in the open.

Near-term priorities:

- cleaner onboarding
- safer packaging
- stronger transport security
- better multi-display support
- clearer distribution model for advanced macOS control features

## Contributing

Contributions are welcome.

Start here:

- [CONTRIBUTING.md](CONTRIBUTING.md)

## License

This project is released under the MIT License.

See:

- [LICENSE](LICENSE)
