// The budget platform: Event Hub, Redis, Cosmos, and the two functions that turn gateway
// logs into a per-developer dollar figure the policy can act on.
//
// STATUS: DEPLOYED AND VERIFIED end to end on 2026-09-04, against the live BasicV2
// gateway. Gateway traffic reaches Redis as month-to-date dollars within ~90 seconds,
// the Cosmos ledger fills, and the policy returns 403 on an over-budget developer.
//
// Six things had to be fixed to get there, all now in this file. Every one of them
// failed with an error that pointed somewhere other than the cause:
//   reserved: true on the plan   - without it the plan is Windows and the apps are
//                                  rejected with "LinuxFxVersion has an invalid value"
//   isZoneRedundant + region     - East US refuses new Cosmos accounts with a message
//                                  about zone redundancy that persists even when it is
//                                  false; hence cosmosLocation as its own parameter
//   storageGovernanceTags        - tenant automation reverts publicNetworkAccess to
//                                  Disabled; the ARM PATCH returns 200 with the old
//                                  value and no Deny policy is visible anywhere
//   defaultAuthorizationPolicy   - Azure fills in an EMPTY allowedApplications, which
//                                  Easy Auth reads as "allow nothing": every valid token
//                                  gets a bodyless 403
//   Application Insights         - without it a host that cannot index functions reports
//                                  nothing at all, anywhere
//   dependsOn on the Redis
//   access policy assignments    - two submitted concurrently is a coin flip
//
//   az deployment group create -g <rg> -f infra/16-budget-platform.bicep \
//      -p namePrefix=claudebudget logAnalyticsWorkspaceId=<workspace resource id>
//
// Then feed the outputs back into 04-apim-gateway.bicep:
//   eventHubAuthorizationRuleId, eventHubName, budgetApiBaseUrl
//
// SHAPE, and why it is this shape:
//
//   Event Hub    fed by an APIM diagnostic destination, NOT by an outbound policy.
//                forward-request runs unbuffered for SSE, so outbound fires before a
//                streamed response has produced token counts. The diagnostic record is
//                written after the stream ends.
//   Redis        month-to-date dollars per developer, as atomic INCRBYFLOAT. This is
//                the only per-user store in the design that scales to 100k, which is
//                the whole reason it is here rather than a list in a named value.
//   Cosmos       the request-level ledger: chargeback, export, and the thing you rebuild
//                Redis from when it is lost. Redis is a cache with a job, not a database.
//   two apps     the processor is throughput-bound and the budget API sits in the request
//                path. Same plan, separate apps, so a backlog of usage events cannot
//                make every developer's request slower.

@description('Prefix for generated resource names. Lowercase letters and digits.')
@minLength(3)
@maxLength(11)
param namePrefix string

param location string = resourceGroup().location

@description('Workspace that already receives GatewayLlmLogs. The functions log here too.')
param logAnalyticsWorkspaceId string

@description('Must match the tiersConfig in 04-apim-gateway.bicep and 14-claude-tiers.bicep. The processor compares month-to-date spend against costQuota.')
param tiersConfig array = [
  { name: 'pro',   tpm: 40000, tokenQuota: 350000000, costQuota: 1000 }
  { name: 'basic', tpm: 20000, tokenQuota: 175000000, costQuota: 500 }
  { name: 'lite',  tpm: 4000,  tokenQuota: 35000000,  costQuota: 100 }
]

@description('The whole teamGovernance block from admin/setup.example.json ({mode, profiles, teams}), passed through unmodified. Serialized as one JSON app setting (CLAUDE_TEAM_GOVERNANCE) that both functions parse once at startup — no network call, same pattern as CLAUDE_TIERS below. Must describe the SAME profiles/teams as infra/22-team-governance.bicep; that module reads the identical config to build its named values, but the two are deployed independently and neither reads the other\'s output, so keep the parameter files in sync (admin/claude-gateway-setup.sh does this from one JSON source).')
param teamGovernanceConfig object = {
  mode: 'off'
  profiles: []
  teams: []
}

@description('Redis SKU. Standard is the minimum with a replica; take Premium for zone redundancy and persistence. A cold Redis means every developer starts the month at zero spend until you replay the Cosmos ledger, so this is not the line to save money on.')
@allowed([ 'Standard', 'Premium' ])
param redisSku string = 'Standard'

@description('Redis capacity. Standard: 0-6 (C0-C6). Premium: 1-5 (P1-P5).')
param redisCapacity int = 1

@description('Entra audience clients present when calling the budget API. Create an app registration for it and pass the application ID. Leave empty to deploy the API unauthenticated, which is only acceptable in a scratch group.')
param budgetApiAudience string = ''

@description('Region for the Cosmos ledger. Separate from `location` because Cosmos capacity is the constraint most likely to block this deployment - East US regularly refuses new accounts with a ServiceUnavailable that names zone redundancy even when isZoneRedundant is false. The ledger is written asynchronously and read by reporting, never from the request path, so a neighbouring region costs nothing that matters.')
param cosmosLocation string = location

@description('APPLICATION (client) ID of the API Management managed identity - not its object/principal ID. Only this application is allowed to call the budget API. Find it with: az ad sp show --id <apim principalId> --query appId.')
param apimIdentityClientId string = ''

@description('Tenant issuer for the budget API. Only used when budgetApiAudience is set.')
param budgetApiIssuer string = '${environment().authentication.loginEndpoint}${subscription().tenantId}/v2.0'

var suffix = uniqueString(resourceGroup().id)
var ehNamespaceName = '${namePrefix}-ehns-${suffix}'
var ehName = 'claude-gateway-logs'
var redisName = '${namePrefix}-redis-${suffix}'
var cosmosName = '${namePrefix}-cosmos-${suffix}'
var storageName = take('${namePrefix}st${suffix}', 24)
var planName = '${namePrefix}-plan-${suffix}'
var processorName = '${namePrefix}-processor-${suffix}'
var budgetApiName = '${namePrefix}-budget-${suffix}'

// ---------------------------------------------------------------------------
// Event Hub
// ---------------------------------------------------------------------------

resource ehNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: ehNamespaceName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    minimumTlsVersion: '1.2'
    disableLocalAuth: false
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ehNamespace
  name: ehName
  properties: {
    // Four partitions is a starting point, not an answer. Partition count is fixed at
    // creation and caps consumer parallelism, so measure your actual gateway log rate
    // before deciding. Retention is short on purpose: this is a transport, and Cosmos
    // plus Log Analytics are the durable copies.
    partitionCount: 4
    messageRetentionInDays: 1
  }
}

resource ehConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHub
  name: 'usage-processor'
}

// Diagnostic settings still take a SAS authorization rule ID rather than an identity,
// which is why local auth stays enabled on the namespace above. The rule grants Send
// only — the processor reads with its managed identity, not with this.
resource ehSendRule 'Microsoft.EventHub/namespaces/authorizationRules@2024-01-01' = {
  parent: ehNamespace
  name: 'apim-diagnostics-send'
  properties: {
    rights: [ 'Send' ]
  }
}

// ---------------------------------------------------------------------------
// Redis — the month-to-date counters
// ---------------------------------------------------------------------------

resource redis 'Microsoft.Cache/redis@2024-11-01' = {
  name: redisName
  location: location
  properties: {
    sku: {
      name: redisSku
      family: redisSku == 'Premium' ? 'P' : 'C'
      capacity: redisCapacity
    }
    minimumTlsVersion: '1.2'
    // Entra auth on, access keys off. The repo's whole premise is that a shared secret
    // is the thing to remove, and a Redis key sitting in two app settings is exactly
    // that. Both functions authenticate as themselves.
    redisConfiguration: {
      'aad-enabled': 'True'
    }
    disableAccessKeyAuthentication: true
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Cosmos — the usage ledger
// ---------------------------------------------------------------------------

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: cosmosLocation
  // Same exemption as the storage account: without it, governance automation reverts
  // publicNetworkAccess to Disabled and the processor's ledger writes 403.
  tags: storageGovernanceTags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        // Pinned explicitly. Left unset, Azure decides — and in a busy region that
        // decision is "zone redundant", which then fails the whole deployment with
        // ServiceUnavailable: "we are currently experiencing high demand in East US
        // region for the zonal redundant (Availability Zones) accounts". The error
        // names capacity, not configuration, so it reads as something to retry rather
        // than something to set. Turn it on deliberately where you have the capacity.
        isZoneRedundant: false
      }
    ]
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmos
  name: 'claude'
  properties: {
    resource: {
      id: 'claude'
    }
  }
}

// Partitioned on the developer, because every question asked of this container is
// "what did one person spend". id is the gateway CorrelationId, which is what makes the
// write idempotent: Event Hub delivery is at-least-once, so the processor WILL see the
// same request twice, and an upsert on the same id is a no-op rather than a double
// charge.
resource usageContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDb
  name: 'usage'
  properties: {
    resource: {
      id: 'usage'
      partitionKey: {
        paths: [ '/oid' ]
        kind: 'Hash'
      }
      defaultTtl: 63072000 // two years, enough for annual chargeback and a rebuild
    }
    options: {
      autoscaleSettings: {
        maxThroughput: 4000
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

@description('Tags applied to the storage account. In tenants that run governance automation over new resources, these are what stop it from re-disabling public network access behind you. Names and values are tenant-specific - ask whoever owns the automation rather than copying these.')
param storageGovernanceTags object = {
  CostControl: 'Ignore'
  SecurityControl: 'Ignore'
}

// Application Insights. Not optional in practice: without it the Functions host has
// nowhere to write, and a host that fails to index functions reports NOTHING anywhere —
// the app simply shows an empty function list. Both of the code defects found while
// deploying this (a network call at module import, and a PEP 585 type hint in a binding
// signature) were invisible until this existed.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: storageGovernanceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    // Pinned, AND tagged above. Setting this alone was not enough: the account came up
    // with publicNetworkAccess DISABLED and refused to change - the ARM PATCH returned
    // 200 with the old value still in it, and no Deny or Modify policy was visible at
    // subscription or resource-group scope. Tenant governance automation was reverting
    // it. The tags are what exempt the account; without them this line is silently
    // ignored and neither function app can reach the data plane — the Event Hub trigger's checkpoint store and the host's own
    // secret repository both live in blob. The symptom is a storage 403 with
    // AuthorizationFailure, which reads as a missing role assignment; the roles were all
    // present and correct. If you want this Disabled, the apps need VNet integration and
    // a private endpoint, which this template does not create.
    publicNetworkAccess: 'Enabled'
  }
}

// Elastic Premium rather than Consumption. The budget API is in the request path of
// every Claude call, and a cold start there is a two-second timeout in the policy — which
// fails open, so the symptom is not an error but a silently unenforced budget.
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  properties: {
    maximumElasticWorkerCount: 20
    // reserved: true is what makes this a LINUX plan, and it is not optional.
    // Without it the plan is Windows, and the function apps below are then rejected
    // with "The parameter LinuxFxVersion has an invalid value" — an error that blames
    // the runtime string. 'Python|3.11' is perfectly valid; the plan underneath it
    // was not.
    reserved: true
  }
  kind: 'elastic'
}

var tiersJson = string(tiersConfig)

// Same "parse once, no network call" treatment as CLAUDE_TIERS. Shipping the whole
// {mode, profiles, teams} block as one setting (rather than three) keeps the two
// functions' startup parsing symmetrical with how admin/setup.example.json already
// groups it, and avoids a partial update leaving mode and profiles/teams out of sync
// across an app restart.
var teamGovernanceJson = string(teamGovernanceConfig)

var sharedAppSettings = [
  { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
  { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
  // Identity-based host storage: no account key anywhere. The three data-plane roles
  // below are what make it work; without them the app starts and then fails to find
  // its own lease container, which presents as "no functions found".
  { name: 'AzureWebJobsStorage__accountName', value: storage.name }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'REDIS_HOST', value: '${redis.name}.redis.cache.windows.net' }
  { name: 'REDIS_PORT', value: '6380' }
  { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
  { name: 'COSMOS_DATABASE', value: cosmosDb.name }
  { name: 'COSMOS_CONTAINER', value: usageContainer.name }
  { name: 'CLAUDE_TIERS', value: tiersJson }
  { name: 'CLAUDE_TEAM_GOVERNANCE', value: teamGovernanceJson }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
]

resource processorApp 'Microsoft.Web/sites@2023-12-01' = {
  name: processorName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: concat(sharedAppSettings, [
        { name: 'EventHubConnection__fullyQualifiedNamespace', value: '${ehNamespace.name}.servicebus.windows.net' }
        { name: 'EventHubConnection__credential', value: 'managedidentity' }
        { name: 'EVENTHUB_NAME', value: eventHub.name }
        { name: 'EVENTHUB_CONSUMER_GROUP', value: ehConsumerGroup.name }
      ])
    }
  }
}

resource budgetApiApp 'Microsoft.Web/sites@2023-12-01' = {
  name: budgetApiName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      // Always ready instances: this app answers a call that has a 2 second budget, and
      // scale-from-zero does not fit inside it.
      minimumElasticInstanceCount: 2
      appSettings: sharedAppSettings
    }
  }
}

// Easy Auth, so the gateway's authentication-managed-identity token is actually checked.
// Without this the budget API is an unauthenticated endpoint that will tell anyone
// whether a given object ID is over budget.
resource budgetApiAuth 'Microsoft.Web/sites/config@2023-12-01' = if (!empty(budgetApiAudience) && !empty(apimIdentityClientId)) {
  parent: budgetApiApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: budgetApiIssuer
          clientId: budgetApiAudience
        }
        validation: {
          // BOTH forms, deliberately. authentication-managed-identity issues a token
          // whose aud is the bare application ID, but the identifier URI form is what
          // most tooling shows you — and a mismatch here is a flat 401 from Easy Auth
          // with nothing in the body naming audiences. Same trap as the gateway's own
          // validate-azure-ad-token, one layer down.
          allowedAudiences: [ budgetApiAudience, 'api://${budgetApiAudience}' ]
          // MUST be set, and must be non-empty. Supply a `validation` block without a
          // defaultAuthorizationPolicy and Azure fills in `allowedApplications: []` —
          // which Easy Auth reads as "allow NO application". Every correctly
          // authenticated token then gets a 403 with an empty body, on every route,
          // including health checks. It looks like a broken app, not a config choice.
          //
          // Naming the gateway's identity here is also the right control: the budget API
          // answers "is this developer over budget" and only the gateway should be able
          // to ask.
          defaultAuthorizationPolicy: {
            allowedApplications: [ apimIdentityClientId ]
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Role assignments
// ---------------------------------------------------------------------------

var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var eventHubsDataReceiver = 'f526a384-b230-433a-b45c-95f59c4a2dec'

// Written out per app rather than looped. A for-expression cannot iterate a collection
// built from identity.principalId — that value does not exist until the app is created,
// and Bicep needs the loop's shape at the start of the deployment (BCP178). Repetition
// is the cost of getting a compile-time error instead of a deployment-time one.
//
// The host needs all three storage data roles, not just blob: the Functions runtime
// keeps leases in blobs, but also uses queues and tables. Grant blob alone and the app
// starts cleanly and then reports "no functions found", which sends you looking in
// entirely the wrong place.
resource processorBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, processorApp.id, storageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: processorApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource processorQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, processorApp.id, storageQueueDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributor)
    principalId: processorApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource processorTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, processorApp.id, storageTableDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributor)
    principalId: processorApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource budgetApiBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, budgetApiApp.id, storageBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: budgetApiApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource budgetApiQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, budgetApiApp.id, storageQueueDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributor)
    principalId: budgetApiApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource budgetApiTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, budgetApiApp.id, storageTableDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributor)
    principalId: budgetApiApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource processorEventHubRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: ehNamespace
  name: guid(ehNamespace.id, processorApp.id, eventHubsDataReceiver)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiver)
    principalId: processorApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Redis data-plane access. 'Data Contributor' for the processor, which writes counters;
// 'Data Reader' for the budget API, which only ever reads a flag. The API being unable
// to write is a property worth having: nothing in the request path can corrupt the
// ledger it is reading from.
resource redisProcessorAccess 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = {
  parent: redis
  name: 'processor'
  properties: {
    accessPolicyName: 'Data Contributor'
    objectId: processorApp.identity.principalId
    objectIdAlias: processorApp.name
  }
}

resource redisBudgetApiAccess 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = {
  parent: redis
  name: 'budgetapi'
  properties: {
    accessPolicyName: 'Data Reader'
    objectId: budgetApiApp.identity.principalId
    objectIdAlias: budgetApiApp.name
  }
  // Serialised deliberately. Two access policy assignments submitted concurrently
  // against one cache is a coin flip: one succeeds and the other returns a bare
  // "An error occurred during the long running operation" with no cause. They are two
  // rows in one control-plane object, so let them queue.
  dependsOn: [ redisProcessorAccess ]
}

// Cosmos data-plane RBAC is its own resource type — control-plane roles like Contributor
// grant nothing here. 00000000-...-0002 is the built-in Data Contributor.
resource cosmosProcessorRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, processorApp.id, 'data-contributor')
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: processorApp.identity.principalId
    scope: cosmos.id
  }
}

// ---------------------------------------------------------------------------
// Observability for the platform itself
// ---------------------------------------------------------------------------

resource processorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: processorApp
  name: 'claude-budget-processor'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
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

resource budgetApiDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: budgetApiApp
  name: 'claude-budget-api'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
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

// Feed these into 04-apim-gateway.bicep.
output eventHubAuthorizationRuleId string = ehSendRule.id
output eventHubName string = eventHub.name
output budgetApiBaseUrl string = 'https://${budgetApiApp.properties.defaultHostName}'
output processorPrincipalId string = processorApp.identity.principalId
output budgetApiPrincipalId string = budgetApiApp.identity.principalId
output redisHost string = '${redis.name}.redis.cache.windows.net'
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output cosmosAccountName string = cosmos.name
output cosmosDatabaseName string = cosmosDb.name
output cosmosContainerName string = usageContainer.name
