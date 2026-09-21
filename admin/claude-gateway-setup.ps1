#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('all', 'preflight', 'reporting', 'retention', 'export')][string]$Stage = 'all',
    [switch]$Interactive,
    [switch]$NonInteractive,
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
$Governance = $null
$Apps = @()
$ProcessorName = ''
$BudgetName = ''
$Quota = $null
$EffectiveConfigPath = ''

function Invoke-Azure {
    $Arguments = $args
    $Result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' '). Resolve the error and rerun; no resources are automatically deleted." }
    return $Result
}
function Install-Prerequisites {
    if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
        if ($IsMacOS) {
            if (-not (Get-Command brew -ErrorAction SilentlyContinue)) { throw 'Homebrew is required to install Azure Functions Core Tools v4 automatically.' }
            Write-Host 'Installing Azure Functions Core Tools v4 with Homebrew.'
            & brew tap azure/functions
            if ($LASTEXITCODE -ne 0) { throw 'Homebrew could not add the Azure Functions tap.' }
            & brew install azure-functions-core-tools@4
            if ($LASTEXITCODE -ne 0) { throw 'Homebrew could not install Azure Functions Core Tools v4.' }
        } elseif ($IsWindows) {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Host 'Installing Azure Functions Core Tools v4 with WinGet.'
                & winget install --id Microsoft.Azure.FunctionsCoreTools --exact --source winget --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) { throw 'WinGet could not install Azure Functions Core Tools v4.' }
            } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
                Write-Host 'Installing Azure Functions Core Tools v4 with Chocolatey.'
                & choco install azure-functions-core-tools-4 --yes
                if ($LASTEXITCODE -ne 0) { throw 'Chocolatey could not install Azure Functions Core Tools v4.' }
            } else {
                throw 'WinGet or Chocolatey is required to install Azure Functions Core Tools v4 automatically.'
            }
            $MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $env:Path = "$MachinePath$([IO.Path]::PathSeparator)$UserPath"
        } else {
            throw 'Azure Functions Core Tools v4 is missing. Automatic installation is supported by this script on macOS and Windows; install func v4 and rerun.'
        }
        if (-not (Get-Command func -ErrorAction SilentlyContinue)) { throw 'Azure Functions Core Tools v4 was installed but func is not on PATH; restart the shell and rerun.' }
    }
    Get-Command $Config.pythonExecutable -ErrorAction Stop | Out-Null
    & $Config.pythonExecutable -c 'import azure.identity, azure.monitor.ingestion, requests, redis' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing Python loader dependencies into $($Config.pythonExecutable)."
        & $Config.pythonExecutable -m pip install azure-identity azure-monitor-ingestion requests redis
        if ($LASTEXITCODE -ne 0) { throw 'pip could not install the Python loader dependencies.' }
    }
    & $Config.pythonExecutable -c 'import azure.identity, azure.monitor.ingestion, requests, redis' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Python loader dependencies are still unavailable in pythonExecutable after installation.' }
}
function Read-SetupValue([string]$Label, [string]$Default = '') {
    $Prompt = if ($Default) { "$Label [$Default]" } else { $Label }
    if ([Console]::IsInputRedirected) {
        [Console]::Error.Write("${Prompt}: ")
        $Answer = [Console]::ReadLine()
        if ($null -eq $Answer) { throw 'Input ended; rerun with -NonInteractive or provide all answers.' }
    } else {
        $Answer = Read-Host $Prompt
    }
    if (-not $Answer) { $Answer = $Default }
    if (-not $Answer) { throw "$Label is required." }
    return $Answer
}
function Read-SetupChoice([string]$Label, [string]$Default, [string[]]$Choices) {
    $Answer = Read-SetupValue "$Label ($($Choices -join '/'))" $Default
    if ($Answer -notin $Choices) { throw "Choose one of: $($Choices -join ', ')." }
    return $Answer
}
function Read-SetupModels {
    [Console]::Error.WriteLine('Available models: 1=claude-sonnet-5, 2=claude-haiku-4-5, 3=claude-opus-5')
    $Answer = Read-SetupValue 'Allowed models (comma-separated numbers)' '1,2,3'
    $Models = [System.Collections.Generic.List[string]]::new()
    foreach ($Selection in $Answer.Split(',')) {
        $Model = switch ($Selection.Trim()) {
            '1' { 'claude-sonnet-5' }
            '2' { 'claude-haiku-4-5' }
            '3' { 'claude-opus-5' }
            default { throw 'Choose one or more model numbers from: 1, 2, 3.' }
        }
        if (-not $Models.Contains($Model)) { $Models.Add($Model) }
    }
    if ($Models.Count -eq 0) { throw 'Choose at least one model.' }
    return $Models.ToArray()
}
function ConvertTo-TeamId([string]$Name) {
    return (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '^-+|-+$', '')
}
function Initialize-InteractiveConfig {
    $Config.resourceGroup = Read-SetupValue 'Gateway resource group name' $Config.resourceGroup
    $Config.foundryResourceGroup = Read-SetupValue 'Foundry resource group name' ($Config.foundryResourceGroup ?? $Config.resourceGroup)
    $Config.apimName = Read-SetupValue 'APIM name' $Config.apimName
    $Config.apimLocation = Read-SetupValue 'APIM location' 'centralus'
    $Config.budgetLocation = $Config.apimLocation
    $Config.cosmosLocation = $Config.apimLocation
    $Config.workspaceLocation = Read-SetupValue 'Workspace location' 'centralus'
    $Config.workbookLocation = Read-SetupValue 'Workbook location' 'centralus'
    $Config.publisherEmail = Read-SetupValue 'Publisher email' $Config.publisherEmail
    $GatewayDisplayName = if ($Config.gatewayDisplayName) { $Config.gatewayDisplayName } else { "Claude Gateway - $($Config.apimName)" }
    $Config.gatewayDisplayName = Read-SetupValue 'Enter a name for the gateway service principal' $GatewayDisplayName
    $Config.budgetApiAudience = ''
    $Config.workspaceResourceId = Read-SetupValue 'Log Analytics workspace resource ID' $Config.workspaceResourceId
    $Config.subscriptionId = $Config.workspaceResourceId.Split('/')[2]
    $Config.foundryAccountName = Read-SetupValue 'Foundry resource name' $Config.foundryAccountName
    $Config.namePrefix = Read-SetupValue 'Resource name prefix' $Config.namePrefix

    if ((Read-SetupChoice 'Configure team governance now?' 'yes' @('yes', 'no')) -eq 'yes') {
        $Profiles = @($Config.teamGovernance.profiles)
        $ActionGroupIds = @($Config.teamGovernance.actionGroupIds | Where-Object { $_ })
        $Mode = if ($Config.teamGovernance.mode -and $Config.teamGovernance.mode -ne 'off') { $Config.teamGovernance.mode } else { 'observe' }
        $Teams = @()
        do {
            $TeamName = Read-SetupValue 'Team name'
            $Emails = @((Read-SetupValue 'Team member email IDs (comma separated)').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $Profile = Read-SetupChoice 'Team profile' 'regular' @('regular', 'power')
            $Tier = Read-SetupChoice 'Default user tier' 'basic' @('pro', 'basic', 'lite')
            $TeamId = ConvertTo-TeamId $TeamName
            if ($TeamId.Length -lt 3) { throw 'Team name must produce an identifier of at least three letters or digits.' }
            $Role = Read-SetupValue 'Team role' "$TeamId.$Profile"
            $AllowedModels = @(Read-SetupModels)
            $Teams += @{ id = $TeamId; displayName = $TeamName; groupDisplayName = "Claude Team - $TeamName"; teamRoleValue = $Role; profile = $Profile; defaultUserTier = $Tier; allowedModels = $AllowedModels; members = $Emails }
            $More = Read-SetupChoice 'Add another team?' 'no' @('yes', 'no')
        } while ($More -eq 'yes')
        $Config.teamGovernance = @{ mode = $Mode; actionGroupIds = $ActionGroupIds; profiles = $Profiles; teams = $Teams }
    }
}
function Initialize-GatewayApplication {
    $Name = $Config.gatewayDisplayName
    $Applications = @(Invoke-Azure ad app list --display-name $Name -o json | ConvertFrom-Json -AsHashtable)
    if ($Applications.Count -gt 1) { throw "Multiple Entra applications are named '$Name'; choose a unique gateway service principal name." }
    if ($Applications.Count -eq 1) {
        $Application = $Applications[0]
    } else {
        $Application = Invoke-Azure ad app create --display-name $Name --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json -AsHashtable
    }
    $ClientId = $Application.appId
    $ObjectId = $Application.id
    $TokenResource = "api://$ClientId"
    $ApplicationJson = Invoke-Azure ad app show --id $ClientId -o json
    $Application = $ApplicationJson | ConvertFrom-Json -AsHashtable
    $Scope = @($Application.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access_as_user' })
    $Role = @($Application.appRoles | Where-Object { $_.value -eq 'Claude.User' })
    $ScopeId = if ($Scope.Count) { $Scope[0].id } else { [Guid]::NewGuid().ToString() }
    $RoleId = if ($Role.Count) { $Role[0].id } else { [Guid]::NewGuid().ToString() }
    $ApiPatch = $ApplicationJson | & jq -c --arg resource $TokenResource --arg scope $ScopeId --arg role $RoleId '
        .identifierUris = ((.identifierUris // []) + [$resource] | unique) |
        .api = ((.api // {}) + {requestedAccessTokenVersion: 2}) |
        .api.oauth2PermissionScopes = ((.api.oauth2PermissionScopes // []) |
                    if any(.[]; .value == "access_as_user") then map(if .value == "access_as_user" then . + {isEnabled:true} else . end) else . + [{id:$scope, value:"access_as_user", type:"User", isEnabled:true, adminConsentDisplayName:"Access Claude Gateway", adminConsentDescription:"Access the Claude gateway as the signed-in user", userConsentDisplayName:"Access Claude Gateway", userConsentDescription:"Access the Claude gateway as you"}] end) |
        .appRoles = ((.appRoles // []) |
                    if any(.[]; .value == "Claude.User") then map(if .value == "Claude.User" then . + {isEnabled:true, allowedMemberTypes:((.allowedMemberTypes // []) + ["User"] | unique)} else . end) else . + [{id:$role, value:"Claude.User", displayName:"Claude User", description:"Access to the Claude gateway", isEnabled:true, allowedMemberTypes:["User"]}] end) |
        {identifierUris, api, appRoles}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the gateway application configuration.' }
    Invoke-Azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$ObjectId" `
        --headers Content-Type=application/json --body $ApiPatch -o none | Out-Null
    $ServicePrincipals = @(Invoke-Azure ad sp list --filter "appId eq '$ClientId'" -o json | ConvertFrom-Json -AsHashtable)
    if ($ServicePrincipals.Count -eq 0) { Invoke-Azure ad sp create --id $ClientId -o none | Out-Null }
    $script:Config.gatewayAudience = $ClientId
    $script:Config.tokenResource = $TokenResource
    Write-Host "Gateway application and service principal: $Name ($ClientId)"
}
function Initialize-BudgetApiApplication {
    $ClientId = $Config.budgetApiAudience
    if ($ClientId) {
        Invoke-Azure ad sp show --id $ClientId -o none | Out-Null
        return $ClientId
    }
    $Name = "Claude Budget API - $($Config.namePrefix)"
    $Applications = @(Invoke-Azure ad app list --display-name $Name -o json | ConvertFrom-Json -AsHashtable)
    if ($Applications.Count -gt 1) { throw "Multiple Entra applications are named '$Name'; set budgetApiAudience explicitly." }
    if ($Applications.Count -eq 1) {
        $Application = $Applications[0]
    } else {
        $Application = Invoke-Azure ad app create --display-name $Name --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json -AsHashtable
    }
    $ClientId = $Application.appId
    $ServicePrincipals = @(Invoke-Azure ad sp list --filter "appId eq '$ClientId'" -o json | ConvertFrom-Json -AsHashtable)
    if ($ServicePrincipals.Count -eq 0) { Invoke-Azure ad sp create --id $ClientId -o none | Out-Null }
    $script:Config.budgetApiAudience = $ClientId
    Write-Host "Budget API application: $ClientId"
    return $ClientId
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
        foundryResourceGroup = $Config.foundryResourceGroup
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
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
if ($Interactive -and $NonInteractive) { throw 'Use either -Interactive or -NonInteractive, not both.' }
if ($Interactive -or (-not $NonInteractive -and -not [Console]::IsInputRedirected)) { Initialize-InteractiveConfig }
$IsInteractive = $Interactive -or (-not $NonInteractive -and -not [Console]::IsInputRedirected)
$ConfigToValidate = $Config
$UsesTemporaryGatewayIdentity = $false
if ($IsInteractive -and $Config.gatewayAudience -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
    $UsesTemporaryGatewayIdentity = $true
    $ConfigToValidate = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $ConfigToValidate.gatewayAudience = '00000000-0000-4000-8000-000000000001'
    $ConfigToValidate.tokenResource = 'api://00000000-0000-4000-8000-000000000001'
}
$ConfigJson = $ConfigToValidate | ConvertTo-Json -Depth 30 -Compress | & jq -e -f (Join-Path $PSScriptRoot 'validate-config.jq')
if ($LASTEXITCODE -ne 0) { throw 'Invalid admin config.' }
if (-not $UsesTemporaryGatewayIdentity) { $Config = $ConfigJson | ConvertFrom-Json -AsHashtable }
$WorkspaceGroup = $Config.workspaceResourceId.Split('/')[4]
$WorkspaceName = $Config.workspaceResourceId.Split('/')[-1]
$Output = $Config.onboardingOutput
if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $Root $Output }
Write-Host "Stage=$Stage; subscription=$($Config.subscriptionId); gateway resource group=$($Config.resourceGroup); Foundry resource group=$($Config.foundryResourceGroup); APIM=$($Config.apimName) ($($Config.apimLocation)); budget=$($Config.budgetLocation); Cosmos=$($Config.cosmosLocation)"
Write-Host 'Order: preflight -> bootstrap APIM only if absent -> tiers/DCR -> authenticated budget platform -> pricing permissions + both price stores -> publish Functions -> final APIM -> onboarding export -> optional smoke/reporting/reconciliation.'
Write-Host "Options: $($Config.options | ConvertTo-Json -Compress)"
Write-Host 'StandardV2 APIM, EP1, Redis, Cosmos, Event Hub and optional Grafana incur charges. Budget accounting is asynchronous, fail-open and excludes cache writes.'
if ($DryRun) { Write-Host 'DRY RUN: configuration validated. No writes, installs, logins, Azure calls or inference.'; return }
Get-Command az -ErrorAction Stop | Out-Null
$Account = Invoke-Azure account show --subscription $Config.subscriptionId -o json | ConvertFrom-Json -AsHashtable
if ($Account.tenantId -ne $Config.tenantId) { throw 'Wrong Azure tenant; log in to the configured tenant.' }
Invoke-Azure account set --subscription $Config.subscriptionId | Out-Null
if ($Stage -ne 'preflight' -and -not $Yes) { throw 'Review -DryRun, then pass -Yes to authorize the selected changes.' }
if ($IsInteractive) {
    Initialize-GatewayApplication
    $ConfigJson = $Config | ConvertTo-Json -Depth 30 -Compress | & jq -e -f (Join-Path $PSScriptRoot 'validate-config.jq')
    if ($LASTEXITCODE -ne 0) { throw 'The generated gateway application configuration is invalid.' }
    $Config = $ConfigJson | ConvertFrom-Json -AsHashtable
}
$Temp = Join-Path ([IO.Path]::GetTempPath()) "claude-admin-$([Guid]::NewGuid())"
[IO.Directory]::CreateDirectory($Temp) | Out-Null
$EffectiveConfigPath = Join-Path $Temp 'effective-config.json'
$Config | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8NoBOM $EffectiveConfigPath
try {
    if ($Stage -eq 'export') {
        $App = Invoke-Azure ad app show --id $Config.gatewayAudience -o json | ConvertFrom-Json -AsHashtable
        $Config.clientConfiguration.clientId = Initialize-ClaudeDesktopClient
        Export-Configuration
        return
    }
    if ($Stage -eq 'retention') { Set-Retention; return }
    if ($Stage -eq 'reporting') { Invoke-Reporting; return }
    Install-Prerequisites
    $Identity = & $Config.pythonExecutable -c 'import base64,json; from azure.identity import DefaultAzureCredential; token=DefaultAzureCredential().get_token("https://management.azure.com/.default").token.split(".")[1]; claims=json.loads(base64.urlsafe_b64decode(token+"="*(-len(token)%4))); print(json.dumps({"oid":claims["oid"],"tid":claims["tid"]}))'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check Python credential identity.' }
    $Identity = $Identity | ConvertFrom-Json -AsHashtable
    if ($Identity.tid -ne $Config.tenantId) { throw 'Python credential resolved to a different tenant than tenantId.' }
    if ($Config.pricingPublisherPrincipalId) {
        if ($Identity.oid -ne $Config.pricingPublisherPrincipalId) { throw 'Python credential identity does not match the configured pricingPublisherPrincipalId.' }
    } else {
        $PrincipalType = Invoke-Azure rest --method GET --url "https://graph.microsoft.com/v1.0/directoryObjects/$($Identity.oid)" --query '"@odata.type"' -o tsv
        $Config.pricingPublisherPrincipalType = switch ($PrincipalType) {
            '#microsoft.graph.user' { 'User' }
            '#microsoft.graph.servicePrincipal' { 'ServicePrincipal' }
            default { throw "Unable to determine pricing publisher principal type for $($Identity.oid) (got $PrincipalType)." }
        }
        $Config.pricingPublisherPrincipalId = $Identity.oid
        Write-Host "Pricing publisher principal auto-detected from the active Python credential: $($Identity.oid) ($($Config.pricingPublisherPrincipalType))"
    }
    Invoke-Azure group show --name $Config.resourceGroup -o none
    Invoke-Azure cognitiveservices account show --name $Config.foundryAccountName --resource-group $Config.foundryResourceGroup -o none
    if ((Invoke-Azure resource show --ids $Config.workspaceResourceId --query location -o tsv) -ne $Config.workspaceLocation) { throw 'workspaceLocation does not match the existing workspace.' }
    $Models = @(Invoke-Azure cognitiveservices account deployment list --name $Config.foundryAccountName --resource-group $Config.foundryResourceGroup -o json | ConvertFrom-Json -AsHashtable)
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
    if ($Config.budgetApiAudience) { Invoke-Azure ad sp show --id $Config.budgetApiAudience -o none }
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
    if ($Stage -eq 'preflight') { Write-Host 'Preflight passed; the gateway identity was ensured in interactive mode, and no Azure resource deployments were made.'; return }
    if (-not $Config.options.pricesReviewed) { throw 'Review PRICES in snippets/15-load-pricing.py against your agreement, then set options.pricesReviewed=true.' }
    if ($Config.options.registerProviders) {
        foreach ($Provider in @('Microsoft.ApiManagement', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.EventHub', 'Microsoft.Cache', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.Dashboard')) {
            Invoke-Azure provider register --namespace $Provider --wait -o none
        }
    }
    if ($Apim.Count -eq 0) {
        $BootstrapParameters = Get-GatewayParameters
        $BootstrapParameters.deployPolicy = $false
        Invoke-Deployment '04-apim-gateway' $Config.resourceGroup 'infra/04-apim-gateway.bicep' $BootstrapParameters | Out-Null
    }
    $Apim = Invoke-Azure apim show --name $Config.apimName --resource-group $Config.resourceGroup -o json | ConvertFrom-Json -AsHashtable
    $ApimClientId = Invoke-Azure ad sp show --id $Apim.identity.principalId --query appId -o tsv
    if (-not $ApimClientId) { throw 'APIM managed identity client ID not available yet; rerun after propagation.' }
    $Tiers = Invoke-Deployment '14-claude-tiers' $WorkspaceGroup 'infra/14-claude-tiers.bicep' @{
        workspaceName = $WorkspaceName; location = $Config.workspaceLocation; tiersConfig = $Config.tiersConfig
        pricingPublisherPrincipalId = $Config.pricingPublisherPrincipalId; pricingPublisherPrincipalType = $Config.pricingPublisherPrincipalType
    }
    $BudgetAudienceWasMissing = -not $Config.budgetApiAudience
    $BudgetParameters = @{
        namePrefix = $Config.namePrefix; location = $Config.budgetLocation; cosmosLocation = $Config.cosmosLocation
        logAnalyticsWorkspaceId = $Config.workspaceResourceId; tiersConfig = $Config.tiersConfig
        teamGovernanceConfig = ($Config.teamGovernance ?? @{ mode = 'off'; profiles = @(); teams = @() })
        budgetApiAudience = $Config.budgetApiAudience; apimIdentityClientId = $ApimClientId
        redisSku = $Config.redisSku; redisCapacity = $Config.redisCapacity; storageGovernanceTags = $Config.storageGovernanceTags
    }
    $Budget = Invoke-Deployment '16-budget-platform' $Config.resourceGroup 'infra/16-budget-platform.bicep' $BudgetParameters
    $BudgetApiAudience = Initialize-BudgetApiApplication
    if ($BudgetAudienceWasMissing) {
        $BudgetParameters.budgetApiAudience = $BudgetApiAudience
        $Budget = Invoke-Deployment '16-budget-platform' $Config.resourceGroup 'infra/16-budget-platform.bicep' $BudgetParameters
    }
    $Config | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8NoBOM $EffectiveConfigPath
    Invoke-Deployment 'pricing-access' $Config.resourceGroup 'admin/pricing-access.bicep' @{
        redisName = $Budget.redisHost.value.Split('.')[0]; pricingPublisherPrincipalId = $Config.pricingPublisherPrincipalId
        pricingPublisherPrincipalType = $Config.pricingPublisherPrincipalType; foundryAccountName = $Config.foundryAccountName
        foundryResourceGroup = $Config.foundryResourceGroup
        enableReconciler = $Config.options.reconcile; cosmosAccountName = $Budget.cosmosAccountName.value
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
    if ($Config.teamGovernance -and $Config.teamGovernance.mode -ne 'off') {
        & (Join-Path $PSScriptRoot 'setup-teams-governance-claude-gateway.ps1') -ConfigPath $EffectiveConfigPath -Yes -SkipInfrastructure
        if ($LASTEXITCODE -ne 0) { throw 'Entra team governance provisioning failed.' }
    }
    $GovernanceParameters = @{
        apimName = $Config.apimName; logAnalyticsWorkspaceId = $Config.workspaceResourceId
        logAnalyticsWorkspaceName = $WorkspaceName; workbookLocation = $Config.workbookLocation
        teamGovernanceMode = ($Config.teamGovernance.mode ?? 'off')
    }
    if ($Config.teamGovernance) {
        $GovernanceParameters.profiles = $Config.teamGovernance.profiles
        $GovernanceParameters.teams = $Config.teamGovernance.teams
        $GovernanceParameters.actionGroupIds = @($Config.teamGovernance.actionGroupIds)
    }
    $Governance = Invoke-Deployment '22-team-governance' $Config.resourceGroup 'infra/22-team-governance.bicep' $GovernanceParameters
    if ($Governance.teamGovernanceModeNamedValue.value -ne 'team-governance-mode' -or
        $Governance.teamsJsonNamedValue.value -ne 'team-governance-teams-json' -or
        $Governance.profilesJsonNamedValue.value -ne 'team-governance-profiles-json' -or
        -not $Governance.workbookId.value -or $Governance.claudeTeamsFunctionName.value -ne 'ClaudeTeams' -or
        $Governance.alertsCreated.value -isnot [bool]) {
        throw 'Team governance deployment outputs are incomplete; final APIM policy was not deployed.'
    }
    $Parameters = Get-GatewayParameters
    $Parameters.eventHubAuthorizationRuleId = $Budget.eventHubAuthorizationRuleId.value
    $Parameters.eventHubName = $Budget.eventHubName.value
    $Parameters.budgetApiBaseUrl = $Budget.budgetApiBaseUrl.value
    $Parameters.budgetApiAudience = $BudgetApiAudience
    $Parameters.deployPolicy = $true
    Invoke-Deployment '04-apim-gateway' $Config.resourceGroup 'infra/04-apim-gateway.bicep' $Parameters | Out-Null
    Export-Configuration
    if ($Config.options.smokeTest) { & (Join-Path $Root 'developer/setup-claude-workstation.ps1') -ConfigPath $Output -TestOnly }
    Invoke-Reporting
    if ($Config.options.reconcile) {
        & $Config.pythonExecutable (Join-Path $Root 'snippets/20-cost-reconciler.py') `
            --resource-id "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.foundryResourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($Config.foundryAccountName)" `
            --hours $Config.reconcileHours --dcr-endpoint $Tiers.pricingDcrEndpoint.value --dcr-immutable-id $Tiers.pricingDcrImmutableId.value `
            --cosmos-endpoint $Budget.cosmosEndpoint.value --cosmos-database $Budget.cosmosDatabaseName.value `
            --cosmos-container $Budget.cosmosContainerName.value --redis-host $Budget.redisHost.value `
            --tiers-json ($Config.tiersConfig | ConvertTo-Json -Depth 20 -Compress) `
            --team-governance-json (($Config.teamGovernance ?? @{ mode = 'off'; profiles = @(); teams = @() }) | ConvertTo-Json -Depth 20 -Compress)
        if ($LASTEXITCODE -ne 0) { throw 'Cost reconciliation failed.' }
    }
    Write-Host 'Selected steps completed. Runtime budget enforcement still requires traffic, telemetry delivery and per-tier verification; deployment success alone is not proof.'
} finally { Remove-Item -LiteralPath $Temp -Recurse -Force }