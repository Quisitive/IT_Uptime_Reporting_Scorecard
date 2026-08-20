param(
  [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
  [Parameter(Mandatory = $true)] [string] $Location,
  [string] $NamePrefix = "itup-scorecard",
  [ValidateSet("azure-vm", "arc", "hybrid")] [string] $DeploymentMode = "hybrid",
  [string[]] $TargetResourceIds = @(),
  [string] $TargetInventoryPath = "",
  [string[]] $AlertEmailReceivers = @(),
  [switch] $EnableVmInsightsMap,
  [switch] $EnableScheduledQueryAlerts,
  [int] $HeartbeatMissingMinutes = 15,
  [switch] $GenerateKqlFromCollectorConfig,
  [switch] $InstallAzureMonitorAgent
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root "infra/main.bicep"
$parametersFile = Join-Path ([System.IO.Path]::GetTempPath()) ("itup-scorecard-" + [System.Guid]::NewGuid().ToString("n") + ".parameters.json")

if ($GenerateKqlFromCollectorConfig) {
  & (Join-Path $PSScriptRoot "Convert-CollectorConfigToKql.ps1") | Out-Null
}

$deploymentParameters = @{
  '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
  contentVersion = "1.0.0.0"
  parameters = @{
    namePrefix = @{ value = $NamePrefix }
    location = @{ value = $Location }
    deploymentMode = @{ value = $DeploymentMode }
    enableVmInsightsMap = @{ value = [bool]$EnableVmInsightsMap.IsPresent }
    enableScheduledQueryAlerts = @{ value = [bool]$EnableScheduledQueryAlerts.IsPresent }
    heartbeatMissingMinutes = @{ value = $HeartbeatMissingMinutes }
    alertEmailReceivers = @{ value = $AlertEmailReceivers }
  }
}

$deploymentParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $parametersFile -Encoding utf8

az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Null

try {
  $deployment = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $template `
    --parameters "@$parametersFile" `
    --query properties.outputs `
    --output json | ConvertFrom-Json
}
finally {
  if (Test-Path $parametersFile) {
    Remove-Item $parametersFile -Force
  }
}

$dcrId = $deployment.dataCollectionRuleId.value

foreach ($targetResourceId in $TargetResourceIds) {
  $safeAssociationName = "scorecard-dcr"
  az monitor data-collection rule association create `
    --name $safeAssociationName `
    --resource $targetResourceId `
    --rule-id $dcrId `
    --only-show-errors | Out-Null
}

if ($TargetInventoryPath) {
  $onboardArgs = @{
    DataCollectionRuleId = $dcrId
    TargetInventoryPath = $TargetInventoryPath
  }

  if ($InstallAzureMonitorAgent) {
    $onboardArgs.InstallAzureMonitorAgent = $true
  }

  & (Join-Path $PSScriptRoot "onboard-targets.ps1") @onboardArgs | Out-Null
}

[pscustomobject]@{
  WorkspaceId = $deployment.workspaceId.value
  WorkspaceResourceId = $deployment.workspaceResourceId.value
  DataCollectionRuleId = $dcrId
  AppInsightsConnectionString = $deployment.appInsightsConnectionString.value
  GrafanaEndpoint = $deployment.grafanaEndpoint.value
  AssociatedTargets = $TargetResourceIds.Count + ($(if ($TargetInventoryPath) { (Get-Content -Path $TargetInventoryPath -Raw | ConvertFrom-Json).Count } else { 0 }))
}