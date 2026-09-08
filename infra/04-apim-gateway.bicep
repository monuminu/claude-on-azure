// APIM as an Entra-authenticated gateway in front of Claude on Microsoft Foundry.
//
// STATUS: COMPILES; the policy it deploys is VERIFIED. `bicep build` succeeds with no
// errors or warnings (azure-cli 2.81.0) and the embedded policy round-trips correctly.
// The policy itself was proven against a live BasicV2 instance — but applied by
// `az rest`, to an APIM that already existed. This template's own resource
// composition has not been deployed from scratch.
//
//   az deployment group create -g <rg> -f infra/04-apim-gateway.bicep \
//      -p apimName=<name> foundryAccountName=<foundry> \
//         publisherEmail=you@contoso.com gatewayAudience=<app-id>
//
// A v2 tier is REQUIRED: the llm-* policies only understand the Anthropic Messages
// schema on BasicV2 / StandardV2 / PremiumV2. Note that `az apim create --sku-name`
// does not accept the v2 SKUs at all, which is why this is Bicep and not CLI.

param location string = resourceGroup().location
param apimName string
param foundryAccountName string
param publisherEmail string
param publisherName string = 'Platform Engineering'
param entraTenantId string = subscription().tenantId

@description('The aud claim clients present. For an app with requestedAccessTokenVersion 2 this is the BARE application ID, not api://<guid>. Decode a real token to be sure.')
param gatewayAudience string

@description('Resource ID of the Log Analytics workspace that receives GatewayLlmLogs. Uncached input and output counts are exact even for streamed calls; cache tokens are absent from this table.')
param logAnalyticsWorkspaceId string

@description('Per-tier limits. tpm and tokenQuota become named values the policy reads; costQuota is NOT used by APIM at all - it is the dollar budget the usage processor enforces, and it lives here only so all three numbers for a tier are declared in one place. See TIERED-QUOTAS.md for how the token quota is sized (budget divided by the CHEAPEST model rate, so it does not bind before the dollar cap).')
param tiersConfig array = [
  { name: 'pro',   tpm: 40000, tokenQuota: 350000000, costQuota: 1000 }
  { name: 'basic', tpm: 20000, tokenQuota: 175000000, costQuota: 500 }
  { name: 'lite',  tpm: 4000,  tokenQuota: 35000000,  costQuota: 100 }
]

@description('Base URL of the budget API the policy calls on a cache miss, without a trailing slash. Leave at the placeholder to deploy before the budget platform exists: the call fails, ignore-error swallows it, and every request is treated as within budget.')
param budgetApiBaseUrl string = 'https://budget-api.invalid'

@description('Entra audience the gateway requests a managed-identity token for when calling the budget API. Typically the API app registration ID.')
param budgetApiAudience string = 'api://budget-api-placeholder'

@description('Resource ID of an Event Hub authorization rule that receives the same gateway logs as Log Analytics. This is what feeds the near-real-time cost pipeline. Empty disables the Event Hub destination, leaving Log Analytics as the only sink.')
param eventHubAuthorizationRuleId string = ''

@description('Event Hub name within that namespace.')
param eventHubName string = 'claude-gateway-logs'

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  // Capital V, no space. Enum: Basic|BasicV2|Consumption|Developer|Premium|PremiumV2|Standard|StandardV2
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// Named values referenced as {{...}} from the policy file.
resource tenantIdNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-tenant-id'
  properties: {
    displayName: 'entra-tenant-id'
    value: entraTenantId
    secret: false
  }
}

resource audienceNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'claude-gateway-audience'
  properties: {
    displayName: 'claude-gateway-audience'
    value: gatewayAudience
    secret: false
  }
}

resource foundryNameNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'foundry-resource-name'
  properties: {
    displayName: 'foundry-resource-name'
    value: foundryAccountName
    secret: false
  }
}

// Per-tier limits, as named values rather than literals in the policy.
//
// tokens-per-minute is the reason this exists. It is the one llm-token-limit attribute
// that does NOT accept a policy expression, so a named value is the only way to change
// it without editing and redeploying the policy document. counter-key, token-quota and
// token-quota-period do take expressions, but keeping all four numbers in one mechanism
// is worth more than the consistency of using expressions where they happen to work.
//
// UNVERIFIED: the docs describe named value substitution as textual and applicable to
// attribute values generally, but never say numeric attributes specifically. Deploy one
// tier first and confirm the policy applies before trusting all six.
resource tierTpmNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for tier in tiersConfig: {
  parent: apim
  name: 'tier-${tier.name}-tpm'
  properties: {
    displayName: 'tier-${tier.name}-tpm'
    value: string(tier.tpm)
    secret: false
  }
}]

resource tierQuotaNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for tier in tiersConfig: {
  parent: apim
  name: 'tier-${tier.name}-token-quota'
  properties: {
    displayName: 'tier-${tier.name}-token-quota'
    value: string(tier.tokenQuota)
    secret: false
  }
}]

// Where the policy asks "is this developer over budget?". Not a secret - it is a URL,
// and the call is authenticated with the gateway's managed identity, not with anything
// carried in the address.
resource budgetApiUrlNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'budget-api-base-url'
  properties: {
    displayName: 'budget-api-base-url'
    value: budgetApiBaseUrl
    secret: false
  }
}

resource budgetApiAudienceNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'budget-api-audience'
  properties: {
    displayName: 'budget-api-audience'
    value: budgetApiAudience
    secret: false
  }
}

// The gateway contract both Claude clients speak: native Anthropic Messages API.
// subscriptionRequired: false — authentication is Entra ID, not APIM subscription keys.
resource claudeApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'claude-anthropic'
  properties: {
    displayName: 'Claude (Anthropic Messages API)'
    path: 'anthropic'
    protocols: [ 'https' ]
    serviceUrl: 'https://${foundryAccountName}.services.ai.azure.com/anthropic'
    subscriptionRequired: false
  }
}

resource messagesOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: claudeApi
  name: 'messages'
  properties: {
    displayName: 'Create a Message'
    method: 'POST'
    urlTemplate: '/v1/messages'
  }
}

// Claude Desktop probes GET /v1/models to auto-discover models. Foundry does NOT
// implement it — it returns 404 api_not_supported. Defining the
// operation anyway means the probe surfaces Foundry's meaningful error instead of a
// generic APIM 404. Either way you MUST set inferenceModels explicitly on Desktop.
resource modelsOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: claudeApi
  name: 'models'
  properties: {
    displayName: 'List Models'
    method: 'GET'
    urlTemplate: '/v1/models'
  }
}

// Child name must be literally 'policy'.
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: claudeApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('./03-apim-claude-policy.xml')
  }
  dependsOn: [
    tenantIdNv
    audienceNv
    foundryNameNv
    tierTpmNv
    tierQuotaNv
    budgetApiUrlNv
    budgetApiAudienceNv
  ]
}

// ---------------------------------------------------------------------------
// Observability. Without this you get request counts and status codes but no
// token accounting. llm-token-limit enforces budgets from ESTIMATED counts on
// streamed calls; GatewayLlmLogs records exact uncached input/output, but omits
// cache writes (and Log Analytics also omits reads). It is not a complete bill.
// ---------------------------------------------------------------------------

resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: true
  }
}

// Turns on LLM logging for this API. Note the schema: only `logs` is accepted here.
// Supplying largeLanguageModel.requests.messages / .responses.messages is rejected
// with "Invalid field ... specified". Leaving them unset is also what you want —
// message-body capture buffers the response, and buffering breaks SSE.
//
// The header lists are what make per-developer reporting possible. Neither log table
// carries caller identity on its own: GatewayLlmLogs has no caller column, and
// GatewayLogs' UserId / ApimSubscriptionId are empty under Entra auth. VERIFIED:
//   frontend.request.headers  - what the CLIENT sent. User-Agent lands here, and it
//                               is how Claude Code is told apart from Claude Desktop.
//                               Policy-set headers do NOT appear here.
//   backend.request.headers   - what APIM FORWARDS, so the policy's x-caller-* headers
//                               land here. Empty on 429/403: a throttled request never
//                               reaches the backend.
//   frontend.response.headers - the fallback that covers throttled requests, populated
//                               from the outbound and on-error sections of the policy.
//                               x-claude-denied-by lands here too, and it is the only
//                               way to tell the budget 403 from the admin 403 from the
//                               token-quota 403 without parsing bodies.
// Query identity as:
//   coalesce(BackendRequestHeaders['x-caller-oid'], ResponseHeaders['x-caller-oid'])
resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: claudeApi
  name: 'azuremonitor'
  properties: {
    loggerId: azureMonitorLogger.id
    sampling: {
      // 100%, and it has to stay there. Cost is computed per request from these rows;
      // sampling would not make the bill smaller, only wrong.
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [ 'User-Agent' ]
      }
      response: {
        headers: [ 'x-caller-oid', 'x-caller-tier', 'x-claude-denied-by' ]
      }
    }
    backend: {
      request: {
        headers: [ 'x-caller-oid', 'x-caller-upn', 'x-caller-tier' ]
      }
    }
    // Bicep's type definition for DiagnosticContractProperties does not yet know
    // about largeLanguageModel and emits BCP037. The ARM API accepts it — verified
    // by PUT against the 2024-05-01 endpoint — and it survives into the compiled
    // template, so the warning is a type-lag artefact, not a real error.
    #disable-next-line BCP037
    largeLanguageModel: {
      logs: 'enabled'
    }
  }
}

// logAnalyticsDestinationType: 'Dedicated' is required — the ARM equivalent of the
// CLI's --export-to-resource-specific. It is what routes rows into the dedicated
// ApiManagementGatewayLlmLog table, with real column names (PromptTokens,
// CompletionTokens, TotalTokens, IsStreamCompletion, ModelName).
//
// THE EVENT HUB DESTINATION IS THE COST PIPELINE'S SOURCE, and it is here rather than
// in an outbound policy for a specific reason. forward-request runs with
// buffer-response="false" because SSE requires it, so the outbound section executes
// when the response STARTS — before a streamed completion has produced its token
// counts. Both Claude clients stream every request, so an outbound "publish usage
// event" would report on nothing. The diagnostic pipeline writes its record after the
// response finishes, and one setting can fan out to both sinks, so Log Analytics keeps
// feeding the workbook while Event Hub feeds the near-real-time processor.
//
// UNVERIFIED: prove the fan-out delivers to both destinations, and measure the actual
// end-to-end latency, before building on it. It is the load-bearing assumption of the
// entire budget loop.
resource apimDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'claude-gateway-llm-logs'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    eventHubAuthorizationRuleId: empty(eventHubAuthorizationRuleId) ? null : eventHubAuthorizationRuleId
    eventHubName: empty(eventHubAuthorizationRuleId) ? null : eventHubName
    logs: [
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
      {
        category: 'GatewayLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Cognitive Services User — the role that grants inference on the /anthropic surface.
// NOT Cognitive Services OpenAI User (5e0bd9bd-...), which the generic APIM AI docs
// recommend; that one is OpenAI-only. Owner and Contributor do not grant inference.
// Foundry User (53ca6127-db72-4b80-b1b0-d745d6d5456d) is the Foundry-native equivalent.
var cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource inferenceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, apim.id, cognitiveServicesUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output gatewayBaseUrl string = '${apim.properties.gatewayUrl}/anthropic'
output apimPrincipalId string = apim.identity.principalId

// Feed these straight into 14-claude-tiers.bicep and 16-budget-platform.bicep so the
// tier numbers are declared once and consumed everywhere.
output tiers array = tiersConfig
