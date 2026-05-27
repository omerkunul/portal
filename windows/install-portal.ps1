param(
  [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Portal",
  [switch]$NoDesktopShortcut,
  [switch]$NoStartupShortcut,
  [switch]$Launch,
  [switch]$NoLaunchTask
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $scriptDir "PortalWindows.exe"
$taskName = "PortalLaunch"

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
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Portal.lnk"

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
  if ($NoLaunchTask) {
    New-Shortcut `
      -Path $startupShortcutPath `
      -Target $exePath `
      -WorkingDirectory $InstallDir `
      -Description "Start Portal when Windows signs in"
  } else {
    Remove-Item -Force $startupShortcutPath -ErrorAction SilentlyContinue
    Write-Host "Startup shortcut skipped because launch task is enabled."
  }
}

function Install-LaunchTask {
  param([string]$TargetExe)

  $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $action = New-ScheduledTaskAction `
    -Execute $TargetExe `
    -WorkingDirectory (Split-Path -Parent $TargetExe)

  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal = New-ScheduledTaskPrincipal `
    -UserId $user `
    -LogonType Interactive `
    -RunLevel Highest

  Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Force | Out-Null
}

if (-not $NoLaunchTask) {
  try {
    Install-LaunchTask -TargetExe $exePath
    Write-Host "Launch task:"
    Write-Host "  $taskName"
  } catch {
    Write-Host "Launch task could not be installed:"
    Write-Host "  $($_.Exception.Message)"
  }
} else {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($Launch) {
  if (-not $NoLaunchTask) {
    try {
      schtasks.exe /Run /TN $taskName | Out-Null
    } catch {
      Write-Host "Launch task run failed:"
      Write-Host "  $($_.Exception.Message)"
      Write-Host "Open Portal from the Start Menu if this was a remote SSH install."
    }
  } else {
    try {
      Start-Process -FilePath $exePath -WorkingDirectory $InstallDir
    } catch {
      Write-Host "Direct launch failed:"
      Write-Host "  $($_.Exception.Message)"
    }
  }
}

Write-Host "Portal installed:"
Write-Host "  $exePath"
Write-Host "Start Menu:"
Write-Host "  Portal"
