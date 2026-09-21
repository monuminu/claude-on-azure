#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroup,
    [string]$ClientId,
    [string]$Scopes,
    [string]$OpusModel,
    [string]$SonnetModel,
    [string]$HaikuModel,
    [string]$DeploymentName = '04-apim-gateway',
    [string]$DeploymentFile,
    [string]$TokenResource,
    [string]$ClientSettings,
    [string]$Output = './claude-client-configuration.json',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$Deployment = $null
$App = $null
$Settings = '{}'
$Config = $null
$DeployedTenant = ''

function Read-Value([string]$Label, [string]$Default = '') {
    $Prompt = if ($Default) { "$Label [$Default]" } else { $Label }
    if ([Console]::IsInputRedirected) {
        [Console]::Error.Write("${Prompt}: ")
        $Answer = [Console]::ReadLine()
        if ($null -eq $Answer) { throw 'Input ended; supply explicit arguments for unattended export.' }
    } else {
        $Answer = Read-Host $Prompt
    }
    if (-not $Answer) { $Answer = $Default }
    if (-not $Answer) { throw "$Label is required." }
    return $Answer
}
Get-Command jq -ErrorAction Stop | Out-Null
if ((Test-Path $Output) -and -not $Force) { throw 'Output exists; use -Force to replace it.' }
if ($DeploymentFile) {
    $Deployment = Get-Content -Raw $DeploymentFile | ConvertFrom-Json -AsHashtable
} else {
    if (-not $SubscriptionId -or -not $ResourceGroup) { throw 'Supply -SubscriptionId and -ResourceGroup, or -DeploymentFile.' }
    $Deployment = & az deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $DeploymentName --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read gateway deployment.' }
    $Deployment = $Deployment | ConvertFrom-Json -AsHashtable
}
if ($Deployment.properties.provisioningState -ne 'Succeeded' -or -not $Deployment.properties.outputs.gatewayBaseUrl.value) { throw 'Missing gateway URL or unsuccessful deployment.' }
$DeployedTenant = $Deployment.properties.parameters.entraTenantId.value
if ($TenantId -and $DeployedTenant -and $TenantId -ne $DeployedTenant) { throw 'Tenant differs from deployed gateway tenant.' }
if (-not $TenantId) { $TenantId = $DeployedTenant }
if (-not $TenantId -and -not $DeploymentFile) {
    $TenantId = & az account show --subscription $SubscriptionId --query tenantId --only-show-errors -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve tenant.' }
}
if (-not $TenantId) { throw 'Offline export needs -TenantId or a deployed entraTenantId parameter.' }
if (-not $Scopes -and -not $DeploymentFile) {
    $App = & az ad app show --id $Deployment.properties.parameters.gatewayAudience.value --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read API scopes; supply -Scopes explicitly.' }
    $App = $App | ConvertFrom-Json -AsHashtable
    if (-not $TokenResource) {
        $DefaultResource = "api://$($Deployment.properties.parameters.gatewayAudience.value)"
        if ($DefaultResource -in $App.identifierUris) { $TokenResource = $DefaultResource }
        elseif ($App.identifierUris.Count -eq 1) { $TokenResource = $App.identifierUris[0] }
        else { throw 'Supply -TokenResource for ambiguous identifier URIs.' }
    }
    $EnabledScopes = @($App.api.oauth2PermissionScopes | Where-Object { $_.isEnabled } | ForEach-Object { $_.value })
    if ('access_as_user' -in $EnabledScopes) { $Scopes = "openid profile $TokenResource/access_as_user" }
    elseif ($EnabledScopes.Count -eq 1) { $Scopes = "openid profile $TokenResource/$($EnabledScopes[0])" }
}
if (-not $ClientId) { $ClientId = Read-Value 'Desktop OIDC client ID (public-client registration)' }
if (-not $Scopes) { $Scopes = Read-Value 'Scopes (space-separated; include the registered gateway API scope)' }
if (-not $OpusModel) { $OpusModel = Read-Value 'Opus model deployment name' 'claude-opus-5' }
if (-not $SonnetModel) { $SonnetModel = Read-Value 'Sonnet model deployment name' 'claude-sonnet-5' }
if (-not $HaikuModel) { $HaikuModel = Read-Value 'Haiku model deployment name' 'claude-haiku-5-4' }
if ($ClientSettings) { $Settings = Get-Content -Raw $ClientSettings }
$Config = & jq -n --arg url $Deployment.properties.outputs.gatewayBaseUrl.value --arg tenant $TenantId --arg client $ClientId --arg scopes $Scopes `
    --arg opus $OpusModel --arg sonnet $SonnetModel --arg haiku $HaikuModel --argjson settings $Settings -f (Join-Path $PSScriptRoot 'client-configuration.jq')
if ($LASTEXITCODE -ne 0) { throw 'Invalid client configuration.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Output))) | Out-Null
$Config | Set-Content -Encoding utf8NoBOM $Output
Write-Host "Created $Output (client settings only; no credentials). Model defaults are not proof of deployment availability."