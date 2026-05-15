$ErrorActionPreference = "Stop"

Write-Host "Checking .NET SDK..."
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
  Write-Host ".NET SDK is missing. Install .NET 8 SDK from:"
  Write-Host "https://dotnet.microsoft.com/en-us/download/dotnet/8.0"
  exit 1
}

Write-Host "Checking OpenSSH Server..."
$capability = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
if ($capability.State -ne "Installed") {
  Add-WindowsCapability -Online -Name $capability.Name
}

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) {
  $existing = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
  if (-not $existing) {
    New-NetFirewallRule `
      -Name "OpenSSH-Server-In-TCP" `
      -DisplayName "OpenSSH Server (sshd)" `
      -Enabled True `
      -Direction Inbound `
      -Protocol TCP `
      -Action Allow `
      -LocalPort 22 | Out-Null
  }
}

Write-Host "Remote build ready."
Write-Host "From Mac, run: ./script/build_windows_remote.sh $env:USERNAME@WINDOWS_IP"
