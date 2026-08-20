param(
  [Parameter(Mandatory = $true)] [string] $DataCollectionRuleId,
  [Parameter(Mandatory = $true)] [string] $TargetInventoryPath,
  [switch] $InstallAzureMonitorAgent
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $TargetInventoryPath)) {
  throw "Target inventory not found: $TargetInventoryPath"
}

$targets = Get-Content -Path $TargetInventoryPath -Raw | ConvertFrom-Json
if ($targets -isnot [array]) {
  $targets = @($targets)
}

function Get-ResourceGroupFromId {
  param([string] $ResourceId)
  $parts = $ResourceId -split "/"
  $index = [Array]::IndexOf($parts, "resourceGroups")
  if ($index -lt 0 -or $index + 1 -ge $parts.Length) {
    throw "Could not parse resource group from resource ID: $ResourceId"
  }
  $parts[$index + 1]
}

function Get-ResourceNameFromId {
  param([string] $ResourceId)
  ($ResourceId -split "/")[-1]
}

function Get-ResourceLocation {
  param([string] $ResourceId)
  az resource show --ids $ResourceId --query location -o tsv --only-show-errors
}

function Install-AmaExtension {
  param(
    [string] $ResourceId,
    [ValidateSet("windows", "linux")] [string] $OsType
  )

  $extensionType = if ($OsType -eq "windows") { "AzureMonitorWindowsAgent" } else { "AzureMonitorLinuxAgent" }

  if ($ResourceId -match "/providers/Microsoft\.Compute/virtualMachines/") {
    az vm extension set --ids $ResourceId --publisher Microsoft.Azure.Monitor --name $extensionType --enable-auto-upgrade true --only-show-errors | Out-Null
    return
  }

  if ($ResourceId -match "/providers/Microsoft\.HybridCompute/machines/") {
    $resourceGroup = Get-ResourceGroupFromId -ResourceId $ResourceId
    $machineName = Get-ResourceNameFromId -ResourceId $ResourceId
    $location = Get-ResourceLocation -ResourceId $ResourceId
    az connectedmachine extension create `
      --resource-group $resourceGroup `
      --machine-name $machineName `
      --name $extensionType `
      --publisher Microsoft.Azure.Monitor `
      --type $extensionType `
      --location $location `
      --enable-auto-upgrade true `
      --only-show-errors | Out-Null
    return
  }

  throw "Unsupported target type for AMA install: $ResourceId"
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($target in $targets) {
  $resourceId = [string]$target.resourceId
  $osType = ([string]$target.os).ToLowerInvariant()

  if (-not $resourceId) {
    throw "Each target must include resourceId."
  }

  if ($InstallAzureMonitorAgent) {
    if ($osType -notin @("windows", "linux")) {
      throw "Target $resourceId must include os as 'windows' or 'linux' when -InstallAzureMonitorAgent is used."
    }
    Install-AmaExtension -ResourceId $resourceId -OsType $osType
  }

  az monitor data-collection rule association create `
    --name scorecard-dcr `
    --resource $resourceId `
    --rule-id $DataCollectionRuleId `
    --only-show-errors | Out-Null

  $results.Add([pscustomobject]@{
    ResourceId = $resourceId
    Os = $osType
    AgentInstallRequested = [bool]$InstallAzureMonitorAgent.IsPresent
    DcrAssociated = $true
  })
}

$results