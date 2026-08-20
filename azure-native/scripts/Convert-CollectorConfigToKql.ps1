param(
  [string] $CollectorConfigPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "config/collector.json"),
  [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "kql")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $CollectorConfigPath)) {
  throw "Collector config not found: $CollectorConfigPath"
}

if (-not (Test-Path $OutputDirectory)) {
  New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$config = Get-Content -Path $CollectorConfigPath -Raw | ConvertFrom-Json
$timezoneOffset = [int]$config.businessHours.timezoneOffsetMinutes
$businessDays = ($config.businessHours.days | ForEach-Object { [int]$_ }) -join ", "
$startHour = [int]$config.businessHours.startHour
$endHour = [int]$config.businessHours.endHour
$standardMonthlyHours = [double]$config.businessHours.standardMonthlyHours
$weights = $config.scoring.weights
$scoring = $config.scoring

$scorecardConfig = @"
print
  businessTimezoneOffsetMinutes = $timezoneOffset,
  businessDays = dynamic([$businessDays]),
  businessStartHour = $startHour,
  businessEndHour = $endHour,
  standardMonthlyHours = $standardMonthlyHours,
  uptimeWeight = $([double]$weights.uptime),
  diskWeight = $([double]$weights.disk),
  securityWeight = $([double]$weights.security),
  uptimeFloorBelowTargetPct = $([double]$scoring.uptime.floorBelowTargetPct),
  diskWarnPct = $([double]$scoring.disk.warnPct),
  diskCritPct = $([double]$scoring.disk.critPct),
  pointsPerIntervention = $([double]$scoring.security.pointsPerIntervention),
  maxInterventionPenalty = $([double]$scoring.security.maxInterventionPenalty),
  escalationRatePer1000 = $([double]$scoring.security.escalationRatePer1000),
  maxEscalationPenalty = $([double]$scoring.security.maxEscalationPenalty)
"@

Set-Content -Path (Join-Path $OutputDirectory "scorecard_config.kql") -Value $scorecardConfig.TrimEnd() -Encoding utf8

$targetsByGroup = @{}
foreach ($target in $config.probe.targets) {
  $groupName = [string]$target.group
  if (-not $targetsByGroup.ContainsKey($groupName)) {
    $targetsByGroup[$groupName] = [System.Collections.Generic.List[string]]::new()
  }
  $targetsByGroup[$groupName].Add([string]$target.name)
}

$rows = [System.Collections.Generic.List[string]]::new()
foreach ($sla in $config.slas) {
  $members = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($group in @($sla.scope.groups)) {
    if ($targetsByGroup.ContainsKey([string]$group)) {
      foreach ($targetName in $targetsByGroup[[string]$group]) {
        [void]$members.Add($targetName)
      }
    }
  }

  foreach ($targetName in @($sla.scope.targets)) {
    [void]$members.Add([string]$targetName)
  }

  $memberLiteral = (($members | Sort-Object | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ", ")
  $rows.Add("  '$($sla.name -replace "'", "''")', $([int]$sla.tier), $([double]$sla.uptimeTarget), dynamic([$memberLiteral])")
}

$scorecardSlas = "datatable(slaName:string, tier:int, targetPct:real, members:dynamic)`n[`n" + ($rows -join ",`n") + "`n]"
Set-Content -Path (Join-Path $OutputDirectory "scorecard_slas.kql") -Value $scorecardSlas -Encoding utf8

[pscustomobject]@{
  ConfigPath = (Resolve-Path $CollectorConfigPath).Path
  OutputDirectory = (Resolve-Path $OutputDirectory).Path
  SlaCount = $config.slas.Count
  TargetCount = $config.probe.targets.Count
}