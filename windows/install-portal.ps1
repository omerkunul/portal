param(
  [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Portal",
  [switch]$NoDesktopShortcut,
  [switch]$NoStartupShortcut,
  [switch]$Launch
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $scriptDir "PortalWindows.exe"

if (-not (Test-Path $sourceExe)) {
  throw "PortalWindows.exe was not found next to install-portal.ps1"
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null

Get-Process -Name "PortalWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

Copy-Item -Force $sourceExe (Join-Path $InstallDir "PortalWindows.exe")
Copy-Item -Force (Join-Path $scriptDir "uninstall-portal.ps1") (Join-Path $InstallDir "uninstall-portal.ps1")

$shell = New-Object -ComObject WScript.Shell
$exePath = Join-Path $InstallDir "PortalWindows.exe"

$programsDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Portal"
New-Item -ItemType Directory -Force $programsDir | Out-Null

function New-Shortcut {
  param(
    [string]$Path,
    [string]$Target,
    [string]$WorkingDirectory,
    [string]$Description
  )

  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $Target
  $shortcut.WorkingDirectory = $WorkingDirectory
  $shortcut.Description = $Description
  $shortcut.IconLocation = "$Target,0"
  $shortcut.Save()
}

New-Shortcut `
  -Path (Join-Path $programsDir "Portal.lnk") `
  -Target $exePath `
  -WorkingDirectory $InstallDir `
  -Description "Portal Windows host"

New-Shortcut `
  -Path (Join-Path $programsDir "Uninstall Portal.lnk") `
  -Target "powershell.exe" `
  -WorkingDirectory $InstallDir `
  -Description "Uninstall Portal"

$uninstallShortcut = $shell.CreateShortcut((Join-Path $programsDir "Uninstall Portal.lnk"))
$uninstallShortcut.TargetPath = "powershell.exe"
$uninstallShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\uninstall-portal.ps1`""
$uninstallShortcut.WorkingDirectory = $InstallDir
$uninstallShortcut.Save()

if (-not $NoDesktopShortcut) {
  New-Shortcut `
    -Path (Join-Path ([Environment]::GetFolderPath("Desktop")) "Portal.lnk") `
    -Target $exePath `
    -WorkingDirectory $InstallDir `
    -Description "Portal Windows host"
}

if (-not $NoStartupShortcut) {
  $startupDir = [Environment]::GetFolderPath("Startup")
  New-Shortcut `
    -Path (Join-Path $startupDir "Portal.lnk") `
    -Target $exePath `
    -WorkingDirectory $InstallDir `
    -Description "Start Portal when Windows signs in"
}

if ($Launch) {
  Start-Process -FilePath $exePath -WorkingDirectory $InstallDir
}

Write-Host "Portal installed:"
Write-Host "  $exePath"
Write-Host "Start Menu:"
Write-Host "  Portal"
