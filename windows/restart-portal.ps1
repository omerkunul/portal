param(
  [string]$ExePath = "$HOME\PortalBuild\dist\windows\PortalWindows.exe"
)

$ErrorActionPreference = "Stop"
$log = "$HOME\PortalBuild\restart-portal.log"

function Log {
  param([string]$Message)
  Add-Content -Path $log -Value "$(Get-Date -Format o) $Message"
}

Log "restart requested; exe=$ExePath"

Get-Process -Name "PortalWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "LanFlowWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Log "old process stopped if present"
Start-Sleep -Milliseconds 400

if (-not (Test-Path $ExePath)) {
  Log "exe missing"
  throw "PortalWindows.exe not found: $ExePath"
}

Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path -Parent $ExePath) -PassThru |
  ForEach-Object { Log "started pid=$($_.Id)" }
Write-Host "PortalWindows restarted: $ExePath"
Log "restart done"
