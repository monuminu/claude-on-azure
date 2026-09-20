param redisName string
param pricingPublisherPrincipalId string
@allowed([ 'User', 'ServicePrincipal' ])
param pricingPublisherPrincipalType string
param foundryAccountName string
param foundryResourceGroup string = resourceGroup().name
param enableReconciler bool = false
param cosmosAccountName string = ''

resource redis 'Microsoft.Cache/redis@2024-11-01' existing = {
  name: redisName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (enableReconciler) {
  name: cosmosAccountName
}

resource pricingAccess 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = {
  parent: redis
  name: 'pricing-${pricingPublisherPrincipalId}'
  properties: {
    accessPolicyName: 'Data Contributor'
    objectId: pricingPublisherPrincipalId
    objectIdAlias: 'Claude pricing publisher'
  }
}

module reconciler '../infra/21-reconciler-metrics-rbac.bicep' = if (enableReconciler) {
  name: 'reconciler-metrics-rbac'
  scope: resourceGroup(foundryResourceGroup)
  params: {
    foundryAccountName: foundryAccountName
    readerPrincipalId: pricingPublisherPrincipalId
    readerPrincipalType: pricingPublisherPrincipalType
  }
}

resource reconcilerCosmosReader 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (enableReconciler) {
  parent: cosmos
  name: guid(cosmos.id, pricingPublisherPrincipalId, 'ledger-reader')
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001'
    principalId: pricingPublisherPrincipalId
    scope: cosmos.id
  }
}
