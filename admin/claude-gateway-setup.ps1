#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('all', 'preflight', 'reporting', 'retention', 'export')][string]$Stage = 'all',
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Config = $null
$WorkspaceGroup = ''
$WorkspaceName = ''
$Output = ''
$Temp = ''
$Account = $null
$Identity = $null
$Models = @()
$App = $null
$Resources = @()
$Apim = $null
$ApimClientId = ''
$DesktopClientId = ''
$Tiers = $null
$Budget = $null
$Apps = @()
$ProcessorName = ''
$BudgetName = ''
$Quota = $null

function Invoke-Azure {
    $Arguments = $args
    $Result = & az @Arguments --subscription $Config.subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' '). Resolve the error and rerun; no resources are automatically deleted." }
    return $Result
}
function Invoke-Deployment([string]$Name, [string]$Group, [string]$File, [hashtable]$Parameters) {
    Write-Host "Deploying $Name in $Group"
    $Wrapped = @{}
    foreach ($Key in $Parameters.Keys) { $Wrapped[$Key] = @{ value = $Parameters[$Key] } }
    $ParameterFile = Join-Path $Temp "$Name.parameters.json"
    $Wrapped | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8NoBOM $ParameterFile
    $Result = Invoke-Azure deployment group create --name $Name --resource-group $Group --template-file (Join-Path $Root $File) --parameters "@$ParameterFile" -o json
    $Result = $Result | ConvertFrom-Json -AsHashtable
    if ($Result.properties.provisioningState -ne 'Succeeded') { throw "$Name did not succeed." }
    return $Result.properties.outputs
}
function Get-GatewayParameters {
    return @{
        apimName = $Config.apimName; apimLocation = $Config.apimLocation; foundryAccountName = $Config.foundryAccountName
        publisherEmail = $Config.publisherEmail; publisherName = $Config.publisherName; entraTenantId = $Config.tenantId
        gatewayAudience = $Config.gatewayAudience; logAnalyticsWorkspaceId = $Config.workspaceResourceId; tiersConfig = $Config.tiersConfig
    }
}
function Initialize-ClaudeDesktopClient {
    $Name = "Claude Desktop - $($Config.apimName)"
    $ClientId = $Config.clientConfiguration.clientId
    if ($ClientId) {
        $ClientApp = Invoke-Azure ad app show --id $ClientId -o json | ConvertFrom-Json -AsHashtable
    } else {
        $ClientApps = @(Invoke-Azure ad app list --display-name $Name -o json | ConvertFrom-Json -AsHashtable)
        if ($ClientApps.Count -gt 1) { throw "Multiple Entra applications are named '$Name'; set clientConfiguration.clientId explicitly." }
        if ($ClientApps.Count -eq 1) {
            $ClientApp = $ClientApps[0]
        } else {
            $ClientApp = Invoke-Azure ad app create --display-name $Name --sign-in-audience AzureADMyOrg `
                --is-fallback-public-client true --public-client-redirect-uris 'http://127.0.0.1/callback' 'http://localhost' -o json |
                ConvertFrom-Json -AsHashtable
        }
        $ClientId = $ClientApp.appId
    }
    if ($ClientApp.signInAudience -ne 'AzureADMyOrg' -or -not $ClientApp.isFallbackPublicClient -or
        'http://localhost' -notin $ClientApp.publicClient.redirectUris -or
        'http://127.0.0.1/callback' -notin $ClientApp.publicClient.redirectUris) {
        throw 'Desktop client must be a single-tenant public client with http://localhost and http://127.0.0.1/callback redirects.'
    }
    $Scope = @($App.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access_as_user' -and $_.isEnabled })
    if ($Scope.Count -ne 1) { throw 'Gateway API must expose one enabled access_as_user scope.' }
    $GatewayAccess = @($ClientApp.requiredResourceAccess | Where-Object { $_.resourceAppId -eq $Config.gatewayAudience })
    $HasPermission = @($GatewayAccess.resourceAccess | Where-Object { $_.id -eq $Scope[0].id -and $_.type -eq 'Scope' }).Count -gt 0
    if (-not $HasPermission) {
        Invoke-Azure ad app permission add --id $ClientId --api $Config.gatewayAudience --api-permissions "$($Scope[0].id)=Scope" -o none | Out-Null
    }
    $ServicePrincipals = @(Invoke-Azure ad sp list --filter "appId eq '$ClientId'" -o json | ConvertFrom-Json -AsHashtable)
    if ($ServicePrincipals.Count -eq 0) { Invoke-Azure ad sp create --id $ClientId -o none | Out-Null }
    $PreAuthorizedApplications = @($App.api.preAuthorizedApplications | Where-Object { $_.appId -ne $ClientId })
    $PreAuthorizedApplications += @{ appId = $ClientId; delegatedPermissionIds = @($Scope[0].id) }
    $App.api.preAuthorizedApplications = $PreAuthorizedApplications
    $Body = @{ api = $App.api } | ConvertTo-Json -Depth 30 -Compress
    Invoke-Azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$($App.id)" `
        --headers Content-Type=application/json --body $Body -o none | Out-Null
    Write-Host "Claude Desktop public client: $ClientId"
    return $ClientId
}
function Export-Configuration {
    $ClientSettings = $Config.clientConfiguration.settingsFile
    if ($ClientSettings -and -not [IO.Path]::IsPathRooted($ClientSettings)) { $ClientSettings = Join-Path $Root $ClientSettings }
    & (Join-Path $PSScriptRoot 'export-claude-client-configuration.ps1') -SubscriptionId $Config.subscriptionId -TenantId $Config.tenantId `
        -ClientId $Config.clientConfiguration.clientId -Scopes $Config.clientConfiguration.scopes -ClientSettings $ClientSettings `
        -ResourceGroup $Config.resourceGroup -TokenResource $Config.tokenResource -OpusModel $Config.models.opus `
        -SonnetModel $Config.models.sonnet -HaikuModel $Config.models.haiku -Output $Output -Force
}
function Set-Retention {
    $TableId = "$($Config.workspaceResourceId)/tables/ClaudeUsageHourly_CL"
    Invoke-Azure resource wait --exists --ids $TableId --api-version 2022-10-01 --interval 60 --timeout $Config.retentionTimeoutSeconds
    $Body = Join-Path $Temp 'retention.json'
    @{ properties = @{ retentionInDays = 30; totalRetentionInDays = 400 } } | ConvertTo-Json | Set-Content -Encoding utf8NoBOM $Body
    Invoke-Azure rest --method patch --url "https://management.azure.com${TableId}?api-version=2022-10-01" --body "@$Body" -o none
}
function Invoke-Reporting {
    if ($Config.options.workbook) {
        Invoke-Deployment '09-workbook' $Config.resourceGroup 'infra/09-workbook.bicep' @{
            logAnalyticsWorkspaceId = $Config.workspaceResourceId; workbookLocation = $Config.workbookLocation
        } | Out-Null
    }
    if ($Config.options.summaryRule) {
        Invoke-Deployment '10-claude-usage-summary-rule' $WorkspaceGroup 'infra/10-claude-usage-summary-rule.bicep' @{ workspaceName = $WorkspaceName } | Out-Null
        Set-Retention
    }
    if ($Config.options.grafana) {
        Invoke-Deployment '11-grafana' $Config.resourceGroup 'infra/11-grafana.bicep' @{
            grafanaName = $Config.grafanaName; location = $Config.grafanaLocation
            logAnalyticsWorkspaceId = $Config.workspaceResourceId; adminPrincipalId = $Config.grafanaAdminPrincipalId
        } | Out-Null
        Invoke-Azure extension add --name amg --upgrade -o none
        $Dashboard = Join-Path $Temp 'dashboard.json'
        $DashboardContent = & jq --arg workspace $Config.workspaceResourceId 'walk(if type == "string" then gsub("WORKSPACE_RESOURCE_ID_PLACEHOLDER"; $workspace) else . end)' (Join-Path $Root 'infra/12-claude-usage-grafana-dashboard.json')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare Grafana dashboard.' }
        $DashboardContent | Set-Content -Encoding utf8NoBOM $Dashboard
        Invoke-Azure grafana dashboard create --name $Config.grafanaName --resource-group $Config.resourceGroup --definition "@$Dashboard" --overwrite true -o none
    }
}
function Publish-Function([string]$Name, [string]$Directory) {
    Push-Location (Join-Path $Root $Directory)
    try {
        & func azure functionapp publish $Name --subscription $Config.subscriptionId --python --build remote
        if ($LASTEXITCODE -ne 0) { throw "Function publication failed: $Name" }
    } finally { Pop-Location }
}

Get-Command jq -ErrorAction Stop | Out-Null
$Config = & jq -ef (Join-Path $PSScriptRoot 'validate-config.jq') $ConfigPath
if ($LASTEXITCODE -ne 0) { throw 'Invalid admin config.' }
$Config = $Config | ConvertFrom-Json -AsHashtable
$WorkspaceGroup = $Config.workspaceResourceId.Split('/')[4]
$WorkspaceName = $Config.workspaceResourceId.Split('/')[-1]
$Output = $Config.onboardingOutput
if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Root $Output }
Write-Host "Stage=$Stage; subscription=$($Config.subscriptionId); resource group=$($Config.resourceGroup); APIM=$($Config.apimName) ($($Config.apimLocation)); budget=$($Config.budgetLocation); Cosmos=$($Config.cosmosLocation)"
Write-Host 'Order: preflight -> bootstrap APIM only if absent -> tiers/DCR -> authenticated budget platform -> pricing permissions + both price stores -> publish Functions -> final APIM -> onboarding export -> optional smoke/reporting/reconciliation.'
Write-Host "Options: $($Config.options | ConvertTo-Json -Compress)"
Write-Host 'StandardV2 APIM, EP1, Redis, Cosmos, Event Hub and optional Grafana incur charges. Budget accounting is asynchronous, fail-open and excludes cache writes.'
if ($DryRun) { Write-Host 'DRY RUN: configuration validated. No writes, installs, logins, Azure calls or inference.'; return }
Get-Command az -ErrorAction Stop | Out-Null
$Account = Invoke-Azure account show -o json | ConvertFrom-Json -AsHashtable
if ($Account.tenantId -ne $Config.tenantId) { throw 'Wrong Azure tenant; log in to the configured tenant.' }
if ($Stage -ne 'preflight' -and -not $Yes) { throw 'Review -DryRun, then pass -Yes to authorize the selected changes.' }
$Temp = Join-Path ([IO.Path]::GetTempPath()) "claude-admin-$([Guid]::NewGuid())"
[IO.Directory]::CreateDirectory($Temp) | Out-Null
try {
    if ($Stage -eq 'export') {
        $App = Invoke-Azure ad app show --id $Config.gatewayAudience -o json | ConvertFrom-Json -AsHashtable
        $Config.clientConfiguration.clientId = Initialize-ClaudeDesktopClient
        Export-Configuration
        return
    }
    if ($Stage -eq 'retention') { Set-Retention; return }
    if ($Stage -eq 'reporting') { Invoke-Reporting; return }
    Get-Command func -ErrorAction Stop | Out-Null
    Get-Command $Config.pythonExecutable -ErrorAction Stop | Out-Null
    & $Config.pythonExecutable -c 'import azure.identity, azure.monitor.ingestion, requests, redis'
    if ($LASTEXITCODE -ne 0) { throw 'Install Python loader dependencies in pythonExecutable environment.' }
    $Identity = & $Config.pythonExecutable -c 'import base64,json; from azure.identity import DefaultAzureCredential; token=DefaultAzureCredential().get_token("https://management.azure.com/.default").token.split(".")[1]; claims=json.loads(base64.urlsafe_b64decode(token+"="*(-len(token)%4))); print(json.dumps({"oid":claims["oid"],"tid":claims["tid"]}))'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check Python credential identity.' }
    $Identity = $Identity | ConvertFrom-Json -AsHashtable
    if ($Identity.oid -ne $Config.pricingPublisherPrincipalId -or $Identity.tid -ne $Config.tenantId) { throw 'Python credential identity does not match pricingPublisherPrincipalId/tenantId.' }
    Invoke-Azure group show --name $Config.resourceGroup -o none
    Invoke-Azure cognitiveservices account show --name $Config.foundryAccountName --resource-group $Config.resourceGroup -o none
    if ((Invoke-Azure resource show --ids $Config.workspaceResourceId --query location -o tsv) -ne $Config.workspaceLocation) { throw 'workspaceLocation does not match the existing workspace.' }
    $Models = @(Invoke-Azure cognitiveservices account deployment list --name $Config.foundryAccountName --resource-group $Config.resourceGroup -o json | ConvertFrom-Json -AsHashtable)
    foreach ($Family in @('opus', 'sonnet', 'haiku')) {
        if (-not $Config.models[$Family]) {
            $Candidates = @($Models | Where-Object { ($_.properties.model.name ?? $_.name) -like "*$Family*" })
            if ($Candidates.Count -ne 1) { throw "Set models.${Family}: no unique deployment." }
            $Config.models[$Family] = $Candidates[0].name
        }
        if ($Config.models[$Family] -notin $Models.name) { throw "Configured $Family model is not deployed in Foundry." }
    }
    $App = Invoke-Azure ad app show --id $Config.gatewayAudience -o json | ConvertFrom-Json -AsHashtable
    if ($App.api.requestedAccessTokenVersion -ne 2 -or $Config.tokenResource -notin $App.identifierUris -or
        -not @($App.appRoles | Where-Object { $_.value -eq 'Claude.User' -and $_.isEnabled }).Count) {
        throw 'Gateway app needs v2 tokens, the configured identifier URI and an enabled Claude.User role.'
    }
    if ($Stage -ne 'preflight') { $Config.clientConfiguration.clientId = Initialize-ClaudeDesktopClient }
    Invoke-Azure ad sp show --id $Config.budgetApiAudience -o none
    $Resources = @(Invoke-Azure resource list --resource-group $Config.resourceGroup -o json | ConvertFrom-Json -AsHashtable)
    foreach ($Resource in $Resources) {
        if (($Resource.type -eq 'Microsoft.ApiManagement/service' -and $Resource.name -eq $Config.apimName) -or
            ($Resource.name.StartsWith("$($Config.namePrefix)-") -and $Resource.type -in @('Microsoft.EventHub/namespaces', 'Microsoft.Web/serverfarms', 'Microsoft.Cache/redis'))) {
            if ($Resource.location -ne $Config.apimLocation) { throw 'Existing resources are in another region. Relocation requires a separate, approved migration; nothing will be deleted.' }
        }
    }
    $Apim = @($Resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service' -and $_.name -eq $Config.apimName })
    if ($Config.options.checkEp1Quota) {
        Invoke-Azure extension show --name quota -o none
        $Scope = "/subscriptions/$($Config.subscriptionId)/providers/Microsoft.Web/locations/$($Config.budgetLocation)"
        $Quota = Invoke-Azure quota show --resource-name EP1 --scope $Scope -o json | ConvertFrom-Json -AsHashtable
        if ($Quota.properties.limit.value -lt 2) { throw 'EP1 limit must support at least two always-ready instances. Request quota or select another region; no quota changes are automatic.' }
        Invoke-Azure quota usage show --resource-name EP1 --scope $Scope -o json
        Write-Host 'Quota limit/usage are advisory; they do not guarantee free regional capacity or Cosmos availability.'
    }
    foreach ($Template in @((Get-ChildItem (Join-Path $Root 'infra/*.bicep')).FullName) + @((Join-Path $PSScriptRoot 'pricing-access.bicep'))) {
        & az bicep build --file $Template --stdout | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $Template" }
    }
    if ($Stage -eq 'preflight') { Write-Host 'Preflight passed; no resource changes made.'; return }
    if (-not $Config.options.pricesReviewed) { throw 'Review PRICES in snippets/15-load-pricing.py against your agreement, then set options.pricesReviewed=true.' }
    if ($Config.options.registerProviders) {
        foreach ($Provider in @('Microsoft.ApiManagement', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.EventHub', 'Microsoft.Cache', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.Dashboard')) {
            Invoke-Azure provider register --namespace $Provider --wait -o none
        }
    }
    if ($Apim.Count -eq 0) { Invoke-Deployment '04-apim-gateway' $Config.resourceGroup 'infra/04-apim-gateway.bicep' (Get-GatewayParameters) | Out-Null }
    $Apim = Invoke-Azure apim show --name $Config.apimName --resource-group $Config.resourceGroup -o json | ConvertFrom-Json -AsHashtable
    $ApimClientId = Invoke-Azure ad sp show --id $Apim.identity.principalId --query appId -o tsv
    if (-not $ApimClientId) { throw 'APIM managed identity client ID not available yet; rerun after propagation.' }
    $Tiers = Invoke-Deployment '14-claude-tiers' $WorkspaceGroup 'infra/14-claude-tiers.bicep' @{
        workspaceName = $WorkspaceName; location = $Config.workspaceLocation; tiersConfig = $Config.tiersConfig
        pricingPublisherPrincipalId = $Config.pricingPublisherPrincipalId; pricingPublisherPrincipalType = $Config.pricingPublisherPrincipalType
    }
    $Budget = Invoke-Deployment '16-budget-platform' $Config.resourceGroup 'infra/16-budget-platform.bicep' @{
        namePrefix = $Config.namePrefix; location = $Config.budgetLocation; cosmosLocation = $Config.cosmosLocation
        logAnalyticsWorkspaceId = $Config.workspaceResourceId; tiersConfig = $Config.tiersConfig
        budgetApiAudience = $Config.budgetApiAudience; apimIdentityClientId = $ApimClientId
        redisSku = $Config.redisSku; redisCapacity = $Config.redisCapacity; storageGovernanceTags = $Config.storageGovernanceTags
    }
    Invoke-Deployment 'pricing-access' $Config.resourceGroup 'admin/pricing-access.bicep' @{
        redisName = $Budget.redisHost.value.Split('.')[0]; pricingPublisherPrincipalId = $Config.pricingPublisherPrincipalId
        pricingPublisherPrincipalType = $Config.pricingPublisherPrincipalType; foundryAccountName = $Config.foundryAccountName; enableReconciler = $Config.options.reconcile
    } | Out-Null
    & $Config.pythonExecutable (Join-Path $Root 'snippets/15-load-pricing.py') --dcr-endpoint $Tiers.pricingDcrEndpoint.value `
        --dcr-immutable-id $Tiers.pricingDcrImmutableId.value --redis-host $Budget.redisHost.value
    if ($LASTEXITCODE -ne 0) { throw 'Price loading failed; check RBAC propagation and network access before rerunning.' }
    $Apps = @(Invoke-Azure functionapp list --resource-group $Config.resourceGroup -o json | ConvertFrom-Json -AsHashtable)
    $ProcessorApps = @($Apps | Where-Object { $_.identity.principalId -eq $Budget.processorPrincipalId.value })
    $BudgetApps = @($Apps | Where-Object { $_.identity.principalId -eq $Budget.budgetApiPrincipalId.value })
    if ($ProcessorApps.Count -ne 1 -or $BudgetApps.Count -ne 1) { throw 'Cannot uniquely resolve Function app names.' }
    Publish-Function $BudgetApps[0].name 'snippets/18-budget-api'
    Publish-Function $ProcessorApps[0].name 'snippets/17-usage-processor'
    $Parameters = Get-GatewayParameters
    $Parameters.eventHubAuthorizationRuleId = $Budget.eventHubAuthorizationRuleId.value
    $Parameters.eventHubName = $Budget.eventHubName.value
    $Parameters.budgetApiBaseUrl = $Budget.budgetApiBaseUrl.value
    $Parameters.budgetApiAudience = $Config.budgetApiAudience
    Invoke-Deployment '04-apim-gateway' $Config.resourceGroup 'infra/04-apim-gateway.bicep' $Parameters | Out-Null
    Export-Configuration
    if ($Config.options.smokeTest) { & (Join-Path $Root 'developer/setup-claude-workstation.ps1') -ConfigPath $Output -TestOnly }
    Invoke-Reporting
    if ($Config.options.reconcile) {
        & $Config.pythonExecutable (Join-Path $Root 'snippets/20-cost-reconciler.py') `
            --resource-id "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($Config.foundryAccountName)" `
            --hours $Config.reconcileHours --dcr-endpoint $Tiers.pricingDcrEndpoint.value --dcr-immutable-id $Tiers.pricingDcrImmutableId.value
        if ($LASTEXITCODE -ne 0) { throw 'Cost reconciliation failed.' }
    }
    Write-Host 'Selected steps completed. Runtime budget enforcement still requires traffic, telemetry delivery and per-tier verification; deployment success alone is not proof.'
} finally { Remove-Item -LiteralPath $Temp -Recurse -Force }