# Administrator Setup

Run the existing [infrastructure deployment steps](../infra/README.md) through either
[claude-gateway-setup.sh](claude-gateway-setup.sh) on macOS or
[claude-gateway-setup.ps1](claude-gateway-setup.ps1) with PowerShell 7.2+.
Both use [setup.example.json](setup.example.json) as the configuration template.
Parameters are declared there, and script options/state are declared at the top of
each entry point. Neither script creates Entra registrations, assigns developer
roles, deletes resources, purges soft-deleted APIM services, or requests quota increases.

## Prerequisites

- Existing subscription, resource group, Foundry account with Claude deployments,
  and Log Analytics workspace. Foundry must be in the deployment resource group.
  The workspace can be in another resource group in the same subscription.
- Gateway Entra registration with v2 tokens, the configured identifier URI, and an
  enabled `Claude.User` app role. Assign that role to developers. Optional
  `Claude.Tier.Pro` and `Claude.Tier.Basic` roles select tiers; otherwise users get
  `lite`. `Claude.Suspended` blocks a user. Group membership alone is not enough
  unless the group has the appropriate application role assignment.
- Separate budget API registration/service principal. The scripts discover APIM's
  managed identity **application/client ID** and pass it to Easy Auth. This is not
  the identity's object ID.
- Azure CLI with Bicep, `jq`, Azure Functions Core Tools v4, and a Python environment
  with `azure-identity`, `azure-monitor-ingestion`, `requests`, and `redis`.
  Set `pythonExecutable` to the executable name or absolute path, not a command
  containing arguments. Function remote builds use the existing Python 3.11 apps.
- Azure CLI `quota` extension when `checkEp1Quota` is enabled. Register the
  `Microsoft.Quota` provider separately if your subscription requires it. The
  script displays EP1 limit/usage; this does not guarantee available capacity.
- An identity able to deploy resources and assign roles in both resource groups,
  read the existing Entra apps/service principals, and publish Function code.
  Python's `DefaultAzureCredential` must resolve to `pricingPublisherPrincipalId`
  in `tenantId`; preflight checks this without displaying its access token.
- Data-plane access from the admin machine to Redis and DCR ingestion. The wrapper
  grants the configured publisher Redis Data Contributor; template `14` grants
  DCR publishing access. Optional reconciliation also grants Foundry Monitoring Reader.

On macOS, tools can be installed using your organization's approved package manager.
On Windows, install PowerShell 7.2+ and put `az`, `jq`, `func`, and the selected
Python executable on PATH. Windows PowerShell 5.1 is not supported. The scripts do
not change execution policy or bypass organizational controls.

## Configure and Run

Create your local `admin/setup.local.json` using the structure in
[setup.example.json](setup.example.json). Replace every placeholder.

Important configuration choices:

| Setting | Meaning |
|---|---|
| `apimLocation`, `budgetLocation` | Must match because the diagnostic Event Hub and APIM must share a region. Existing resources cannot be moved by changing these values. |
| `workspaceResourceId`, `workspaceLocation` | Full existing workspace ID and actual region; the workspace need not be in APIM's region. |
| `cosmosLocation`, `workbookLocation` | Explicit independent locations. Regional availability still applies. |
| `gatewayAudience` | Bare gateway application/client ID used in v2 `aud`. |
| `tokenResource` | Registered identifier URI used to acquire a gateway token, commonly `api://<gateway-client-id>`. Not the Foundry/Cognitive Services audience. |
| `budgetApiAudience` | Separate budget API application/client ID. |
| `tiersConfig` | Exactly `pro`, `basic`, `lite`; `tpm` is per minute, `tokenQuota` is monthly tokens, `costQuota` is monthly USD. Passed identically to templates `04`, `14`, and `16`. |
| `models` | Leave aliases empty to discover deployed Opus, Sonnet, and Haiku. If there is not exactly one candidate per family, specify the desired deployment name. A fallback must be chosen explicitly. |
| `clientConfiguration.clientId` | Desktop OIDC public-client registration ID, not the gateway API audience. Empty prompts during export. |
| `clientConfiguration.scopes` | Space-separated OIDC and gateway delegated scopes, for example `openid profile api://<gateway-client-id>/access_as_user`. Empty discovers a registered API scope or prompts. |
| `clientConfiguration.settingsFile` | Optional JSON file for the screenshot settings described below. Relative paths resolve from the repository root. |
| `storageGovernanceTags` | Organization-approved tags. Empty by default; the wrapper does not apply the template's tenant-specific Ignore tags automatically. |
| `onboardingOutput` | Generated handoff JSON. Relative paths resolve from the repository root. |

Review the `PRICES` dictionary in [the pricing loader](../snippets/15-load-pricing.py)
against your actual agreement and models. Rates are **per 1,000 tokens**. Ensure
the model keys reported in usage have pricing entries. Missing Redis prices can
produce zero-dollar charges. Set `options.pricesReviewed=true` only after review.

From the repository root, first validate offline:

```bash
bash admin/claude-gateway-setup.sh --config admin/setup.local.json --dry-run
```

```powershell
./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json -DryRun
```

Dry run validates config and displays the sequence/options. It performs **no Azure
calls, logins, installs, inference, or file writes**. It is not ARM what-if and
cannot check identity, permissions, model availability, or capacity.

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
2. Bootstrap APIM with template `04` only when it does not exist.
3. Deploy tiers/DCR with `14` into the workspace resource group.
4. Deploy `16` with the current APIM identity client ID and budget API audience.
5. Grant pricing access and load prices into **both** Log Analytics and Redis.
6. Publish the budget API and usage processor from their existing source folders.
7. Redeploy `04` with the actual budget endpoint and Event Hub outputs.
8. Export the developer JSON; optionally run smoke tests, reporting, and reconciliation.

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
- `reconcile`: run one cost-reconciliation pass for `reconcileHours`. This does
  **not** schedule a recurring job. Repeated rollups must be deduplicated using
  `arg_max(TimeGenerated, *) by BinStart, Model` as in the existing reporting.
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

Users still need the gateway API's `Claude.User` application-role assignment. Setup
does not assign that role because the admin config does not identify onboarding
users or groups. The standalone export scripts remain read-only and prompt for a
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