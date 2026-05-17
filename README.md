# Portal

Small app pair for sharing the Windows-attached mouse/keyboard with a Mac over the same LAN.

This is not remote desktop. It sends input events over TCP and the Mac injects them as native Quartz events.

## App Builds

- Mac app output: `dist/Portal.app`
- Windows app project: `windows/PortalWindows`
- Windows exe build script: `windows/build-windows-exe.ps1`

The older Python MVP files are still included as a fallback, but the app builds are the main path now.

## Use on the Mac

Grant the terminal app Accessibility permission first:

`System Settings -> Privacy & Security -> Accessibility`

If you run the packaged app, grant Accessibility permission to `Portal`.

```bash
./script/build_and_run.sh
```

Portal starts listening automatically.

Find the Mac IP to enter on Windows:

```bash
ipconfig getifaddr en0
```

### AWDL Permission and Startup Flow

AWDL can interrupt low-latency Wi-Fi mouse movement. Portal can toggle AWDL from
the Mac app, but macOS normally asks for an admin password each time. The app now
uses a one-time permission flow:

- On first `Start`, Portal asks once for admin permission and installs a narrow
  sudoers rule.
- After that, `Start` disables AWDL without a password.
- When Portal stops or quits, it enables AWDL again without a password.

You can also install the same narrow sudoers rule manually:

```bash
./script/install_awdl_sudoers.sh
```

After that, the Mac app can run only these two commands without prompting:

- `/sbin/ifconfig awdl0 down`
- `/sbin/ifconfig awdl0 up`

Remove the rule with:

```bash
./script/uninstall_awdl_sudoers.sh
```

## Build the Windows app

On Windows, install the .NET 8 SDK, then run PowerShell from this folder:

```powershell
.\windows\build-windows-exe.ps1
```

The exe will be created at:

`dist\windows\PortalWindows.exe`

Open it, enter the Mac IP and port, then press `Start`.

For best capture behavior on Windows, run it as Administrator.

## Install the Windows app

After building the exe, create the installable package:

```powershell
.\windows\package-windows-installer.ps1
```

The package is created at:

`dist\Portal-Windows-installer.zip`

Unzip it on Windows and run:

```powershell
.\install-portal.ps1 -Launch
```

This installs Portal to:

`%LOCALAPPDATA%\Programs\Portal`

It also creates Start Menu, Desktop, and startup shortcuts. To skip those:

```powershell
.\install-portal.ps1 -NoDesktopShortcut -NoStartupShortcut
```

## Remote Windows Build From Mac

To avoid copying the project back and forth, prepare the Windows machine once:

```powershell
.\windows\setup-remote-build.ps1
```

Then build from the Mac:

```bash
./script/build_windows_remote.sh user@windows-ip
```

The Mac will copy the Windows project to the Windows machine, run the Windows build there, and fetch the exe back to:

`dist/windows/PortalWindows.exe`

For an even faster loop, leave this running once on the Windows desktop:

```powershell
.\windows\dev-watch-run.ps1
```

After that, every remote build from the Mac will update the exe under `PortalBuild` and the watcher will restart `PortalWindows.exe` automatically on the Windows desktop.

Alternatively install the interactive restart task once:

```powershell
.\windows\install-restart-task.ps1
```

Then from the Mac you can restart the visible Windows app:

```bash
./script/restart_windows_omerkunul.sh
```

Or build and restart in one step:

```bash
./script/build_and_restart_windows_omerkunul.sh
```

You can also save the target:

```bash
export PORTAL_WIN_TARGET=user@windows-ip
./script/build_windows_remote.sh
```

## Controls

Use the wired mouse/keyboard on Windows. Move the cursor to the selected Windows screen edge to enter Mac control. Move the Mac cursor to the opposite edge to return to Windows.

Emergency quit on Windows host:

`Ctrl + Alt + Backspace`

## Performance Stats

Both apps now show live stats:

- Windows shows raw mouse samples per second and sent move packets.
- Mac shows received move packets per second, raw samples per second, average/max packet interval, click count, key count and scroll count.

Mouse movement defaults to immediate raw forwarding for lower latency. Stats stay throttled so the UI does not slow the pointer path.

## Current MVP Limits

- Windows edge detection uses the current Windows monitor. Mac movement is currently restored to the main Mac display while multi-monitor support is stabilized.
- Basic keyboard mapping only, enough for letters, numbers, arrows, enter, escape, delete, tab, space, modifiers and common punctuation.
- No encryption yet.
- No clipboard or file transfer yet.
- The Windows exe must be built on Windows because it targets `net8.0-windows`.
