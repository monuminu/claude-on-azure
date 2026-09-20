#!/usr/bin/env bash
# Provisions Entra ID security groups, gateway app roles and group-to-app-role assignments
# described by the "teamGovernance" block of an admin config (see admin/setup.example.json).
#
# Safety posture (mirrors admin/claude-gateway-setup.sh):
#   --dry-run  Fully offline. Validates the config and prints the plan. No az/Graph calls.
#   --check    Read-only reconciliation against real Entra ID. Never creates or changes
#              anything. Exits non-zero if drift is found. Does not require --yes.
#   --yes      Required to authorize any create/update/add. Group deletions and member
#              removals are NEVER performed by this script (additive/no-destructive-default).
#
# This script is a genuine expansion of scope beyond admin/claude-gateway-setup.sh, which
# deliberately never touches Entra groups, app roles or role assignments (see admin/README.md).
# Review a --dry-run and/or --check run before authorizing changes with --yes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CONFIG_PATH=''
DRY_RUN=false
CHECK=false
YES=false
SKIP_INFRASTRUCTURE=false
MANIFEST_OUTPUT=''
CONFIG=''
SUBSCRIPTION_ID=''
TENANT_ID=''
GATEWAY_AUDIENCE=''
MODE=''
TEMP=''
APP=''
GATEWAY_SP_ID=''
MISSING_ROLES='[]'
ROLE_ID_BY_VALUE='{}'
DRIFT=false

usage() {
  cat <<'EOF'
Usage: setup-teams-governance-claude-gateway.sh --config FILE [--check] [--dry-run] [--yes] [--manifest-output FILE]

Provisions the Entra ID security groups, gateway application roles and group-to-app-role
assignments described by the config's "teamGovernance" block. Idempotent and additive:
existing group members, app roles and role assignments are never removed or disabled.

  --config FILE           Admin config JSON (validated with admin/validate-config.jq).
  --dry-run               Validate the config and print the plan only. No Azure/Graph calls.
  --check                 Read-only reconciliation: report drift, make no changes. No --yes needed.
  --yes                   Required (unless --check) to authorize creating/updating Entra objects.
  --manifest-output FILE  Also write the resulting JSON manifest to FILE.
  --skip-infrastructure   Skip module 22 deployment (for the full gateway orchestrator only).
  -h, --help              Show this help.
EOF
}

value() { jq -er "$1" <<< "$CONFIG"; }
azure() { az "$@" --only-show-errors; }
new_guid() { command -v uuidgen >/dev/null 2>&1 && uuidgen | tr 'A-Z' 'a-z' || python3 -c 'import uuid; print(uuid.uuid4())'; }
odata_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --config) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; CONFIG_PATH=$2; shift 2 ;;
    --manifest-output) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; MANIFEST_OUTPUT=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --check) CHECK=true; shift ;;
    --yes) YES=true; shift ;;
    --skip-infrastructure) SKIP_INFRASTRUCTURE=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$CONFIG_PATH" ]] || { usage >&2; exit 2; }

CONFIG=$(jq -ef "$ROOT/admin/validate-config.jq" "$CONFIG_PATH")
SUBSCRIPTION_ID=$(value .subscriptionId)
TENANT_ID=$(value .tenantId)
GATEWAY_AUDIENCE=$(value .gatewayAudience)
MODE=$(jq -r '.teamGovernance.mode // "off"' <<< "$CONFIG")

printf 'teamGovernance.mode=%s; teams=%s; profiles=%s\n' "$MODE" \
  "$(jq -r '.teamGovernance.teams // [] | length' <<< "$CONFIG")" \
  "$(jq -r '.teamGovernance.profiles // [] | length' <<< "$CONFIG")"
jq -r '.teamGovernance.teams[]? | "  - \(.id): \(.displayName) -> group \"\(.groupDisplayName)\", role \(.teamRoleValue), profile \(.profile), \(.members | length) member(s)"' <<< "$CONFIG"

if [[ "$DRY_RUN" == true ]]; then
  echo 'DRY RUN: configuration validated offline. No writes, logins, Graph or Azure calls made.'
  exit 0
fi

command -v az >/dev/null 2>&1 || { echo 'Azure CLI (az) is required.' >&2; exit 1; }
ACCOUNT=$(azure account show --subscription "$SUBSCRIPTION_ID" -o json)
[[ $(jq -r .tenantId <<< "$ACCOUNT") == "$TENANT_ID" ]] || { echo 'Wrong Azure tenant; log in to the configured tenant.' >&2; exit 1; }

if [[ "$CHECK" != true && "$YES" != true ]]; then
  echo 'Review --dry-run/--check, then pass --yes to authorize Azure and Entra changes.' >&2
  exit 2
fi

deploy_governance() {
  local parameter_file=$TEMP/22-team-governance.parameters.json result
  jq -n --arg apimName "$(value .apimName)" \
    --arg workspaceId "$(value .workspaceResourceId)" \
    --arg workspaceName "$(jq -er '.workspaceResourceId | split("/")[-1]' <<< "$CONFIG")" \
    --arg workbookLocation "$(value .workbookLocation)" \
    --arg mode "$MODE" \
    --argjson profiles "$(jq -c '.teamGovernance.profiles // null' <<< "$CONFIG")" \
    --argjson teams "$(jq -c '.teamGovernance.teams // null' <<< "$CONFIG")" \
    --argjson actionGroupIds "$(jq -c '.teamGovernance.actionGroupIds // []' <<< "$CONFIG")" '
      {
        apimName: {value: $apimName},
        logAnalyticsWorkspaceId: {value: $workspaceId},
        logAnalyticsWorkspaceName: {value: $workspaceName},
        workbookLocation: {value: $workbookLocation},
        teamGovernanceMode: {value: $mode},
        actionGroupIds: {value: $actionGroupIds}
      }
      + (if $profiles == null then {} else {profiles: {value: $profiles}} end)
      + (if $teams == null then {} else {teams: {value: $teams}} end)
    ' > "$parameter_file"
  result=$(azure deployment group create --subscription "$SUBSCRIPTION_ID" --name 22-team-governance \
    --resource-group "$(value .resourceGroup)" --template-file "$ROOT/infra/22-team-governance.bicep" \
    --parameters "@$parameter_file" -o json)
  jq -e '.properties.outputs |
    .teamGovernanceModeNamedValue.value == "team-governance-mode" and
    .teamsJsonNamedValue.value == "team-governance-teams-json" and
    .profilesJsonNamedValue.value == "team-governance-profiles-json" and
    (.workbookId.value | length > 0) and .claudeTeamsFunctionName.value == "ClaudeTeams" and
    (.alertsCreated.value | type == "boolean")' <<< "$result" >/dev/null || {
      echo 'Team governance deployment outputs are incomplete.' >&2
      exit 1
    }
  echo 'Deployed team governance infrastructure and workbook (modules 22 and 23).'
}

TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

if [[ "$CHECK" == true ]]; then
  echo 'CHECK: module 22 deployment skipped because check mode is read-only.'
elif [[ "$SKIP_INFRASTRUCTURE" != true ]]; then
  deploy_governance
fi

if [[ "$MODE" == off ]]; then
  echo 'teamGovernance.mode is off; infrastructure is configured but Entra reconciliation is disabled.'
  exit 0
fi

APP=$(azure ad app show --id "$GATEWAY_AUDIENCE" -o json)
GATEWAY_SP_ID=$(azure ad sp show --id "$GATEWAY_AUDIENCE" --query id -o tsv)

# --- Ensure gateway app roles (idempotent merge; never removes or disables unrelated roles) ---
jq -c '[({value: "Claude.User", displayName: "Claude User", description: "Access to the Claude gateway"}),
  (.teamGovernance.teams[] | {value: ("Claude.Tier." + (.defaultUserTier | ascii_upcase[0:1]) + (.defaultUserTier[1:])), displayName: ("Individual tier - " + .defaultUserTier), description: ("Claude individual budget tier: " + .defaultUserTier)}),
  (.teamGovernance.teams[] | {value: .teamRoleValue, displayName: ("Team - " + .displayName), description: ("Claude team membership: " + .displayName)}),
        (.teamGovernance.profiles[] | {value: .roleValue, displayName: ("Team profile - " + .name), description: ("Claude team budget profile: " + .name)})]
       | flatten | unique_by(.value)' <<< "$CONFIG" > "$TEMP/desired-roles.json"
jq -c '.appRoles // []' <<< "$APP" > "$TEMP/existing-roles.json"

DESIRED_COUNT=$(jq 'length' "$TEMP/desired-roles.json")
NEW_IDS='[]'
for ((i = 0; i < DESIRED_COUNT; i++)); do
  NEW_IDS=$(jq -c --arg g "$(new_guid)" '. + [$g]' <<< "$NEW_IDS")
done
echo "$NEW_IDS" > "$TEMP/new-ids.json"

jq -n --slurpfile existing "$TEMP/existing-roles.json" --slurpfile desired "$TEMP/desired-roles.json" --slurpfile ids "$TEMP/new-ids.json" '
  ($existing[0]) as $existing | ($desired[0]) as $desired | ($ids[0]) as $ids |
  ($existing | map({(.value): .}) | add // {}) as $have |
  [$desired[] as $d | ($have[$d.value]) as $ex |
    if $ex then ($ex + {isEnabled: true})
    else ($d + {id: $ids[($desired | map(.value) | index($d.value))], isEnabled: true, allowedMemberTypes: ["User"]})
    end] as $resolved |
  ($existing | map(select((.value as $v | ($desired | map(.value) | index($v))) | not))) as $untouched |
  {
    appRoles: ($untouched + $resolved),
    roleIdByValue: ($resolved | map({(.value): .id}) | add),
    missing: [$desired[] | .value as $v | select(($have[$v] // null) == null or ($have[$v].isEnabled != true)) | $v]
  }
' > "$TEMP/role-merge.json"

MISSING_ROLES=$(jq -c '.missing' "$TEMP/role-merge.json")
if [[ "$(jq 'length' <<< "$MISSING_ROLES")" -gt 0 ]]; then
  if [[ "$CHECK" == true ]]; then
    DRIFT=true
    printf 'DRIFT: missing or disabled gateway app roles: %s\n' "$(jq -r 'join(", ")' <<< "$MISSING_ROLES")"
  else
    jq -c '{appRoles: .appRoles}' "$TEMP/role-merge.json" > "$TEMP/roles-patch.json"
    azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$(jq -er .id <<< "$APP")" \
      --headers Content-Type=application/json --body "@$TEMP/roles-patch.json" -o none
    printf 'Ensured gateway app roles: %s\n' "$(jq -r 'join(", ")' <<< "$MISSING_ROLES")"
  fi
fi
ROLE_ID_BY_VALUE=$(jq -c '.roleIdByValue' "$TEMP/role-merge.json")

# --- Per-team groups, membership and role assignments ---
: > "$TEMP/teams.jsonl"
TEAM_COUNT=$(jq '.teamGovernance.teams | length' <<< "$CONFIG")
for ((t = 0; t < TEAM_COUNT; t++)); do
  TEAM=$(jq -c ".teamGovernance.teams[$t]" <<< "$CONFIG")
  TEAM_ID=$(jq -r .id <<< "$TEAM")
  DISPLAY=$(jq -r .displayName <<< "$TEAM")
  GROUP_DISPLAY=$(jq -r .groupDisplayName <<< "$TEAM")
  TEAM_ROLE_VALUE=$(jq -r .teamRoleValue <<< "$TEAM")
  TIER_ROLE_VALUE=$(jq -r '.defaultUserTier | "Claude.Tier." + (.[0:1] | ascii_upcase) + .[1:]' <<< "$TEAM")
  PROFILE_NAME=$(jq -r .profile <<< "$TEAM")
  PROFILE_ROLE_VALUE=$(jq -r --arg n "$PROFILE_NAME" '.teamGovernance.profiles[] | select(.name == $n) | .roleValue' <<< "$CONFIG")
  MEMBERS=$(jq -c '.members' <<< "$TEAM")

  FILTER="displayName eq '$(odata_escape "$GROUP_DISPLAY")'"
  MATCHING_GROUPS=$(azure ad group list --filter "$FILTER" -o json)
  GROUP_COUNT=$(jq 'length' <<< "$MATCHING_GROUPS")
  [[ "$GROUP_COUNT" -le 1 ]] || { printf 'Multiple Entra groups are named "%s"; resolve manually before rerunning.\n' "$GROUP_DISPLAY" >&2; exit 1; }

  GROUP_STATUS=''
  GROUP='null'
  if [[ "$GROUP_COUNT" -eq 1 ]]; then
    GROUP=$(jq -c '.[0]' <<< "$MATCHING_GROUPS")
    GROUP_STATUS='existing'
  elif [[ "$CHECK" == true ]]; then
    GROUP_STATUS='missing'
    DRIFT=true
  else
    MAIL_NICK=$(printf '%s' "$TEAM_ID" | tr -c 'A-Za-z0-9' '-')
    GROUP=$(azure ad group create --display-name "$GROUP_DISPLAY" --mail-nickname "$MAIL_NICK" \
      --description "Claude team governance ($TEAM_ID); managed by setup-teams-governance-claude-gateway, do not edit membership manually." -o json)
    GROUP_STATUS='created'
  fi
  GROUP_ID=$(jq -r '.id // empty' <<< "$GROUP")

  MISSING_USERS='[]'
  RESOLVED_MEMBERS='[]'
  MEMBER_COUNT=$(jq 'length' <<< "$MEMBERS")
  for ((m = 0; m < MEMBER_COUNT; m++)); do
    UPN=$(jq -r ".[$m]" <<< "$MEMBERS")
    USER=$(azure ad user show --id "$UPN" -o json 2>/dev/null || true)
    if [[ -z "$USER" ]]; then
      MISSING_USERS=$(jq -c --arg u "$UPN" '. + [$u]' <<< "$MISSING_USERS")
    else
      RESOLVED_MEMBERS=$(jq -c --arg u "$UPN" --arg id "$(jq -r .id <<< "$USER")" '. + [{upn: $u, objectId: $id}]' <<< "$RESOLVED_MEMBERS")
    fi
  done
  if [[ "$(jq 'length' <<< "$MISSING_USERS")" -gt 0 ]]; then
    if [[ "$CHECK" == true ]]; then
      DRIFT=true
    else
      printf 'Missing Entra users for team %s: %s\n' "$TEAM_ID" "$(jq -r 'join(", ")' <<< "$MISSING_USERS")" >&2
      exit 1
    fi
  fi

  CURRENT_MEMBERS='[]'
  ADDED_MEMBERS='[]'
  EXTRA_MEMBERS='[]'
  if [[ -n "$GROUP_ID" ]]; then
    CURRENT_MEMBERS=$(azure ad group member list --group "$GROUP_ID" -o json | jq -c '[.[] | {upn: (.userPrincipalName // .displayName), objectId: .id}]')
    RESOLVED_MEMBER_COUNT=$(jq 'length' <<< "$RESOLVED_MEMBERS")
    for ((m = 0; m < RESOLVED_MEMBER_COUNT; m++)); do
      MEMBER=$(jq -c ".[$m]" <<< "$RESOLVED_MEMBERS")
      MEMBER_ID=$(jq -r .objectId <<< "$MEMBER")
      if jq -e --arg id "$MEMBER_ID" 'any(.[]; .objectId == $id)' <<< "$CURRENT_MEMBERS" >/dev/null; then
        continue
      fi
      if [[ "$CHECK" == true ]]; then
        DRIFT=true
      else
        azure ad group member add --group "$GROUP_ID" --member-id "$MEMBER_ID"
      fi
      ADDED_MEMBERS=$(jq -c --argjson m "$MEMBER" '. + [$m]' <<< "$ADDED_MEMBERS")
    done
    EXTRA_MEMBERS=$(jq -c --argjson desired "$RESOLVED_MEMBERS" '[.[] | select((.objectId as $id | ($desired | map(.objectId) | index($id))) | not)]' <<< "$CURRENT_MEMBERS")
    [[ "$(jq 'length' <<< "$EXTRA_MEMBERS")" -eq 0 ]] || DRIFT=true
  fi

  ROLE_ASSIGNMENTS='[]'
  if [[ -n "$GROUP_ID" ]]; then
    ASSIGNED=$(azure rest --method GET --url "https://graph.microsoft.com/v1.0/groups/$GROUP_ID/appRoleAssignments" -o json)
    for ROLE_VALUE in 'Claude.User' "$TEAM_ROLE_VALUE" "$PROFILE_ROLE_VALUE" "$TIER_ROLE_VALUE"; do
      ROLE_ID=$(jq -r --arg v "$ROLE_VALUE" '.[$v] // empty' <<< "$ROLE_ID_BY_VALUE")
      [[ -n "$ROLE_ID" ]] || { printf 'App role %s was not resolved; rerun after roles are ensured.\n' "$ROLE_VALUE" >&2; exit 1; }
      if jq -e --arg rid "$ROLE_ID" --arg sp "$GATEWAY_SP_ID" 'any(.value[]?; .appRoleId == $rid and .resourceId == $sp)' <<< "$ASSIGNED" >/dev/null; then
        ROLE_ASSIGNMENTS=$(jq -c --arg v "$ROLE_VALUE" '. + [{role: $v, status: "existing"}]' <<< "$ROLE_ASSIGNMENTS")
      elif [[ "$CHECK" == true ]]; then
        DRIFT=true
        ROLE_ASSIGNMENTS=$(jq -c --arg v "$ROLE_VALUE" '. + [{role: $v, status: "missing"}]' <<< "$ROLE_ASSIGNMENTS")
      else
        jq -n --arg p "$GROUP_ID" --arg r "$GATEWAY_SP_ID" --arg a "$ROLE_ID" '{principalId: $p, resourceId: $r, appRoleId: $a}' > "$TEMP/assign-$t-$ROLE_VALUE.json"
        azure rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GATEWAY_SP_ID/appRoleAssignedTo" \
          --headers Content-Type=application/json --body "@$TEMP/assign-$t-$ROLE_VALUE.json" -o none
        ROLE_ASSIGNMENTS=$(jq -c --arg v "$ROLE_VALUE" '. + [{role: $v, status: "assigned"}]' <<< "$ROLE_ASSIGNMENTS")
      fi
    done
  fi

  jq -n --arg id "$TEAM_ID" --arg display "$DISPLAY" --arg group "$GROUP_DISPLAY" --arg status "$GROUP_STATUS" \
    --arg groupId "$GROUP_ID" --argjson missingUsers "$MISSING_USERS" --argjson resolved "$RESOLVED_MEMBERS" \
    --argjson added "$ADDED_MEMBERS" --argjson current "$CURRENT_MEMBERS" --argjson extra "$EXTRA_MEMBERS" --argjson roles "$ROLE_ASSIGNMENTS" '
    {id: $id, displayName: $display, groupDisplayName: $group, groupStatus: $status, groupObjectId: ($groupId | if . == "" then null else . end),
     missingUsers: $missingUsers, members: $resolved, addedMembers: $added, currentMembers: $current, extraMembers: $extra, roleAssignments: $roles}
  ' >> "$TEMP/teams.jsonl"
done

jq -s --arg mode "$MODE" --arg check "$CHECK" --arg app "$(jq -r .id <<< "$APP")" --arg sp "$GATEWAY_SP_ID" --argjson missingRoles "$MISSING_ROLES" '
  (reduce .[] as $t ({}; reduce ($t.members | map(.upn) | .[]) as $upn (.; .[$upn] = ((.[$upn] // 0) + 1)))) as $counts |
  {
    mode: $mode, checkMode: ($check == "true"), gatewayApplicationObjectId: $app, gatewayServicePrincipalId: $sp,
    missingOrDisabledAppRoles: $missingRoles, teams: ., ambiguousMembers: [$counts | to_entries[] | select(.value > 1) | .key]
  }
' "$TEMP/teams.jsonl" > "$TEMP/manifest.json"
[[ "$(jq '.ambiguousMembers | length' "$TEMP/manifest.json")" -eq 0 ]] || DRIFT=true

cat "$TEMP/manifest.json"
[[ -z "$MANIFEST_OUTPUT" ]] || cp "$TEMP/manifest.json" "$MANIFEST_OUTPUT"

if [[ "$CHECK" == true && "$DRIFT" == true ]]; then
  echo 'Reconciliation found drift; rerun without --check (with --yes) to converge, or review the manifest above.' >&2
  exit 1
fi
echo 'Team governance reconciliation complete. Group deletions and member removals are never automatic.'
