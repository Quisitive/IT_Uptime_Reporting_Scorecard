<#
.SYNOPSIS
  Installs the IT Uptime & Security Scorecard Collector as a Windows Service.
.DESCRIPTION
  Interactive wizard (or unattended with -Silent). Stages the app + a bundled Node 22
  runtime, registers a Windows Service via the WinSW wrapper, opens firewall ports, and
  starts the service. Re-running upgrades the app in place while preserving data/ and config.
.EXAMPLE
  # Interactive
  powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  # Unattended
  .\install.ps1 -Silent -HttpPort 8080 -OpenFirewall Yes -StartService
#>
[CmdletBinding()]
param(
  [string]$InstallDir   = "C:\Program Files\ITScorecard",
  [int]$HttpPort        = 8080,
  [int]$SyslogUdpPort   = 514,
  [int]$SyslogTcpPort   = 514,
  [string]$AdminPassword = "",
  [ValidateSet('Yes','No')][string]$OpenFirewall = 'Yes',
  [string]$SourceDir    = "",
  [string]$NodeVersion  = "22.11.0",
  [switch]$Silent,
  [switch]$DryRun,
  [switch]$StartService
)

$ErrorActionPreference = 'Stop'
$ServiceId   = 'ITScorecard'
$ServiceName = 'IT Scorecard Collector'

function Step($m){ Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Info($m){ Write-Host "   $m" }
function Do-Op($desc, [scriptblock]$op){ if($DryRun){ Write-Host "   [dry-run] $desc" -ForegroundColor DarkYellow } else { Info $desc; & $op } }
function Ask($label, $default){
  if($Silent){ return $default }
  $v = Read-Host ("   {0} [{1}]" -f $label, $default)
  if([string]::IsNullOrWhiteSpace($v)){ return $default } else { return $v }
}
function XmlEsc($s){ return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }

Write-Host "IT Uptime & Security Scorecard - Installer" -ForegroundColor Green
Write-Host "=================================================="

# --- admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin -and -not $DryRun){
  Write-Error "This installer must run as Administrator. Right-click PowerShell > Run as administrator, then re-run."
  exit 1
}

# --- resolve app payload ---
if(-not $SourceDir){
  if(Test-Path (Join-Path $PSScriptRoot 'payload\package.json'))      { $SourceDir = Join-Path $PSScriptRoot 'payload' }
  elseif(Test-Path (Join-Path $PSScriptRoot '..\package.json'))       { $SourceDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
  else { Write-Error "Could not locate app payload (no payload\package.json or ..\package.json next to install.ps1)."; exit 1 }
}
Info "App source: $SourceDir"

# --- wizard ---
Step "Configuration"
$InstallDir     = Ask "Install directory"        $InstallDir
$HttpPort       = [int](Ask "Web UI / API port (TCP)" $HttpPort)
$SyslogUdpPort  = [int](Ask "Syslog UDP port"    $SyslogUdpPort)
$SyslogTcpPort  = [int](Ask "Syslog TCP port"    $SyslogTcpPort)
$OpenFirewall   = Ask "Open Windows Firewall for those ports? (Yes/No)" $OpenFirewall
if(-not $Silent -and [string]::IsNullOrWhiteSpace($AdminPassword)){
  $sec = Read-Host "   Admin password (blank = auto-generate & show after start)" -AsSecureString
  if($sec.Length -gt 0){ $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }
}
if(-not $Silent){
  $startAns = Ask "Start the service now? (Yes/No)" "Yes"
  if($startAns -match '^(y|yes)$'){ $StartService = $true }
}

$runtimeDir = Join-Path $InstallDir 'runtime'
$serviceDir = Join-Path $InstallDir 'service'
$dataDir    = Join-Path $InstallDir 'data'
$nodeExe    = Join-Path $runtimeDir 'node.exe'
$svcExe     = Join-Path $serviceDir "$ServiceId.exe"
$svcXml     = Join-Path $serviceDir "$ServiceId.xml"

# --- stop existing service if upgrading ---
if(Test-Path $svcExe){
  Step "Stopping existing service (upgrade)"
  Do-Op "stop $ServiceId" { & $svcExe stop 2>$null | Out-Null; Start-Sleep 2 }
}

# --- copy app (preserve data/ and existing config) ---
Step "Installing application files"
Do-Op "create $InstallDir" { New-Item -ItemType Directory -Force -Path $InstallDir,$runtimeDir,$serviceDir,$dataDir | Out-Null }
foreach($item in 'src','web','scripts','package.json'){
  $src = Join-Path $SourceDir $item
  if(Test-Path $src){ Do-Op "copy $item" { Copy-Item $src -Destination $InstallDir -Recurse -Force } }
}
# config: copy only if not already present, so upgrades keep the operator's settings
$cfgDst = Join-Path $InstallDir 'config'
if(-not (Test-Path (Join-Path $cfgDst 'collector.json'))){
  Do-Op "copy default config" { Copy-Item (Join-Path $SourceDir 'config') -Destination $InstallDir -Recurse -Force }
} else { Info "existing config preserved: $cfgDst\collector.json" }

# --- Node runtime (bundled or downloaded) ---
Step "Node.js runtime"
if(Test-Path (Join-Path $SourceDir 'runtime\node.exe')){
  Do-Op "use bundled node.exe" { Copy-Item (Join-Path $SourceDir 'runtime\node.exe') -Destination $nodeExe -Force }
} elseif(Test-Path $nodeExe){
  Info "node.exe already present"
} else {
  $url = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
  Do-Op "download & extract Node $NodeVersion from $url" {
    $tmp = Join-Path $env:TEMP "node-$NodeVersion.zip"; $ext = Join-Path $env:TEMP "node-$NodeVersion"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $ext -Force
    Copy-Item (Join-Path $ext "node-v$NodeVersion-win-x64\node.exe") -Destination $nodeExe -Force
    Remove-Item $tmp,$ext -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- WinSW service wrapper (bundled or downloaded) ---
Step "Service wrapper (WinSW)"
if(Test-Path (Join-Path $SourceDir 'service\WinSW-x64.exe')){
  Do-Op "use bundled WinSW" { Copy-Item (Join-Path $SourceDir 'service\WinSW-x64.exe') -Destination $svcExe -Force }
} elseif(Test-Path $svcExe){
  Info "service wrapper already present"
} else {
  $winsw = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
  Do-Op "download WinSW from $winsw" { Invoke-WebRequest -Uri $winsw -OutFile $svcExe -UseBasicParsing }
}

# --- service definition ---
Step "Writing service definition"
$pwEnv = ""
if($AdminPassword){ $pwEnv = "  <env name=""ADMIN_PASSWORD"" value=""$(XmlEsc $AdminPassword)"" />`n" }
$xml = @"
<service>
  <id>$ServiceId</id>
  <name>$ServiceName</name>
  <description>Agentless IT uptime and security scorecard collector.</description>
  <executable>$nodeExe</executable>
  <arguments>--disable-warning=ExperimentalWarning src\index.js</arguments>
  <workingdirectory>$InstallDir</workingdirectory>
  <env name="NODE_ENV" value="production" />
  <env name="HTTP_PORT" value="$HttpPort" />
  <env name="SYSLOG_UDP_PORT" value="$SyslogUdpPort" />
  <env name="SYSLOG_TCP_PORT" value="$SyslogTcpPort" />
$pwEnv  <logpath>$serviceDir\logs</logpath>
  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>8</keepFiles></log>
  <onfailure action="restart" delay="10 sec" />
  <startmode>Automatic</startmode>
</service>
"@
Do-Op "write $svcXml" { Set-Content -Path $svcXml -Value $xml -Encoding UTF8 }

# --- register + start ---
Step "Registering Windows Service"
Do-Op "install service '$ServiceId'" { & $svcExe install | Out-Null }
if($StartService){ Do-Op "start service" { & $svcExe start | Out-Null } }

# --- firewall ---
if($OpenFirewall -match '^(y|yes)$'){
  Step "Firewall rules"
  $rules = @(
    @{ n = "IT Scorecard UI ($HttpPort/TCP)";      p = 'TCP'; port = $HttpPort },
    @{ n = "IT Scorecard syslog ($SyslogUdpPort/UDP)"; p = 'UDP'; port = $SyslogUdpPort },
    @{ n = "IT Scorecard syslog ($SyslogTcpPort/TCP)"; p = 'TCP'; port = $SyslogTcpPort }
  )
  foreach($r in $rules){
    Do-Op "allow inbound $($r.p) $($r.port)" {
      Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
      New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Action Allow -Protocol $r.p -LocalPort $r.port | Out-Null
    }
  }
}

# --- surface admin password ---
Step "Done"
$host1 = $env:COMPUTERNAME
Write-Host "   Web UI:  http://${host1}:$HttpPort  (also http://localhost:$HttpPort on this server)" -ForegroundColor Green
if($AdminPassword){
  Write-Host "   Admin password: (the one you entered)" -ForegroundColor Green
} elseif(-not $DryRun -and $StartService){
  Start-Sleep 3
  $outLog = Join-Path $serviceDir "logs\$ServiceId.out.log"
  $shown = $false
  if(Test-Path $outLog){
    $line = Select-String -Path $outLog -Pattern 'password:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if($line){ Write-Host "   First-run admin login -> username: admin  password: $($line.Matches[0].Groups[1].Value)" -ForegroundColor Yellow; $shown = $true }
  }
  if(-not $shown){ Write-Host "   First-run admin password was written to: $outLog (search for 'password:')" -ForegroundColor Yellow }
} else {
  Write-Host "   Start the service, then find the first-run admin password in $serviceDir\logs\$ServiceId.out.log" -ForegroundColor Yellow
}
Write-Host "   Manage:  services.msc  (service '$ServiceName')  or  $svcExe [start|stop|restart|status]"
Write-Host "   Config:  $InstallDir\config\collector.json   Data: $dataDir"
Write-Host "   Change the admin password immediately under Setup in the web UI." -ForegroundColor Yellow
if(-not $DryRun -and $StartService){ try { Start-Process "http://localhost:$HttpPort" } catch {} }
