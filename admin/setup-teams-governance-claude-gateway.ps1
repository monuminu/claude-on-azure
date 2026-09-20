#requires -Version 7.2
<#
.SYNOPSIS
Provisions Entra ID security groups, gateway app roles and group-to-app-role assignments
described by the "teamGovernance" block of an admin config (see admin/setup.example.json).

.DESCRIPTION
Safety posture (mirrors admin/claude-gateway-setup.ps1):
  -DryRun  Fully offline. Validates the config and prints the plan. No az/Graph calls.
  -Check   Read-only reconciliation against real Entra ID. Never creates or changes
           anything. Exits non-zero if drift is found. Does not require -Yes.
  -Yes     Required to authorize any create/update/add. Group deletions and member
           removals are NEVER performed by this script (additive/no-destructive-default).

This script is a genuine expansion of scope beyond admin/claude-gateway-setup.ps1, which
deliberately never touches Entra groups, app roles or role assignments (see admin/README.md).
Review a -DryRun and/or -Check run before authorizing changes with -Yes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$SkipInfrastructure,
    [string]$ManifestOutput
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Drift = $false

function Invoke-Azure {
    $Result = & az @args --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($args -join ' ')" }
    return $Result
}

function New-GuidString { return [Guid]::NewGuid().ToString() }

function ConvertTo-ODataLiteral([string]$Value) { return $Value.Replace("'", "''") }

function Invoke-GovernanceDeployment {
    $Parameters = @{
        apimName = $Config.apimName
        logAnalyticsWorkspaceId = $Config.workspaceResourceId
        logAnalyticsWorkspaceName = $Config.workspaceResourceId.Split('/')[-1]
        workbookLocation = $Config.workbookLocation
        teamGovernanceMode = $Mode
        actionGroupIds = @($Config.teamGovernance.actionGroupIds)
    }
    if ($Config.teamGovernance) {
        $Parameters.profiles = $Config.teamGovernance.profiles
        $Parameters.teams = $Config.teamGovernance.teams
    }
    $ParameterFile = [IO.Path]::GetTempFileName()
    try {
        $ParameterValues = @{}
        foreach ($Entry in $Parameters.GetEnumerator()) { $ParameterValues[$Entry.Key] = @{ value = $Entry.Value } }
        $ParameterValues | ConvertTo-Json -Depth 30 | Set-Content -Path $ParameterFile -Encoding utf8NoBOM
        $Deployment = Invoke-Azure deployment group create --subscription $Config.subscriptionId --name '22-team-governance' `
            --resource-group $Config.resourceGroup --template-file (Join-Path $Root 'infra/22-team-governance.bicep') `
            --parameters "@$ParameterFile" -o json | ConvertFrom-Json -AsHashtable
    } finally {
        Remove-Item $ParameterFile -Force -ErrorAction SilentlyContinue
    }
    $Outputs = $Deployment.properties.outputs
    if ($Outputs.teamGovernanceModeNamedValue.value -ne 'team-governance-mode' -or
        $Outputs.teamsJsonNamedValue.value -ne 'team-governance-teams-json' -or
        $Outputs.profilesJsonNamedValue.value -ne 'team-governance-profiles-json' -or
        -not $Outputs.workbookId.value -or $Outputs.claudeTeamsFunctionName.value -ne 'ClaudeTeams' -or
        $Outputs.alertsCreated.value -isnot [bool]) {
        throw 'Team governance deployment outputs are incomplete.'
    }
    Write-Host 'Deployed team governance infrastructure and workbook (modules 22 and 23).'
}

$ConfigJson = & jq -ef (Join-Path $Root 'admin/validate-config.jq') $ConfigPath
if ($LASTEXITCODE -ne 0) { throw 'Invalid admin config.' }
$Config = $ConfigJson | ConvertFrom-Json -AsHashtable

$Mode = $Config.teamGovernance.mode
if (-not $Mode) { $Mode = 'off' }

$TeamsConfig = @($Config.teamGovernance.teams)
$ProfilesConfig = @($Config.teamGovernance.profiles)
Write-Host "teamGovernance.mode=$Mode; teams=$($TeamsConfig.Count); profiles=$($ProfilesConfig.Count)"
foreach ($Team in $TeamsConfig) {
    Write-Host "  - $($Team.id): $($Team.displayName) -> group `"$($Team.groupDisplayName)`", role $($Team.teamRoleValue), profile $($Team.profile), $($Team.members.Count) member(s)"
}

if ($DryRun) {
    Write-Host 'DRY RUN: configuration validated offline. No writes, logins, Graph or Azure calls made.'
    return
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
$Account = Invoke-Azure account show --subscription $Config.subscriptionId -o json | ConvertFrom-Json -AsHashtable
if ($Account.tenantId -ne $Config.tenantId) { throw 'Wrong Azure tenant; log in to the configured tenant.' }

if (-not $Check -and -not $Yes) {
    throw 'Review -DryRun/-Check, then pass -Yes to authorize Azure and Entra changes.'
}

if ($Check) {
    Write-Host 'CHECK: module 22 deployment skipped because check mode is read-only.'
} elseif (-not $SkipInfrastructure) {
    Invoke-GovernanceDeployment
}

if ($Mode -eq 'off') {
    Write-Host 'teamGovernance.mode is off; infrastructure is configured but Entra reconciliation is disabled.'
    return
}

$App = Invoke-Azure ad app show --id $Config.gatewayAudience -o json | ConvertFrom-Json -AsHashtable
$GatewaySpId = Invoke-Azure ad sp show --id $Config.gatewayAudience --query id -o tsv

# --- Ensure gateway app roles (idempotent merge; never removes or disables unrelated roles) ---
$DesiredRoles = [System.Collections.Generic.List[hashtable]]::new()
$DesiredRoles.Add(@{ value = 'Claude.User'; displayName = 'Claude User'; description = 'Access to the Claude gateway' })
foreach ($Team in $Config.teamGovernance.teams) {
    $TierName = $Team.defaultUserTier.Substring(0, 1).ToUpperInvariant() + $Team.defaultUserTier.Substring(1)
    $DesiredRoles.Add(@{ value = "Claude.Tier.$TierName"; displayName = "Individual tier - $($Team.defaultUserTier)"; description = "Claude individual budget tier: $($Team.defaultUserTier)" })
    $DesiredRoles.Add(@{ value = $Team.teamRoleValue; displayName = "Team - $($Team.displayName)"; description = "Claude team membership: $($Team.displayName)" })
}
foreach ($Profile in $Config.teamGovernance.profiles) {
    $DesiredRoles.Add(@{ value = $Profile.roleValue; displayName = "Team profile - $($Profile.name)"; description = "Claude team budget profile: $($Profile.name)" })
}
$DesiredRoles = @($DesiredRoles | Sort-Object -Property value -Unique)

$ExistingRoles = @($App.appRoles)
$HaveByValue = @{}
foreach ($Role in $ExistingRoles) { $HaveByValue[$Role.value] = $Role }

$Resolved = [System.Collections.Generic.List[hashtable]]::new()
$MissingRoles = [System.Collections.Generic.List[string]]::new()
foreach ($Desired in $DesiredRoles) {
    $Existing = $HaveByValue[$Desired.value]
    if ($Existing) {
        if ($Existing.isEnabled -ne $true) { $MissingRoles.Add($Desired.value) }
        $Resolved.Add(@{ id = $Existing.id; value = $Existing.value; displayName = $Existing.displayName; description = $Existing.description; isEnabled = $true; allowedMemberTypes = $Existing.allowedMemberTypes })
    } else {
        $MissingRoles.Add($Desired.value)
        $Resolved.Add(@{ id = (New-GuidString); value = $Desired.value; displayName = $Desired.displayName; description = $Desired.description; isEnabled = $true; allowedMemberTypes = @('User') })
    }
}
$DesiredValues = @($DesiredRoles | ForEach-Object { $_.value })
$Untouched = @($ExistingRoles | Where-Object { $DesiredValues -notcontains $_.value })
$RoleIdByValue = @{}
foreach ($Role in $Resolved) { $RoleIdByValue[$Role.value] = $Role.id }

if ($MissingRoles.Count -gt 0) {
    if ($Check) {
        $Drift = $true
        Write-Host "DRIFT: missing or disabled gateway app roles: $($MissingRoles -join ', ')"
    } else {
        $Body = @{ appRoles = @($Untouched + $Resolved) } | ConvertTo-Json -Depth 30 -Compress
        Invoke-Azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$($App.id)" --headers 'Content-Type=application/json' --body $Body -o none | Out-Null
        Write-Host "Ensured gateway app roles: $($MissingRoles -join ', ')"
    }
}

# --- Per-team groups, membership and role assignments ---
$Teams = [System.Collections.Generic.List[hashtable]]::new()
foreach ($Team in $Config.teamGovernance.teams) {
    $ProfileMatch = @($Config.teamGovernance.profiles | Where-Object { $_.name -eq $Team.profile })[0]
    $TierName = $Team.defaultUserTier.Substring(0, 1).ToUpperInvariant() + $Team.defaultUserTier.Substring(1)
    $TierRoleValue = "Claude.Tier.$TierName"

    $Filter = "displayName eq '$(ConvertTo-ODataLiteral $Team.groupDisplayName)'"
    $Groups = @(Invoke-Azure ad group list --filter $Filter -o json | ConvertFrom-Json -AsHashtable)
    if ($Groups.Count -gt 1) { throw "Multiple Entra groups are named '$($Team.groupDisplayName)'; resolve manually before rerunning." }

    $GroupStatus = ''
    $Group = $null
    if ($Groups.Count -eq 1) {
        $Group = $Groups[0]
        $GroupStatus = 'existing'
    } elseif ($Check) {
        $GroupStatus = 'missing'
        $Drift = $true
    } else {
        $MailNickname = ($Team.id -replace '[^A-Za-z0-9]', '-')
        $Group = Invoke-Azure ad group create --display-name $Team.groupDisplayName --mail-nickname $MailNickname `
            --description "Claude team governance ($($Team.id)); managed by setup-teams-governance-claude-gateway, do not edit membership manually." -o json |
            ConvertFrom-Json -AsHashtable
        $GroupStatus = 'created'
    }
    $GroupId = if ($Group) { $Group.id } else { $null }

    $MissingUsers = [System.Collections.Generic.List[string]]::new()
    $ResolvedMembers = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($Upn in $Team.members) {
        $UserJson = & az ad user show --id $Upn --only-show-errors -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $UserJson) {
            $MissingUsers.Add($Upn)
        } else {
            $User = $UserJson | ConvertFrom-Json -AsHashtable
            $ResolvedMembers.Add(@{ upn = $Upn; objectId = $User.id })
        }
    }
    if ($MissingUsers.Count -gt 0) {
        if ($Check) {
            $Drift = $true
        } else {
            throw "Missing Entra users for team $($Team.id): $($MissingUsers -join ', ')"
        }
    }

    $CurrentMembers = [System.Collections.Generic.List[hashtable]]::new()
    $AddedMembers = [System.Collections.Generic.List[hashtable]]::new()
    $ExtraMembers = [System.Collections.Generic.List[hashtable]]::new()
    if ($GroupId) {
        $CurrentRaw = @(Invoke-Azure ad group member list --group $GroupId -o json | ConvertFrom-Json -AsHashtable)
        foreach ($Member in $CurrentRaw) {
            $Upn = if ($Member.userPrincipalName) { $Member.userPrincipalName } else { $Member.displayName }
            $CurrentMembers.Add(@{ upn = $Upn; objectId = $Member.id })
        }
        $CurrentIds = @($CurrentMembers | ForEach-Object { $_.objectId })
        foreach ($Member in $ResolvedMembers) {
            if ($CurrentIds -contains $Member.objectId) { continue }
            if ($Check) {
                $Drift = $true
            } else {
                Invoke-Azure ad group member add --group $GroupId --member-id $Member.objectId | Out-Null
            }
            $AddedMembers.Add($Member)
        }
        $ResolvedIds = @($ResolvedMembers | ForEach-Object { $_.objectId })
        foreach ($Member in $CurrentMembers) {
            if ($ResolvedIds -notcontains $Member.objectId) { $ExtraMembers.Add($Member) }
        }
        if ($ExtraMembers.Count -gt 0) { $Drift = $true }
    }

    $RoleAssignments = [System.Collections.Generic.List[hashtable]]::new()
    if ($GroupId) {
        $Assigned = Invoke-Azure rest --method GET --url "https://graph.microsoft.com/v1.0/groups/$GroupId/appRoleAssignments" -o json | ConvertFrom-Json -AsHashtable
        $AssignedValues = @($Assigned.value)
        foreach ($RoleValue in @('Claude.User', $Team.teamRoleValue, $ProfileMatch.roleValue, $TierRoleValue)) {
            $RoleId = $RoleIdByValue[$RoleValue]
            if (-not $RoleId) { throw "App role $RoleValue was not resolved; rerun after roles are ensured." }
            $HasRole = @($AssignedValues | Where-Object { $_.appRoleId -eq $RoleId -and $_.resourceId -eq $GatewaySpId }).Count -gt 0
            if ($HasRole) {
                $RoleAssignments.Add(@{ role = $RoleValue; status = 'existing' })
            } elseif ($Check) {
                $Drift = $true
                $RoleAssignments.Add(@{ role = $RoleValue; status = 'missing' })
            } else {
                $Body = @{ principalId = $GroupId; resourceId = $GatewaySpId; appRoleId = $RoleId } | ConvertTo-Json -Compress
                Invoke-Azure rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GatewaySpId/appRoleAssignedTo" --headers 'Content-Type=application/json' --body $Body -o none | Out-Null
                $RoleAssignments.Add(@{ role = $RoleValue; status = 'assigned' })
            }
        }
    }

    $Teams.Add(@{
        id = $Team.id
        displayName = $Team.displayName
        groupDisplayName = $Team.groupDisplayName
        groupStatus = $GroupStatus
        groupObjectId = $GroupId
        missingUsers = @($MissingUsers)
        members = @($ResolvedMembers)
        addedMembers = @($AddedMembers)
        currentMembers = @($CurrentMembers)
        extraMembers = @($ExtraMembers)
        roleAssignments = @($RoleAssignments)
    })
}

$MemberCounts = @{}
foreach ($Team in $Teams) {
    foreach ($Member in @($Team.members)) {
        $Upn = $Member.upn
        if ($MemberCounts.ContainsKey($Upn)) { $MemberCounts[$Upn] += 1 } else { $MemberCounts[$Upn] = 1 }
    }
}
$Ambiguous = @($MemberCounts.Keys | Where-Object { $MemberCounts[$_] -gt 1 })
if ($Ambiguous.Count -gt 0) { $Drift = $true }

$Manifest = @{
    mode = $Mode
    checkMode = [bool]$Check
    gatewayApplicationObjectId = $App.id
    gatewayServicePrincipalId = $GatewaySpId
    missingOrDisabledAppRoles = @($MissingRoles)
    teams = @($Teams)
    ambiguousMembers = $Ambiguous
}
$ManifestJson = $Manifest | ConvertTo-Json -Depth 30
Write-Output $ManifestJson
if ($ManifestOutput) { Set-Content -Path $ManifestOutput -Value $ManifestJson -Encoding utf8NoBOM }

if ($Check -and $Drift) {
    Write-Error 'Reconciliation found drift; rerun without -Check (with -Yes) to converge, or review the manifest above.'
    exit 1
}
Write-Host 'Team governance reconciliation complete. Group deletions and member removals are never automatic.'
