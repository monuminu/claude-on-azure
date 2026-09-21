@description('Name of the Foundry / Cognitive Services account, within this module\'s target resource group.')
param foundryAccountName string

@description('Principal ID of the API Management system-assigned managed identity.')
param apimPrincipalId string

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

// Cognitive Services User grants inference on the /anthropic surface. The OpenAI User role is OpenAI-only.
var cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource inferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, apimPrincipalId, cognitiveServicesUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}
