param(
  [string] $ResourceGroupName = "itup-scorecard-rg",
  [string] $Location = "centralus"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root "infra/main.bicep"

az bicep build --file $template --stdout | Out-Null

az deployment group what-if `
  --resource-group $ResourceGroupName `
  --template-file $template `
  --parameters namePrefix=itup-scorecard location=$Location deploymentMode=hybrid `
  --only-show-errors