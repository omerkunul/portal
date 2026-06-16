$ErrorActionPreference = "Stop"

param(
  [Parameter(Mandatory = $true)]
  [string]$Key
)

$sshDir = Join-Path $env:USERPROFILE ".ssh"
$authorizedKeys = Join-Path $sshDir "authorized_keys"
$adminAuthorizedKeys = "C:\ProgramData\ssh\administrators_authorized_keys"

function Add-KeyIfMissing {
  param(
    [string]$Path,
    [string]$Key
  )

  if (Test-Path $Path) {
    $existing = Get-Content $Path -Raw
    if ($existing -notlike "*$Key*") {
      Add-Content -Path $Path -Value $Key
    }
  } else {
    Set-Content -Path $Path -Value $Key
  }
}

New-Item -ItemType Directory -Force $sshDir | Out-Null
New-Item -ItemType Directory -Force "C:\ProgramData\ssh" | Out-Null

Add-KeyIfMissing -Path $authorizedKeys -Key $key
Add-KeyIfMissing -Path $adminAuthorizedKeys -Key $key

icacls $sshDir /inheritance:r | Out-Null
icacls $sshDir /grant "$env:USERNAME:(OI)(CI)F" | Out-Null
icacls $authorizedKeys /inheritance:r | Out-Null
icacls $authorizedKeys /grant "$env:USERNAME:F" | Out-Null

icacls $adminAuthorizedKeys /inheritance:r | Out-Null
icacls $adminAuthorizedKeys /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

Restart-Service sshd

Write-Host "Mac SSH key installed for $env:USERNAME."
Write-Host "User key file: $authorizedKeys"
Write-Host "Admin key file: $adminAuthorizedKeys"
