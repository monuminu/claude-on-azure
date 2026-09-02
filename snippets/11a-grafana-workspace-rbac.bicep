// Grants Grafana's managed identity Monitoring Reader on the Log Analytics workspace.
//
// This is a MODULE rather than a resource in 11-grafana.bicep because the workspace is
// usually in a different resource group from Grafana - Azure's own default workspaces
// live in DefaultResourceGroup-<region>. Bicep rejects a role assignment scoped across
// resource groups with BCP139 ("A resource's scope must match the scope of the Bicep
// file"). A module deployed into the workspace's resource group is the supported way.

@description('Name of the Log Analytics workspace, within this module\'s target resource group.')
param workspaceName string

@description('Principal ID of the Grafana system-assigned managed identity.')
param grafanaPrincipalId string

@description('Resource ID of the Grafana instance, used only to make the assignment GUID deterministic.')
param grafanaResourceId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// Monitoring Reader — what lets Grafana actually run KQL against the workspace. Without
// it the instance deploys fine and then every panel returns a permissions error that
// reads like a broken datasource.
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource grafanaReadsLogs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: workspace
  name: guid(workspace.id, grafanaResourceId, monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: grafanaPrincipalId
    principalType: 'ServicePrincipal'
  }
}
