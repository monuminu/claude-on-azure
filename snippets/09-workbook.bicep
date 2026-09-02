// Admin usage workbook for Claude behind the API Management gateway.
//
// STATUS: VERIFIED. Deployed to a live BasicV2 gateway + Log Analytics workspace on
// 2026-09-02. All 22 queries in the workbook were executed against real data before
// deployment; every tile rendered.
//
//   az deployment group create -g <rg> -f 09-workbook.bicep \
//      -p logAnalyticsWorkspaceId=<workspace resource id>
//
// PREREQUISITES — the workbook is anonymous without both of these:
//   1. The gateway policy stamps x-caller-oid / x-caller-upn (03-apim-claude-policy.xml)
//   2. The API diagnostic logs those headers plus User-Agent (04-apim-gateway.bicep)
// Deploy this on its own only if you already have both.

@description('Resource ID of the Log Analytics workspace receiving GatewayLlmLogs and GatewayLogs.')
param logAnalyticsWorkspaceId string

param location string = resourceGroup().location

@description('Display name shown in the Azure Monitor workbook gallery.')
param workbookDisplayName string = 'Claude usage — gateway view'

// The workbook JSON ships with a placeholder fallbackResourceIds so it is portable.
// Substituting the real workspace here means the workbook opens with its parameters
// already resolved instead of prompting on first load.
var workbookJson = replace(
  loadTextContent('./08-claude-usage-workbook.json'),
  '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/PLACEHOLDER/providers/Microsoft.OperationalInsights/workspaces/PLACEHOLDER',
  logAnalyticsWorkspaceId
)

// The resource NAME must be a GUID — a friendly name is rejected. guid() keeps it
// deterministic, so redeploying updates the same workbook instead of creating another.
resource claudeUsageWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-usage-workbook')
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    version: 'Notebook/1.0'
    sourceId: logAnalyticsWorkspaceId
    serializedData: workbookJson
  }
}

output workbookId string = claudeUsageWorkbook.id
output portalUrl string = 'https://portal.azure.com/#@/resource${claudeUsageWorkbook.id}/workbook'
