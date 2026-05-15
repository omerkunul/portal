$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot "PortalWindows\PortalWindows.csproj"
$out = Join-Path $root "dist\windows"
$staging = Join-Path $root "dist\windows-staging"

Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null

dotnet publish $project `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -o $staging

if ($LASTEXITCODE -ne 0) {
  throw "dotnet publish failed with exit code $LASTEXITCODE"
}

Get-Process -Name "PortalWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "LanFlowWindows" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -Recurse -Force (Join-Path $staging "*") $out
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue

Write-Host "Built: $out\PortalWindows.exe"
