param redisName string
param pricingPublisherPrincipalId string
@allowed([ 'User', 'ServicePrincipal' ])
param pricingPublisherPrincipalType string
param foundryAccountName string
param enableReconciler bool = false

resource redis 'Microsoft.Cache/redis@2024-11-01' existing = {
  name: redisName
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
  params: {
    foundryAccountName: foundryAccountName
    readerPrincipalId: pricingPublisherPrincipalId
    readerPrincipalType: pricingPublisherPrincipalType
  }
}
