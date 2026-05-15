$ErrorActionPreference = "Stop"

$taskName = "PortalRestart"
$scriptPath = "$HOME\PortalBuild\windows\restart-portal.ps1"

if (-not (Test-Path $scriptPath)) {
  Write-Host "Expected restart script is not in PortalBuild yet:"
  Write-Host $scriptPath
  Write-Host "Run one remote build first, then run this installer again."
  exit 1
}

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
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

Write-Host "Installed scheduled task: $taskName"
Write-Host "Trigger remotely with:"
Write-Host "  schtasks /Run /TN $taskName"
