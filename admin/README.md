# Administrator Setup

Run the existing [infrastructure deployment steps](../infra/README.md) through either
[claude-gateway-setup.sh](claude-gateway-setup.sh) on macOS or
[claude-gateway-setup.ps1](claude-gateway-setup.ps1) with PowerShell 7.2+.
Both use [setup.example.json](setup.example.json) as the configuration template.
Parameters are declared there, and script options/state are declared at the top of
each entry point. The main scripts create or reuse the Desktop public-client registration
and, when team governance is active, invoke the additive team-governance reconciler.
They do not delete resources or directory assignments, purge soft-deleted APIM services,
or request quota increases.

## Prerequisites

- Existing subscription, gateway resource group, Foundry account with Claude deployments,
  and Log Analytics workspace. Set `resourceGroup` to the gateway deployment group and
  `foundryResourceGroup` to the group containing the Foundry account. The Foundry and
  workspace can be in other resource groups in the same subscription. For compatibility,
  omitting `foundryResourceGroup` defaults it to `resourceGroup`.
- Gateway Entra registration with v2 tokens, the configured identifier URI, and an
  enabled `Claude.User` app role. Assign that role to developers. Optional
  `Claude.Tier.Pro` and `Claude.Tier.Basic` roles select tiers; otherwise users get
  `lite`. `Claude.Suspended` blocks a user. Group membership alone is not enough
  unless the group has the appropriate application role assignment.
- The scripts create or reuse a separate budget API registration/service principal
  when `budgetApiAudience` is empty. They also discover APIM's managed identity
  **application/client ID** and pass it to Easy Auth. This is not the identity's object ID.
- Azure CLI with Bicep, `jq`, and a Python environment with `pip`. Before the main
  preflight, the setup wrappers install Azure Functions Core Tools v4 when `func`
  is missing and install missing `azure-identity`, `azure-monitor-ingestion`,
  `requests`, and `redis` packages into the configured Python environment.
  Set `pythonExecutable` to the executable name or absolute path, not a command
  containing arguments. Function remote builds use the existing Python 3.11 apps.
- Azure CLI `quota` extension when `checkEp1Quota` is enabled. Register the
  `Microsoft.Quota` provider separately if your subscription requires it. The
  script displays EP1 limit/usage; this does not guarantee available capacity.
- An identity able to deploy resources and assign roles in both resource groups,
  read the existing Entra apps/service principals, and publish Function code.
  Preflight resolves the active Python `DefaultAzureCredential`, checks it is in
  `tenantId`, and auto-detects `pricingPublisherPrincipalId`/`pricingPublisherPrincipalType`
  from it (via a Microsoft Graph directory-object lookup) without displaying its
  access token. Set `pricingPublisherPrincipalId` explicitly in the config only to
  pin a specific value; preflight then verifies the credential matches it instead.
- Data-plane access from the admin machine to Redis and DCR ingestion. The wrapper
  grants the configured publisher Redis Data Contributor; template `14` grants
  DCR publishing access. Optional reconciliation also grants Foundry Monitoring Reader.

Automatic Core Tools installation uses Homebrew on macOS and WinGet, with
Chocolatey as a fallback, on Windows. Install PowerShell 7.2+ on Windows and put
`az`, `jq`, and the selected Python executable on PATH. Windows PowerShell 5.1 is
not supported. Dry runs remain offline and install nothing. The scripts do not
install package managers, change execution policy, elevate privileges, or bypass
organizational controls.

## Configure and Run

On macOS/Linux, interactive setup can create `admin/setup.local.json` from the
defaults in [setup.example.json](setup.example.json). From the repository root, run:

```bash
bash admin/claude-gateway-setup.sh --interactive --stage preflight
```

The script prompts for all required subscription, tenant, identity, resource, and
optional team values; validates the effective configuration; saves it with restricted
file permissions; and then runs read-only preflight. Add `--yes` instead of
`--stage preflight` when ready to authorize the full deployment. Interactive mode is
automatic when standard input is a terminal, so `--interactive` is optional there.

For automation, create `admin/setup.local.json` using the structure in
[setup.example.json](setup.example.json), replace every placeholder, and pass it with
`--config`. Explicit `--non-interactive` mode requires a configuration file.

Important configuration choices:

| Setting | Meaning |
|---|---|
| `apimLocation`, `budgetLocation` | Must match because the diagnostic Event Hub and APIM must share a region. Existing resources cannot be moved by changing these values. |
| `workspaceResourceId`, `workspaceLocation` | Full existing workspace ID and actual region; the workspace need not be in APIM's region. |
| `cosmosLocation`, `workbookLocation` | Explicit independent locations. Regional availability still applies. |
| `gatewayAudience` | Bare gateway application/client ID used in v2 `aud`. |
| `tokenResource` | Registered identifier URI used to acquire a gateway token, commonly `api://<gateway-client-id>`. Not the Foundry/Cognitive Services audience. |
| `budgetApiAudience` | Separate budget API application/client ID. Leave empty to create or reuse `Claude Budget API - <namePrefix>`. |
| `tiersConfig` | Exactly `pro`, `basic`, `lite`; `tpm` is per minute, `tokenQuota` is monthly tokens, `costQuota` is monthly USD. Passed identically to templates `04`, `14`, and `16`. |
| `models` | Leave aliases empty to discover deployed Opus, Sonnet, and Haiku. If there is not exactly one candidate per family, specify the desired deployment name. A fallback must be chosen explicitly. |
| `clientConfiguration.clientId` | Desktop OIDC public-client registration ID, not the gateway API audience. Empty prompts during export. |
| `clientConfiguration.scopes` | Space-separated OIDC and gateway delegated scopes, for example `openid profile api://<gateway-client-id>/access_as_user`. Empty discovers a registered API scope or prompts. |
| `clientConfiguration.settingsFile` | Optional JSON file for the screenshot settings described below. Relative paths resolve from the repository root. |
| `storageGovernanceTags` | Organization-approved tags. Empty by default; the wrapper does not apply the template's tenant-specific Ignore tags automatically. |
| `onboardingOutput` | Generated handoff JSON. Relative paths resolve from the repository root. |

### Team Governance

`teamGovernance` is an optional top-level block in `setup.example.json` that
declares team-level budget profiles and direct membership as source-controlled config.
Omitting the key is valid and is treated as `{"mode":"off","profiles":[],"teams":[]}`.
In `observe` or `enforce`, the main setup invokes the neighboring standalone Bash or
PowerShell reconciler before deploying the final APIM policy.

| Field | Meaning |
|---|---|
| `teamGovernance.mode` | `off`, `observe`, or `enforce`. Must default to `off` for backward compatibility. |
| `teamGovernance.actionGroupIds[]` | Optional Azure Monitor action-group resource IDs. An empty array deploys the workbook without the five governance alert rules. |
| `teamGovernance.profiles[]` | Named team-level budget profiles: `name`, `roleValue` (an Entra app role value in the `Claude.TeamProfile.*` namespace), and `tpm`/`tokenQuota`/`costQuota` aggregate limits for the team. |
| `teamGovernance.teams[]` | One entry per governed team: stable `id`, display/group names, `Claude.Team.*` role, profile reference, default individual tier, `allowedModels`, and non-overlapping direct member UPNs. The governance scripts create or resolve the security group. |
| `teamGovernance.teams[].allowedModels` | Non-empty unique subset of `claude-sonnet-5`, `claude-haiku-4-5`, and `claude-opus-5`. Omitting the property preserves backward compatibility and allows all three. |

Validation rejects unknown `mode` values, duplicate team IDs/group display
names/team role values/profile role values, a `profile` or `defaultUserTier`
that does not exist, empty/duplicate/unsupported model allowlists, non-positive profile limits, and any member UPN listed
under more than one team. Apply preflight also requires every listed user to resolve uniquely.

Interactive setup presents the three model IDs as numbered options for every team and
accepts comma-separated selections such as `1,3`. In `enforce` mode, APIM returns only
that team's models from `GET /v1/models` and rejects an unlisted `/v1/messages` model
with HTTP 403 and `x-claude-denied-by: team-model-policy`. Modes `off` and `observe`
do not filter or deny models, preserving the staged governance rollout.

The standalone scripts preserve existing app-role IDs, unrelated roles, extra group members,
and unrelated assignments. They add missing direct members and assign each team group the required
`Claude.User`, default `Claude.Tier.*`, `Claude.Team.*`, and `Claude.TeamProfile.*` roles.
An authorized standalone apply also deploys `infra/22-team-governance.bicep`; that module embeds
`infra/23-team-governance-workbook.json` at compile time, so workbook 23 is not deployed separately.
Mode `off` still deploys the named values and workbook but skips Entra reconciliation. The full
gateway setup suppresses this standalone deployment because it deploys module 22 itself immediately
before the final APIM policy. The scripts never remove directory state. Use `--check` / `-Check` for read-only drift reporting,
`--dry-run` / `-DryRun` for local validation, and `--yes` / `-Yes` only after reviewing the
target tenant and config. Keep the emitted manifest as audit evidence.

The operator needs delegated Microsoft Graph permissions sufficient to read users,
applications, service principals, groups, members, and app-role assignments and to update
the gateway app, create/update groups, add members, and create group app-role assignments.
Common tenant grants are `User.Read.All`, `Application.ReadWrite.All`, and
`Group.ReadWrite.All`; prefer a narrower custom role where available. Admin consent, Entra
licensing for group-based enterprise-app assignment, and production apply approval remain
tenant-owner responsibilities. Azure CLI authentication is reused; no Graph secret is stored.
Role and membership changes appear only in newly issued access tokens.
The operator also needs resource-group deployment permission for the standalone module-22 apply.

Review the `PRICES` dictionary in [the pricing loader](../snippets/15-load-pricing.py)
against your actual agreement and models. Rates are **per 1,000 tokens**. Ensure
the model keys reported in usage have pricing entries. Missing Redis prices can
produce zero-dollar charges. Set `options.pricesReviewed=true` only after review.

To validate an existing configuration offline:

```bash
bash admin/claude-gateway-setup.sh --config admin/setup.local.json --dry-run
```

```powershell
./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json -DryRun
```

Dry run validates config and displays the sequence/options. It performs **no Azure
calls, logins, installs, inference, or file writes**, except when an explicit
`--log-file` is requested. It is not ARM what-if and
cannot check identity, permissions, model availability, or capacity. A config-free
interactive dry run validates the prompted configuration but does not save it.

For timestamped progress, Azure CLI verbose diagnostics, failure line/command
context, and a persistent copy of the live terminal stream:

```bash
bash admin/claude-gateway-setup.sh \
  --config admin/setup.local.json \
  --non-interactive \
  --yes \
  --debug \
  --log-file logs/claude-gateway-setup.log
```

The log is streamed through `tee`, so output remains visible while the command runs.
Debug mode intentionally does not enable raw `set -x` tracing, which could expose
tokens or request bodies.

When run from a terminal, the Bash script can additionally prompt for subscription,
tenant, pricing-publisher identity, and publisher name when creating its local config.
Both main scripts prompt before validation for the resource group, APIM and resource
locations, publisher email, gateway application ID, workspace resource ID, Foundry
name, resource prefix, and optional team governance entries. Use `--interactive` /
`-Interactive` to prompt with redirected input, or
`--non-interactive` / `-NonInteractive` for automation. Prompted values are held in a
temporary effective configuration and passed to the team-governance reconciler; the
source configuration file is not changed when one was supplied explicitly. A Bash
interactive run without `--config` creates or updates `admin/setup.local.json`.

After logging into the configured tenant/subscription, run read-only preflight:

```bash
bash admin/claude-gateway-setup.sh --config admin/setup.local.json --stage preflight
```

```powershell
./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json -Stage preflight
```

Preflight reads Azure and directory data, acquires a Python credential to verify
identity, and compiles Bicep. Azure CLI can update its own cache/tooling. No Azure
resources are changed. Provider registration is an optional later deployment step,
so providers/extensions needed for preflight must already be available.

To authorize provisioning and publication:

```bash
bash admin/claude-gateway-setup.sh --config admin/setup.local.json --yes
```

```powershell
./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json -Yes
```

The workflow is:

1. Preflight and optional provider registration.
2. Bootstrap APIM with template `04` and policy deployment disabled when it does not exist.
3. Deploy tiers/DCR with `14` into the workspace resource group.
4. Deploy `16` with the current APIM identity client ID and budget API audience.
5. Grant pricing access and load prices into **both** Log Analytics and Redis.
6. Publish the budget API and usage processor from their existing source folders.
7. Reconcile Entra teams when governance mode is active, then deploy module `22` named values,
   `ClaudeTeams()` metadata, workbook, and optional alerts.
8. Redeploy `04` with policy enabled and the actual budget/Event Hub outputs.
9. Export developer JSON; optionally run reporting, smoke tests, and Cosmos-ledger replay.

StandardV2 APIM, EP1 (two always-ready budget API instances), Redis, Cosmos, Event Hub,
storage, monitoring, and optional Grafana incur charges. Use a maintenance window
for an existing gateway: updating policy, shared settings, or Function code can
affect traffic. A new gateway's bootstrap is deliberately fail-open for the budget
lookup; do not onboard users until runtime checks pass.

## Optional Stages and Recovery

Use `--stage` / `-Stage` with `--yes` / `-Yes` to resume `reporting`, `retention`, or
`export` without repeating provisioning. All stages use the same complete config.

- `workbook`: deploy the usage workbook (enabled by default).
- `summaryRule`: deploy hourly rollup and wait for its table, then PATCH retention
  to 30 interactive / 400 total days. Table creation needs the first bin. The
  configurable wait defaults to 7,200 seconds; after timeout rerun `retention`.
- `grafana`: provision Managed Grafana, install/update the `amg` extension, and
  import the dashboard. Set name, location, and admin principal. The importing
  identity needs Grafana data-plane permissions; Azure resource Owner alone is
  insufficient. Prefer the executing identity as admin or grant it access beforehand.
- `reconcile`: run one reconciliation pass. It rolls up aggregate Foundry cache metrics and
  rebuilds current-month user, tier, team, and profile Redis counters/flags from immutable
  Cosmos rows. It rejects mapping drift instead of rewriting historic team attribution.
  This does **not** schedule a recurring job.
- `smokeTest`: use the exported handoff for one small billable inference request
  and an unauthenticated rejection check. The executing user needs `Claude.User`.
  This does not test tier exhaustion, suspension, streaming, or accounting delivery.

Errors stop the workflow; resources already deployed remain. RBAC and managed
identity propagation can take several minutes. Resolve the reported cause, then
rerun. Existing APIM skips placeholder bootstrap on a full rerun, but Functions,
pricing, and selected reporting resources are reapplied. The JSON output is
replaced only when export validation succeeds. Keep the same prefix/resource
names when resuming.

Region changes, APIM soft-delete conflicts, and stale Foundry role assignments
after identity recreation require a separately reviewed migration or targeted
repair. No deletion, purge, broad RBAC cleanup, or automatic quota increase is
performed. Interrupting the CLI does not cancel an in-progress ARM deployment.

### Governance operations

- Onboard: add the UPN to exactly one team in config, review `--check`, approve/apply, obtain a
  fresh token, and verify all four roles before traffic testing.
- Transfer: update source config, then separately approve removal of old membership and role
  assignments because reconciliation is additive-only. Do not promote while a fresh token has
  multiple team/profile roles.
- Tier/profile change: update config, apply, and verify a fresh token plus named values. Historical
  Cosmos rows retain request-time attribution.
- Emergency suspension: assign `Claude.Suspended`; existing tokens remain valid until refreshed.
- Monthly reset/rebuild: Redis keys expire after month end. Reconciliation replaces current-month
  state from Cosmos and stops on mapping drift.
- Rollback: change governance mode from `enforce` to `observe` and redeploy module `22`/policy.
  Individual controls remain active.

Follow [the live validation checklist](../docs/team-governance-live-validation.md) for promotion,
denial attribution, fail-open testing, and rollback evidence.

## Export Claude Client Configuration

The admin entry point generates `developer/claude-client-configuration.json` for
Claude Desktop, the Claude Code VS Code extension, and the Claude Code CLI.
The standalone exporters are [export-claude-client-configuration.sh](export-claude-client-configuration.sh)
and [export-claude-client-configuration.ps1](export-claude-client-configuration.ps1).
Both require `jq` and the neighboring [client-configuration.jq](client-configuration.jq).
The JSON contains **only client settings and model aliases**, not subscription,
resource group, APIM name, audience metadata, tiers, budgets, roles, or timestamps.
It does not contain tokens, passwords, or keys.

For the minimum-input interactive Bash export, sign in with Azure CLI and run:

```bash
az login
bash admin/export-claude-client-configuration.sh
```

The script asks for the Azure subscription ID, gateway resource group, and Desktop
OIDC public-client ID. It discovers the gateway URL, tenant, API identifier URI,
and delegated scope from the successful `04-apim-gateway` deployment and Entra
application. Press Enter to accept each model alias default. No deployment name,
deployment file, token resource, client settings file, or tenant ID is needed for
the normal live-Azure path.

To provide values explicitly for automation:

```bash
bash admin/export-claude-client-configuration.sh --subscription-id '<subscription-id>' \
  --resource-group '<gateway-resource-group>' --output developer/claude-client-configuration.json
```

```powershell
./admin/export-claude-client-configuration.ps1 -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<gateway-resource-group>' -Output ./developer/claude-client-configuration.json
```

Live export reads the URL and tenant from the successful `04-apim-gateway`
deployment. It reads registered API scopes when scopes are not supplied, preferring
an enabled `access_as_user` scope, otherwise a single enabled scope. It adds
`openid profile` to discovered scopes. If discovery cannot choose a scope, it asks
for the actual registered scope. Supply `--scopes` / `-Scopes` explicitly when
directory reads are unavailable. `--token-resource` / `-TokenResource` selects the
API identifier URI during scope discovery; it is not included as a separate output field.

The exporter asks for the **Desktop OIDC client ID**, then any missing scopes and
model deployment names. Press Enter at each model prompt to accept:

| Prompt | Default |
|---|---|
| Opus | `claude-opus-5` |
| Sonnet | `claude-sonnet-5` |
| Haiku | `claude-haiku-5-4` |

These are literal defaults, including the requested Haiku spelling. The exporter
does not deploy models or verify that these names exist. Enter your actual Foundry
deployment names when different. Explicit `--opus-model`, `--sonnet-model`,
`--haiku-model` (PowerShell: `-OpusModel`, `-SonnetModel`, `-HaikuModel`) skip their
prompts. For unattended export, also pass `--client-id` / `-ClientId` and
`--scopes` / `-Scopes`. EOF at a prompt fails without replacing the prior output.
The full admin setup passes the model names it validated during preflight;
standalone/export-only runs prompt for aliases that were not supplied.

### OIDC Prerequisites

Leave `clientConfiguration.clientId` empty when running the full Bash or PowerShell
setup. For `all` and `export` stages, setup creates or reuses the uniquely named
`Claude Desktop - <APIM name>` single-tenant public-client registration. It enables
public-client flows, registers `http://localhost` and
`http://127.0.0.1/callback`, adds the gateway's enabled `access_as_user` delegated
permission, creates its service principal when absent, and pre-authorizes that
client on the gateway API. Reruns reuse the registration. More than one exact-name
match fails so setup never chooses an application ambiguously.

To manage the Desktop registration separately, set `clientConfiguration.clientId`
to its application (client) ID. Setup validates the same public-client and redirect
requirements, then ensures the delegated permission and gateway pre-authorization.
The Desktop client ID is **not** the gateway API registration's audience. The setup
identity must be allowed to create/read Entra applications and must own or otherwise
be allowed to update the gateway API application. No client secret is created.

Users still need the gateway API's `Claude.User` application-role assignment. Active
team governance assigns it to each declared team group; deployments without team governance
must manage generic onboarding separately. The standalone export scripts remain read-only and prompt for a
Desktop client ID; only the full setup scripts provision the registration. The
issuer uses `https://login.microsoftonline.com/<tenant-id>/v2.0`.

The screenshot displays **ID token (default)**. This repository's gateway expects
a gateway-audience API token with `Claude.User`, so the export defaults to
`access_token`. An ID token for a separate Desktop client has the wrong audience.
Only select `id_token` through the optional settings below for a separately
validated gateway configuration that accepts it. The CLI/VS Code helpers always
acquire access tokens via Azure CLI, using the issuer tenant and the API resource
derived from scopes. Azure CLI and Desktop have separate login sessions and consent.

### Optional Screenshot Settings

Pass `--client-settings FILE` / `-ClientSettings FILE` to override these defaults:

```json
{
  "signInSessionLifetime": null,
  "gatewaySignInFlow": "browser",
  "bearerToken": "access_token",
  "redirectPort": null,
  "additionalRedirectReferrerHosts": [],
  "artifactPreviewIframeOrigin": null,
  "customInferenceHeaders": {},
  "streamIdleTimeout": 300
}
```

Durations are seconds. Null means leave the UI field blank; a null redirect port
uses the client's ephemeral-port behavior. Referrer hosts are hostnames, not URLs.
The artifact origin must be an HTTPS origin. Headers must be non-credential
headers; authorization/API-key/token/cookie/secret header names are rejected.
Do not put secrets in any field. Unknown fields and invalid values fail export.

The output has this shape (IDs and URLs below are illustrative, not deployed values):

```json
{
  "provider": "gateway",
  "credentialKind": "interactive_sign_in",
  "gatewayUrl": "https://example.azure-api.net/anthropic",
  "signInSessionLifetime": null,
  "gatewaySignInFlow": "browser",
  "gatewaySso": {
    "clientId": "<desktop-public-client-id>",
    "issuerUrl": "https://login.microsoftonline.com/<tenant-id>/v2.0",
    "bearerToken": "access_token",
    "scopes": "openid profile api://<gateway-api-client-id>/access_as_user",
    "redirectPort": null,
    "additionalRedirectReferrerHosts": []
  },
  "artifactPreviewIframeOrigin": null,
  "customInferenceHeaders": {},
  "streamIdleTimeout": 300,
  "models": {
    "opus": "claude-opus-5",
    "sonnet": "claude-sonnet-5",
    "haiku": "claude-haiku-5-4"
  }
}
```

Use `--deployment-name` / `-DeploymentName` for another ARM deployment name.
An offline saved `az deployment group show` document is supported through
`--deployment-file` / `-DeploymentFile`; supply the tenant if absent from the
document, plus the Desktop client ID and actual scopes (arguments or prompts).
Subscription/resource group are unnecessary in offline mode. Optional settings
file paths resolve from the current directory for standalone exports.
Existing output requires `--force` / `-Force` to replace.

`DEPLOYMENT`, `DEPLOYED_TENANT`, `APP`, `SETTINGS`, and `CONFIG` in the Bash script
are internal variables populated while it runs. They are not values an
administrator must configure.

The gateway URL comes from a deployment snapshot, not a live APIM named-value
audit. Reconcile/redeploy portal changes before exporting. Share the output via a
trusted internal channel with the [developer instructions](../developer/README.md).
The JSON is this repository's handoff format, not a verified native Desktop import
format; Desktop values are entered in its Gateway UI. Local admin config and the
default generated JSON filename are gitignored.

## Validation Status

Run `node --test tests/test_gateway_scripts.mjs` from the repository root. The local
harness uses POSIX command mocks to exercise Bash and PowerShell 7 on macOS:
deployment order, matching tiers, MI client-ID wiring, failure propagation,
rerun behavior, config export, settings merge/backups, helpers, and smoke checks.
The RBAC wrapper also compiles with `az bicep build`.

These checks do not constitute a Windows-host test or a live deployment. Function
publication, Azure capacity, RBAC propagation, runtime inference, and telemetry
must still be verified in your environment. Budget checks are asynchronous and
fail-open, and per-user accounting excludes cache-write costs. A 200 inference
response is not proof of complete or hard-dollar budget enforcement.