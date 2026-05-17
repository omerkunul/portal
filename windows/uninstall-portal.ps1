$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Get-Process -Name "PortalWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "Portal.lnk"
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Portal.lnk"
$programsDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Portal"

Remove-Item -Force $desktopShortcut -ErrorAction SilentlyContinue
Remove-Item -Force $startupShortcut -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $programsDir -ErrorAction SilentlyContinue

if (Test-Path $installDir) {
  Remove-Item -Recurse -Force $installDir
}

Write-Host "Portal uninstalled."
