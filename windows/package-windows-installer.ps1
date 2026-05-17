$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "dist\windows\PortalWindows.exe"
$packageDir = Join-Path $root "dist\Portal-Windows-installer"
$zip = Join-Path $root "dist\Portal-Windows-installer.zip"

if (-not (Test-Path $exe)) {
  throw "PortalWindows.exe is missing. Run .\windows\build-windows-exe.ps1 first."
}

Remove-Item -Recurse -Force $packageDir -ErrorAction SilentlyContinue
Remove-Item -Force $zip -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $packageDir | Out-Null

Copy-Item -Force $exe (Join-Path $packageDir "PortalWindows.exe")
Copy-Item -Force (Join-Path $PSScriptRoot "install-portal.ps1") (Join-Path $packageDir "install-portal.ps1")
Copy-Item -Force (Join-Path $PSScriptRoot "uninstall-portal.ps1") (Join-Path $packageDir "uninstall-portal.ps1")

@"
# Portal Windows Installer

Run from PowerShell:

.\install-portal.ps1 -Launch

Default install location:

%LOCALAPPDATA%\Programs\Portal

The installer creates:

- Start Menu shortcut: Portal
- Desktop shortcut: Portal
- Startup shortcut: Portal

To skip shortcuts:

.\install-portal.ps1 -NoDesktopShortcut -NoStartupShortcut

To uninstall:

Run "Uninstall Portal" from the Start Menu, or:

%LOCALAPPDATA%\Programs\Portal\uninstall-portal.ps1
"@ | Set-Content -Encoding UTF8 (Join-Path $packageDir "README-Windows-Installer.txt")

Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zip -Force
Write-Host "Packaged: $zip"
