<#
.SYNOPSIS
  Uninstalls the Quisitive IT Scorecard Collector Windows Service and (optionally) its data.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  .\uninstall.ps1 -InstallDir "C:\Program Files\QuisitiveScorecard" -RemoveData -Silent
#>
[CmdletBinding()]
param(
  [string]$InstallDir = "C:\Program Files\QuisitiveScorecard",
  [switch]$RemoveData,
  [switch]$Silent
)
$ErrorActionPreference = 'Continue'
$ServiceId = 'QuisitiveScorecard'
$svcExe = Join-Path $InstallDir "service\$ServiceId.exe"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ Write-Error "Run as Administrator."; exit 1 }

Write-Host "Uninstalling $ServiceId ..." -ForegroundColor Cyan
if(Test-Path $svcExe){
  & $svcExe stop 2>$null | Out-Null
  Start-Sleep 2
  & $svcExe uninstall 2>$null | Out-Null
  Write-Host "   service removed"
} else { Write-Host "   service wrapper not found (already removed?)" }

# firewall rules
Get-NetFirewallRule -DisplayName 'Quisitive Scorecard*' -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "   removing firewall rule: $($_.DisplayName)"
  Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
}

# files
$dataDir = Join-Path $InstallDir 'data'
$removeData = $RemoveData
if(-not $Silent -and -not $RemoveData -and (Test-Path $dataDir)){
  $ans = Read-Host "Delete collected data and settings in $dataDir? (yes/No)"
  if($ans -match '^(y|yes)$'){ $removeData = $true }
}
foreach($item in 'src','web','scripts','runtime','service','package.json','config'){
  $p = Join-Path $InstallDir $item
  if(Test-Path $p){ Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}
if($removeData){ Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "   data removed" }
else { Write-Host "   data KEPT at $dataDir" }

# remove install dir if empty
if((Test-Path $InstallDir) -and -not (Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue)){ Remove-Item $InstallDir -Force -ErrorAction SilentlyContinue }
Write-Host "Done." -ForegroundColor Green
