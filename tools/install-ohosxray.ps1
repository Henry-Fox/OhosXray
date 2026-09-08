#Requires -Version 5.1
<#
.SYNOPSIS
  OhosXray semi-auto install: find hdc/device, run hdc install -r *.hap

.DESCRIPTION
  Debug-signed HAP only. Receiver must enable Developer Mode + USB debugging.
  This script does not bypass system install restrictions.

.PARAMETER HapPath
  Path to HAP. If omitted, searches common folders for the newest *.hap.

.PARAMETER Device
  Optional hdc device serial (when multiple devices).

.EXAMPLE
  .\tools\install-ohosxray.ps1
  .\tools\install-ohosxray.ps1 -HapPath .\release\entry-default-signed.hap
#>
[CmdletBinding()]
param(
  [string]$HapPath = "",
  [string]$Device = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

function Write-Step([string]$msg) {
  Write-Host ""
  Write-Host "==> $msg" -ForegroundColor Cyan
}

function Find-Hdc {
  $cmd = Get-Command hdc -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $candidates = @(
    "$env:LOCALAPPDATA\OpenHarmony\Sdk\*\toolchains\hdc.exe",
    "$env:LOCALAPPDATA\Huawei\Sdk\*\toolchains\hdc.exe",
    "C:\Program Files\Huawei\DevEco Studio\sdk\*\toolchains\hdc.exe",
    "C:\Users\$env:USERNAME\AppData\Local\OpenHarmony\Sdk\*\toolchains\hdc.exe"
  )
  foreach ($pattern in $candidates) {
    $hit = Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

function Find-Hap([string]$explicit) {
  if ($explicit) {
    if (-not (Test-Path -LiteralPath $explicit)) {
      throw "HAP not found: $explicit"
    }
    return (Resolve-Path -LiteralPath $explicit).Path
  }

  $searchDirs = @(
    (Join-Path $RepoRoot "release"),
    (Join-Path $RepoRoot "dist"),
    (Join-Path $RepoRoot "entry\build\default\outputs\default"),
    $RepoRoot
  )
  $found = @()
  foreach ($dir in $searchDirs) {
    if (Test-Path $dir) {
      $found += Get-ChildItem -Path $dir -Filter "*.hap" -File -ErrorAction SilentlyContinue
    }
  }
  if ($found.Count -eq 0) {
    throw @"
No .hap file found.

Please:
  1) Download debug-signed HAP from GitHub Releases into repo root or release\
  2) Or build HAP with DevEco
  3) Or pass -HapPath

See: docs\install-for-friends.md
"@
  }
  $pick = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  return $pick.FullName
}

Write-Host "OhosXray install helper" -ForegroundColor Green
Write-Host "Note: debug-signed HAP requires Developer Mode. No sideload bypass." -ForegroundColor DarkYellow

Write-Step "Locate hdc"
$hdc = Find-Hdc
if (-not $hdc) {
  throw @"
hdc not found.

Install DevEco Studio / HarmonyOS SDK and add toolchains to PATH, e.g.:
  %LOCALAPPDATA%\OpenHarmony\Sdk\<version>\toolchains\hdc.exe
"@
}
Write-Host "hdc = $hdc"

Write-Step "Locate HAP"
$hap = Find-Hap $HapPath
Write-Host "hap = $hap  ($([math]::Round((Get-Item $hap).Length / 1MB, 1)) MB)"

Write-Step "Check device"
$listArgs = @("list", "targets")
$targetsRaw = & $hdc @listArgs 2>&1 | Out-String
Write-Host $targetsRaw.Trim()
$lines = @($targetsRaw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object {
  $_ -and ($_ -ne "[Empty]") -and ($_ -notmatch "List of targets") -and ($_ -notmatch "^\[")
})
if ($lines.Count -eq 0) {
  throw @"
No device detected.

On phone:
  1) Settings > About phone > tap Build number to enable Developer options
  2) Enable USB debugging
  3) Connect USB and tap Allow
  4) Run this script again

Chinese guide: docs\install-for-friends.md
"@
}

$serial = $Device
if (-not $serial) {
  if ($lines.Count -eq 1) {
    $serial = $lines[0]
  } else {
    Write-Host "Multiple devices:" -ForegroundColor Yellow
    $i = 1
    foreach ($t in $lines) {
      Write-Host "  [$i] $t"
      $i++
    }
    throw "Pass -Device <serial>, e.g. -Device $($lines[0])"
  }
}
Write-Host "target = $serial"

Write-Step "Install HAP (hdc install -r)"
$installArgs = @("-t", $serial, "install", "-r", $hap)
& $hdc @installArgs
if ($LASTEXITCODE -ne 0) {
  throw "Install failed, exit=$LASTEXITCODE. Check hdc output above (USB auth / resign uninstall old / storage)."
}

Write-Host ""
Write-Host "Install OK." -ForegroundColor Green
Write-Host "Open OhosXray on phone > add node > Global VPN (smart route) > Connect > Allow VPN."
Write-Host "Details (CN): docs\install-for-friends.md"