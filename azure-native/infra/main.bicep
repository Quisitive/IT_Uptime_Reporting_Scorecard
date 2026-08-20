targetScope = 'resourceGroup'

@description('Short name prefix used for Azure resources.')
param namePrefix string = 'itup-scorecard'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Deployment mode selected by the operator. Azure VMs and Arc/on-prem use the same workspace/DCR; scripts associate target resources after deployment.')
@allowed([
  'azure-vm'
  'arc'
  'hybrid'
])
param deploymentMode string = 'hybrid'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 90

@description('Enable VM Insights dependency map collection. This can increase ingestion volume.')
param enableVmInsightsMap bool = false

@description('Email receivers for Azure Monitor action group notifications.')
param alertEmailReceivers array = []

@description('Create scheduled query alert rules for missing Heartbeat and SLA breaches.')
param enableScheduledQueryAlerts bool = true

@description('A machine is considered down when no Heartbeat has arrived for this many minutes.')
@minValue(5)
@maxValue(120)
param heartbeatMissingMinutes int = 15

@description('Grant the Azure Managed Grafana managed identity Monitoring Reader at this resource group scope.')
param grantGrafanaMonitoringReader bool = true

@description('Optional tags applied to all supported resources.')
param tags object = {}

var suffix = uniqueString(resourceGroup().id, namePrefix)
var workspaceName = take('${namePrefix}-law-${suffix}', 63)
var appInsightsName = take('${namePrefix}-appi-${suffix}', 255)
var dcrName = take('${namePrefix}-dcr-${suffix}', 64)
var grafanaName = take(replace('${namePrefix}-amg-${suffix}', '_', '-'), 30)
var actionGroupName = take('${namePrefix}-ag-${suffix}', 260)
var machineDownAlertName = take('${namePrefix}-heartbeat-missing-${suffix}', 260)
var slaBreachAlertName = take('${namePrefix}-sla-breach-${suffix}', 260)
var defaultTags = {
  workload: 'it-uptime-scorecard'
  managedBy: 'bicep'
  deploymentMode: deploymentMode
}
var allTags = union(defaultTags, tags)
var monitoringReaderRoleDefinitionId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var dcrBaseDataFlows = [
  {
    streams: [
      'Microsoft-Perf'
      'Microsoft-Event'
      'Microsoft-Syslog'
    ]
    destinations: [
      'scorecardWorkspace'
    ]
  }
]
var dcrVmInsightsDataFlows = enableVmInsightsMap ? [
  {
    streams: [
      'Microsoft-ServiceMap'
    ]
    destinations: [
      'scorecardWorkspace'
    ]
  }
] : []

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  tags: allTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: allTags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logWorkspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: logRetentionInDays
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: allTags
  kind: 'Windows'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'vmInsightsPerfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(*)\\% Free Space'
            '\\Network Interface(*)\\Bytes Total/sec'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'windowsScorecardEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'System!*[System[(Level=1 or Level=2 or Level=3 or EventID=41 or EventID=109 or EventID=6005 or EventID=6006 or EventID=6008 or EventID=6013 or EventID=1074 or EventID=1076)]]'
            'Security!*[System[(EventID=4624 or EventID=4625 or EventID=4688)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
          ]
        }
      ]
      syslog: [
        {
          name: 'linuxScorecardSyslog'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
            'user'
          ]
          logLevels: [
            'Debug'
            'Info'
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
      extensions: enableVmInsightsMap ? [
        {
          name: 'dependencyAgent'
          streams: [
            'Microsoft-ServiceMap'
          ]
          extensionName: 'DependencyAgent'
          extensionSettings: {}
        }
      ] : []
    }
    destinations: {
      logAnalytics: [
        {
          name: 'scorecardWorkspace'
          workspaceResourceId: logWorkspace.id
        }
      ]
    }
    dataFlows: concat(dcrBaseDataFlows, dcrVmInsightsDataFlows)
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2024-10-01' = {
  name: grafanaName
  location: location
  tags: allTags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Enabled'
    publicNetworkAccess: 'Enabled'
    grafanaConfigurations: {
      users: {
        viewersCanEdit: false
      }
      snapshots: {
        externalEnabled: false
      }
    }
  }
}

resource grafanaMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantGrafanaMonitoringReader) {
  name: guid(resourceGroup().id, grafana.id, monitoringReaderRoleDefinitionId)
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleDefinitionId)
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (length(alertEmailReceivers) > 0) {
  name: actionGroupName
  location: 'global'
  tags: allTags
  properties: {
    groupShortName: 'itupsc'
    enabled: true
    emailReceivers: [for email in alertEmailReceivers: {
      name: replace(split(email, '@')[0], '.', '-')
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

resource machineDownAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableScheduledQueryAlerts) {
  name: machineDownAlertName
  location: location
  tags: allTags
  properties: {
    displayName: 'IT Scorecard - machine heartbeat missing'
    description: 'Fires when any monitored machine has no Heartbeat within the configured threshold.'
    enabled: true
    severity: 2
    scopes: [
      logWorkspace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT${heartbeatMissingMinutes}M'
    criteria: {
      allOf: [
        {
          query: 'Heartbeat | summarize LastSeen=max(TimeGenerated) by Computer | where LastSeen < ago(${heartbeatMissingMinutes}m) | summarize AffectedMachines=count()'
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'AffectedMachines'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: length(alertEmailReceivers) > 0 ? [
        actionGroup.id
      ] : []
    }
  }
}

resource slaBreachAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (enableScheduledQueryAlerts) {
  name: slaBreachAlertName
  location: location
  tags: allTags
  properties: {
    displayName: 'IT Scorecard - SLA breach'
    description: 'Fires when any scorecard SLA is below its configured target for the current month.'
    enabled: true
    severity: 2
    scopes: [
      logWorkspace.id
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'scorecard_sla_uptime(startofmonth(now()), now()) | where breached == true | summarize BreachedSlas=count()'
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'BreachedSlas'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: length(alertEmailReceivers) > 0 ? [
        actionGroup.id
      ] : []
    }
  }
}

var scorecardFunctions = [
  {
    name: 'scorecard-config'
    alias: 'scorecard_config'
    parameters: ''
    displayName: 'Scorecard configuration'
    query: loadTextContent('../kql/scorecard_config.kql')
  }
  {
    name: 'scorecard-slas'
    alias: 'scorecard_slas'
    parameters: ''
    displayName: 'Scorecard SLA member map'
    query: loadTextContent('../kql/scorecard_slas.kql')
  }
  {
    name: 'scorecard-machine-uptime'
    alias: 'scorecard_machine_uptime'
    parameters: 'startTime:datetime = startofmonth(now()), endTime:datetime = now()'
    displayName: 'Scorecard machine uptime by business minute'
    query: loadTextContent('../kql/scorecard_machine_uptime.kql')
  }
  {
    name: 'scorecard-sla-uptime'
    alias: 'scorecard_sla_uptime'
    parameters: 'startTime:datetime = startofmonth(now()), endTime:datetime = now()'
    displayName: 'Scorecard SLA uptime'
    query: loadTextContent('../kql/scorecard_sla_uptime.kql')
  }
  {
    name: 'scorecard-health-index'
    alias: 'scorecard_health_index'
    parameters: 'startTime:datetime = startofmonth(now()), endTime:datetime = now()'
    displayName: 'Scorecard Health Index'
    query: loadTextContent('../kql/scorecard_health_index.kql')
  }
]

resource savedSearches 'Microsoft.OperationalInsights/workspaces/savedSearches@2025-02-01' = [for scorecardFunction in scorecardFunctions: {
  parent: logWorkspace
  name: scorecardFunction.name
  properties: {
    category: 'IT Uptime Scorecard'
    displayName: scorecardFunction.displayName
    functionAlias: scorecardFunction.alias
    functionParameters: scorecardFunction.parameters
    query: scorecardFunction.query
    version: 2
  }
}]

output workspaceId string = logWorkspace.properties.customerId
output workspaceResourceId string = logWorkspace.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output dataCollectionRuleId string = dataCollectionRule.id
output grafanaEndpoint string = grafana.properties.endpoint
output grafanaResourceId string = grafana.id
