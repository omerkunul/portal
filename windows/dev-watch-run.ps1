param(
  [string]$ExePath = "$HOME\PortalBuild\dist\windows\PortalWindows.exe",
  [int]$PollMs = 1000
)

$ErrorActionPreference = "Stop"

Write-Host "Portal dev watcher"
Write-Host "Watching: $ExePath"
Write-Host "Leave this window open while iterating from the Mac."

$lastWrite = $null

while ($true) {
  if (Test-Path $ExePath) {
    $item = Get-Item $ExePath
    if ($null -eq $lastWrite -or $item.LastWriteTimeUtc -gt $lastWrite) {
      $lastWrite = $item.LastWriteTimeUtc
      Write-Host "New build detected: $($item.LastWriteTime)"

      Get-Process -Name "PortalWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
      Get-Process -Name "LanFlowWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
      Start-Sleep -Milliseconds 300
      Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path -Parent $ExePath)
      Write-Host "PortalWindows restarted."
    }
  }

  Start-Sleep -Milliseconds $PollMs
}
