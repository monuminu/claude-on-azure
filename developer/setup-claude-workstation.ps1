#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$ClaudeDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),
    [switch]$DryRun,
    [switch]$InstallClaude,
    [switch]$InstallVSCode,
    [switch]$Login,
    [switch]$SmokeTest,
    [switch]$TestOnly
)
$ErrorActionPreference = 'Stop'
$ClaudeDir = [IO.Path]::GetFullPath($ClaudeDir)
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$HelperDir = Join-Path $ClaudeDir 'gateway'
$HelperPath = Join-Path $HelperDir 'claude-gateway-token.ps1'
$Settings = @{}
$Token = ''
$Body = ''
$Response = $null
$Backup = "$SettingsPath.backup.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).$PID"
$Temp = "$SettingsPath.$PID.tmp"
$GuidPattern = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
$TenantId = ''
$TokenResources = @()
$TokenResource = ''
$TokenScope = ''
$Conflicts = @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_RESOURCE', 'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_FOUNDRY_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')

if ($Config.provider -ne 'gateway' -or $Config.credentialKind -ne 'interactive_sign_in' -or $Config.gatewaySso.clientId -notmatch $GuidPattern -or
    $Config.gatewaySso.issuerUrl -notmatch '^https://login.microsoftonline.com/[0-9a-fA-F-]+/v2.0$' -or
    $Config.gatewaySso.scopes -isnot [string] -or $Config.gatewaySso.scopes -match '[\r\n]' -or
    $Config.gatewayUrl -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/anthropic$' -or
    $Config.models.opus -isnot [string] -or -not $Config.models.opus -or
    $Config.models.sonnet -isnot [string] -or -not $Config.models.sonnet -or
    $Config.models.haiku -isnot [string] -or -not $Config.models.haiku) { throw 'Invalid claude-client-configuration.json; obtain a fresh export from your administrator.' }
$TenantId = $Config.gatewaySso.issuerUrl.Split('/')[3]
$TokenResources = @($Config.gatewaySso.scopes.Split(' ') | Where-Object { $_ -match '^(api://|https://)' } | ForEach-Object { $_ -replace '/[^/]+$', '' } | Sort-Object -Unique)
if ($TenantId -notmatch $GuidPattern -or $TokenResources.Count -ne 1 -or $TokenResources[0] -notmatch '^(api://|https://)[A-Za-z0-9./:_-]+$' -or
    $TokenResources[0] -eq "api://$($Config.gatewaySso.clientId)") { throw 'Invalid issuer tenant or gateway API scopes.' }
$TokenResource = $TokenResources[0]
$TokenScope = @($Config.gatewaySso.scopes.Split(' ') | Where-Object { $_ -match '^(api://|https://)' })[0]
if (Test-Path $SettingsPath) { $Settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json -AsHashtable }
if ($Settings -isnot [System.Collections.IDictionary]) { throw 'Invalid existing Claude settings.' }
if (-not $Settings.env) { $Settings.env = @{} }
if ($Settings.env -isnot [System.Collections.IDictionary]) { throw 'Invalid existing Claude env settings.' }
foreach ($Name in $Conflicts) { $Settings.env.Remove($Name) }
$Settings.Remove('forceLoginMethod')
$Settings.Remove('forceLoginOrgUUID')
$Settings.env.ANTHROPIC_BASE_URL = $Config.gatewayUrl
$Settings.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = '2700000'
$Settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL = $Config.models.opus
$Settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL = $Config.models.sonnet
$Settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $Config.models.haiku
$Settings.apiKeyHelper = 'pwsh -NoProfile -File "' + $HelperPath + '"'
Write-Host "Gateway: $($Config.gatewayUrl)`nSettings: $SettingsPath"
if ($DryRun) {
    Write-Host "DRY RUN: validate config, merge settings, create token helper. Install Claude=$InstallClaude; VS Code=$InstallVSCode; login=$Login; smoke=$($SmokeTest -or $TestOnly); test-only=$TestOnly. No writes or network calls."
    return
}
foreach ($Name in $Conflicts) {
    if ([Environment]::GetEnvironmentVariable($Name)) { throw "Unset inherited $Name before setup; it can override gateway settings." }
}
Get-Command az -ErrorAction Stop | Out-Null
if ($Login) {
    & az login --tenant $TenantId --scope $TokenScope --allow-no-subscriptions --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'Azure login failed.' }
}
$Token = & az account get-access-token --tenant $TenantId --resource $TokenResource --query accessToken --only-show-errors -o tsv
if ($LASTEXITCODE -ne 0 -or -not $Token) { throw 'No token. Run again with -Login.' }
if (-not $TestOnly) {
    if ($InstallClaude) {
        & npm install -g '@anthropic-ai/claude-code'
        if ($LASTEXITCODE -ne 0) { throw 'Claude Code installation failed.' }
    }
    if ($InstallVSCode) {
        & code --install-extension anthropic.claude-code
        if ($LASTEXITCODE -ne 0) { throw 'VS Code extension installation failed.' }
    }
    Get-Command claude -ErrorAction Stop | Out-Null
    [IO.Directory]::CreateDirectory($HelperDir) | Out-Null
    if (Test-Path $SettingsPath) { Copy-Item $SettingsPath $Backup }
    $Config | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8NoBOM (Join-Path $HelperDir 'claude-client-configuration.json')
    @'
#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$Config = Get-Content -Raw (Join-Path $PSScriptRoot 'claude-client-configuration.json') | ConvertFrom-Json
$TenantId = $Config.gatewaySso.issuerUrl.Split('/')[3]
$TokenResources = @($Config.gatewaySso.scopes.Split(' ') | Where-Object { $_ -match '^(api://|https://)' } | ForEach-Object { $_ -replace '/[^/]+$', '' } | Sort-Object -Unique)
if ($TokenResources.Count -ne 1) { throw 'Expected one gateway API resource in scopes.' }
$Token = & az account get-access-token --tenant $TenantId --resource $TokenResources[0] --query accessToken --only-show-errors -o tsv
if ($LASTEXITCODE -ne 0 -or -not $Token) { Write-Error 'No token; run az login for your gateway tenant.'; exit 1 }
[Console]::Out.WriteLine($Token)
'@ | Set-Content -Encoding utf8NoBOM $HelperPath
    try {
        $Settings | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $Temp
        Move-Item -Force $Temp $SettingsPath
    } finally {
        if (Test-Path $Temp) { Remove-Item $Temp }
    }
    Write-Host "Configured Claude Code. Existing settings backup (when present): $Backup"
}
if ($SmokeTest -or $TestOnly) {
    $Body = @{ model = $Config.models.sonnet; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Reply with READY' }) } | ConvertTo-Json -Depth 10
    $Response = Invoke-WebRequest -Uri "$($Config.gatewayUrl)/v1/messages" -Method Post -ContentType 'application/json' -Headers @{ 'anthropic-version' = '2023-06-01' } -Body $Body -TimeoutSec 90 -SkipHttpErrorCheck
    if ($Response.StatusCode -ne 401) { throw "Unauthenticated request: expected 401, got $($Response.StatusCode)." }
    $Response = Invoke-WebRequest -Uri "$($Config.gatewayUrl)/v1/messages" -Method Post -ContentType 'application/json' -Headers @{ 'anthropic-version' = '2023-06-01'; 'x-api-key' = $Token; Authorization = 'Bearer dummy' } -Body $Body -TimeoutSec 90 -SkipHttpErrorCheck
    if ($Response.StatusCode -ne 200) { throw "Authenticated request: expected 200, got $($Response.StatusCode). Check role assignment, model, quota and backend." }
    Write-Host 'Smoke tests passed: unauthenticated 401; authenticated inference 200.'
}
$Token = $null
Write-Host 'Restart Claude Code / reload VS Code. Organization-managed settings and project settings can override user settings.'