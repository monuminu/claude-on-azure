// Grants the cost reconciler's identity Monitoring Reader on the Foundry account.
//
// 20-cost-reconciler.py reads the account's Azure Monitor metrics — cacheReadInputTokens,
// ephemeral5mInputTokens, ephemeral1hInputTokens — because those are the only place cache
// WRITE tokens are reported anywhere on Azure. Reading them needs
// Microsoft.Insights/metrics/read at or above the account's scope.
//
// NOTE what this does NOT cover. Cognitive Services User (granted to APIM in
// 04-apim-gateway.bicep) does not include metrics/read, so the gateway's own identity
// cannot do this. Nor can Grafana's: its Monitoring Reader is scoped to a Log Analytics
// workspace, and a workspace grant confers nothing on a Cognitive Services account.
// Whoever runs the reconciler needs this assignment specifically.
//
// This is a MODULE for the same reason as 11a: the Foundry account usually sits in a
// different resource group from the gateway, and Bicep rejects a cross-resource-group
// role assignment with BCP139. Deploy it into the account's resource group:
//
//   module reconcilerRbac '21-reconciler-metrics-rbac.bicep' = {
//     name: 'reconciler-metrics-rbac'
//     scope: resourceGroup(split(foundryAccountId, '/')[4])
//     params: {
//       foundryAccountName: split(foundryAccountId, '/')[8]
//       readerPrincipalId: <the reconciler's identity>
//     }
//   }

@description('Name of the Foundry / Cognitive Services account, within this module\'s target resource group.')
param foundryAccountName string

@description('Principal ID that runs 20-cost-reconciler.py. A managed identity once scheduled; your own object ID while running it by hand.')
param readerPrincipalId string

@description('Principal type. Use ServicePrincipal for a managed identity, User for a hand-run loader.')
@allowed([ 'ServicePrincipal', 'User' ])
param readerPrincipalType string = 'ServicePrincipal'

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

// Monitoring Reader. Read-only across metrics and monitoring settings — it grants no
// access to the models themselves and cannot issue inference requests.
var monitoringReader = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource reconcilerReadsMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, readerPrincipalId, monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: readerPrincipalId
    principalType: readerPrincipalType
  }
}
