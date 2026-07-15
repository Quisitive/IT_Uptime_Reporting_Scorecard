<#
.SYNOPSIS
  Builds a self-contained, shippable installer bundle (zip) for the collector.
.DESCRIPTION
  Stages the app under installer\payload, optionally downloads the bundled Node runtime and
  the WinSW service wrapper into the payload (so the target server needs no internet), then
  zips the installer folder to dist\QuisitiveScorecard-Installer-<version>.zip.

  The recipient unzips it and runs install.ps1 as Administrator.
.EXAMPLE
  .\package-installer.ps1                 # full offline bundle (downloads Node + WinSW)
  .\package-installer.ps1 -SkipDownloads  # smaller bundle; target downloads Node/WinSW at install time
#>
[CmdletBinding()]
param(
  [string]$NodeVersion = "22.11.0",
  [switch]$SkipDownloads
)
$ErrorActionPreference = 'Stop'
$root      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path   # repo root (app)
$payload   = Join-Path $PSScriptRoot 'payload'
$distDir   = Join-Path $root 'dist'

function Step($m){ Write-Host "== $m ==" -ForegroundColor Cyan }

$version = (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version

Step "Staging app payload"
if(Test-Path $payload){ Remove-Item $payload -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload,(Join-Path $payload 'runtime'),(Join-Path $payload 'service') | Out-Null
foreach($item in 'src','web','config','scripts','package.json'){
  Copy-Item (Join-Path $root $item) -Destination $payload -Recurse -Force
}
Write-Host "   staged src/ web/ config/ scripts/ package.json"

if(-not $SkipDownloads){
  Step "Bundling Node $NodeVersion"
  $url = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
  $tmp = Join-Path $env:TEMP "node-$NodeVersion.zip"; $ext = Join-Path $env:TEMP "node-$NodeVersion-x"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
  Expand-Archive -Path $tmp -DestinationPath $ext -Force
  Copy-Item (Join-Path $ext "node-v$NodeVersion-win-x64\node.exe") -Destination (Join-Path $payload 'runtime\node.exe') -Force
  Remove-Item $tmp,$ext -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "   bundled runtime\node.exe"

  Step "Bundling WinSW"
  Invoke-WebRequest -Uri "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe" -OutFile (Join-Path $payload 'service\WinSW-x64.exe') -UseBasicParsing
  Write-Host "   bundled service\WinSW-x64.exe"
} else {
  Write-Host "   (skipped downloads; installer will fetch Node + WinSW on the target server)" -ForegroundColor DarkYellow
}

Step "Zipping bundle"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$stage = Join-Path $env:TEMP "quisitive-installer-stage"
if(Test-Path $stage){ Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item $payload -Destination (Join-Path $stage 'payload') -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'install.ps1')   -Destination $stage -Force
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination $stage -Force
Copy-Item (Join-Path $PSScriptRoot 'INSTALL.md')    -Destination $stage -Force
$zip = Join-Path $distDir "QuisitiveScorecard-Installer-$version.zip"
if(Test-Path $zip){ Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force

Write-Host "`nBuilt: $zip" -ForegroundColor Green
Write-Host "Ship the zip. On the target server: unzip, then (as Administrator) powershell -ExecutionPolicy Bypass -File .\install.ps1"
