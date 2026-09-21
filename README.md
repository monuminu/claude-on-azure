# Claude on Azure

A working guide to running Anthropic's Claude inside the Microsoft ecosystem — **Claude in Microsoft
Foundry**, **Claude Code**, **Claude Desktop** (including how to run Cowork against your own Azure
endpoint), **Azure API Management as an enterprise gateway**, an **admin usage workbook**, and the
**Microsoft 365 connector**.

📖 **[Read the guide →](https://monuminu.github.io/claude-on-azure/)**

## What's covered

- Deploying Claude models in Microsoft Foundry, and the **Hosted on Azure vs Hosted on Anthropic**
  choice the portal disguises as a version number
- Which features actually work on an Azure-hosted deployment, and which don't
- Calling the endpoint with **keyless Entra ID auth** — cURL and the Python `AnthropicFoundry` client
- Pointing **Claude Code** at a Foundry deployment, and the model-pinning failure that will otherwise
  be your first support ticket
- Configuring **Claude Desktop** in third-party inference mode — static API key for a pilot, Entra
  app registration for a real rollout, plus MDM export
- Putting **Azure API Management** in front of Foundry so admins configure once and users just sign
  in — per-user Entra auth, app-role gating, token limits, and the audience mismatch that silently
  breaks one of the two clients
- Giving three developer tiers **their own monthly dollar budget** — and why APIM products,
  the obvious answer, cannot be driven from a claim
- Governing teams with Entra app roles, aggregate token and cost limits, observe/enforce rollout,
  durable Cosmos accounting, and Redis reconstruction
- Building an **admin usage workbook** — per-developer token and cost reporting, Claude Code vs
  Claude Desktop, and who is hitting their limits, from gateway logs that start out anonymous
- Setting up the **Microsoft 365 connector** by hand in Entra when your Global Admin has no Claude
  account, and the Conditional Access limitation that will break it
- CCU billing, RBAC, monitoring, and a decision table for Foundry vs the direct Claude API

## Repo contents

```
index.md            the guide
TIERED-QUOTAS.md    per-developer dollar budgets at 100K developers — design doc
CACHE-TOKEN-ANALYSIS.md  measured cache-accounting gaps and remediation review
images/             screenshots (tenant identifiers replaced)

infra/              everything you deploy — start at infra/README.md
  README.md                   prerequisites, deploy order, and the two-pass 04 -> 16 -> 04 loop
  03-apim-claude-policy.xml   APIM inbound policy: Entra validation, tier limits, MI backend auth
  04-apim-gateway.bicep       APIM v2 + system identity + API + tier named values + role assignment
  08-claude-usage-workbook.json  4-page admin workbook, 29 tiles
  09-workbook.bicep           deploys the workbook against your workspace
  10-claude-usage-summary-rule.bicep  hourly rollup, for history past raw retention
  11-grafana.bicep            Azure Managed Grafana + RBAC (billable, ~$31/month)
  11a-grafana-workspace-rbac.bicep    cross-resource-group role assignment module
  12-claude-usage-grafana-dashboard.json  20-panel Grafana dashboard
  13-import-grafana-dashboard.sh  imports it (no ARM path for AMG dashboards)
  14-claude-tiers.bicep       ClaudeTiers() function + PRICING_CL table and DCR
  16-budget-platform.bicep    Event Hub, Redis, Cosmos, and the two functions
  21-reconciler-metrics-rbac.bicep  Monitoring Reader for the cost reconciler
  22-team-governance.bicep    APIM team settings, KQL function, workbook, and alerts
  23-team-governance-workbook.json  team/user governance workbook

admin/
  setup-teams-governance-claude-gateway.sh/.ps1  additive Entra reconciliation

snippets/           examples and the code that runs against the platform
  01-curl-entra.sh  cURL against the Foundry Anthropic endpoint, Entra auth
  02-python-entra.py  AnthropicFoundry + DefaultAzureCredential
  05-gateway-smoke-test.sh    positive, negative, and streaming cases for the gateway
  06-claude-code-managed-settings.json  admin-pushed Claude Code settings
  07-claude-gateway-token.sh  apiKeyHelper that mints a per-user Entra token
  15-load-pricing.py          maintained Claude prices -> PRICING_CL and Redis
  17-usage-processor/         Event Hub trigger: price, count, flag over-budget
  18-budget-api/              the boolean the gateway policy asks
  19-tier-smoke-test.sh       per-tier limits, rejection reasons, fail-open
  20-cost-reconciler.py       Foundry metrics rollup + Cosmos-to-Redis budget replay

tests/              regression tests for the pricing and processor arithmetic
```

**For the recommended automated deployment, use the administrator setup below.** For
manual deployment and template-level details, [`infra/README.md`](infra/README.md)
carries the prerequisites, deployment order, and a per-template record of what has
actually been deployed and verified versus what merely compiles.

## Administrator and developer setup

The repository provides equivalent setup entry points for both operating-system
families:

| Role | macOS/Linux (Bash) | Windows or macOS (PowerShell 7.2+) |
|---|---|---|
| Administrator | [`admin/claude-gateway-setup.sh`](admin/claude-gateway-setup.sh) | [`admin/claude-gateway-setup.ps1`](admin/claude-gateway-setup.ps1) |
| Developer | [`developer/setup-claude-workstation.sh`](developer/setup-claude-workstation.sh) | [`developer/setup-claude-workstation.ps1`](developer/setup-claude-workstation.ps1) |

Run all commands from the repository root unless a command says otherwise. PowerShell
examples require `pwsh` 7.2 or later; Windows PowerShell 5.1 is not supported. The
scripts do not elevate privileges, weaken execution policy, or store access tokens in
configuration files.

### What the administrator script sets up

The administrator wrapper is the orchestrator for the Bicep templates and runtime
components in [`infra/`](infra/). It validates one configuration, resolves the Entra
identities and model deployments, and executes the resources in dependency order. This
is important because APIM must first exist to obtain its managed identity, while the
final APIM policy needs outputs from the budget platform.

During a full run, the script:

1. Validates configuration, Azure access, locations, existing Foundry deployments,
   Log Analytics, Python tooling, Bicep compilation, and optional EP1 quota.
2. Creates or reuses the gateway Entra application and service principal, including
   the `access_as_user` scope and `Claude.User` app role.
3. Bootstraps APIM from `infra/04-apim-gateway.bicep` without the final policy.
4. Deploys `infra/14-claude-tiers.bicep` for tier metadata, pricing ingestion, and the
   `ClaudeTiers()` Log Analytics function.
5. Deploys `infra/16-budget-platform.bicep`, which provisions Event Hub, Redis,
   Cosmos DB, storage, and the usage-processor and budget-api Function Apps.
6. Loads reviewed model pricing into Log Analytics and Redis, then publishes the
   Function code from `snippets/17-usage-processor/` and `snippets/18-budget-api/`.
7. When team governance is enabled, reconciles Entra groups, members, tiers, team
   roles, and profile roles additively, then deploys `infra/22-team-governance.bicep`
   for named values, the `ClaudeTeams()` function, workbook, and optional alerts.
8. Redeploys `infra/04-apim-gateway.bicep` with the final policy and actual Event Hub
   and budget API endpoints. The policy validates Entra tokens, applies user/team
   model access and token limits, checks budget state, and uses managed identity to
   call Foundry.
9. Optionally deploys the usage workbook, summary rule, retention, Grafana, and cost
   reconciliation components, based on `options` in the configuration.
10. Creates or reuses the Claude Desktop public-client registration and exports
    [`developer/claude-client-configuration.json`](developer/claude-client-configuration.json)
    as the credential-free developer handoff.

The workflow is rerunnable and does not automatically delete resources, remove Entra
assignments, purge APIM, request quota increases, or roll back resources created before
a failure. A full deployment provisions billable Azure services. Review the deployment
status and cost notes in [`infra/README.md`](infra/README.md) before approval.

### Administrator prerequisites and inputs

Before starting, the administrator needs:

- An Azure subscription, tenant, target gateway resource group, an existing Microsoft
  Foundry account with Claude deployments, and an existing Log Analytics workspace.
- Permission to deploy resources and role assignments, read/update the required Entra
  applications and groups, and publish Azure Functions.
- Azure CLI with Bicep, `jq`, Python with `pip`, and Azure Functions Core Tools v4.
  The live setup can install missing Core Tools and required Python packages where its
  supported package manager is available; dry-run mode installs nothing.
- PowerShell 7.2+ for `.ps1` scripts, or Bash on macOS/Linux. On macOS, Homebrew is
  required only when the script needs to install Functions Core Tools automatically.
- Reviewed tier limits, team profiles, model allowlists, and the per-1,000-token prices
  in [`snippets/15-load-pricing.py`](snippets/15-load-pricing.py). Set
  `options.pricesReviewed` to `true` only after this review.

[`admin/setup.example.json`](admin/setup.example.json) is the parameter reference.
The main input groups are:

| Input | Where the administrator gets it |
|---|---|
| `subscriptionId`, `tenantId` | Azure portal or `az account show` after signing in. |
| `resourceGroup` | Gateway platform resource group selected by the administrator. |
| `foundryResourceGroup`, `foundryAccountName` | Existing Foundry resource overview. |
| `workspaceResourceId`, `workspaceLocation` | Existing Log Analytics workspace overview; use the full Azure resource ID. |
| `apimName`, `namePrefix`, locations | Organization naming policy and approved Azure regions. `apimLocation` and `budgetLocation` must match. |
| `publisherEmail`, `publisherName` | APIM publisher/contact approved by the platform team. |
| `tiersConfig` | Approved `pro`, `basic`, and `lite` rate, monthly token, and monthly USD limits. |
| `teamGovernance` | Team owners, direct member UPNs, model allowlists, default tiers, aggregate profiles, rollout mode, and optional Monitor action-group IDs. |
| `models` | Existing Foundry deployment names. Leave aliases empty for discovery; ambiguous or missing families require an explicit selection. |
| `clientConfiguration` | Usually leave blank so setup creates/reuses the Desktop OIDC client and discovers the delegated scope. |
| `onboardingOutput` | Path for the generated developer handoff; normally `developer/claude-client-configuration.json`. |

Do not put passwords, API keys, access tokens, or client secrets in the JSON. See
[`admin/README.md`](admin/README.md) for every field, required Graph permissions,
regional constraints, optional stages, recovery, and governance operations.

### Run administrator setup interactively

The Bash script can start without a config file, prompt for the required Azure,
gateway, team, and member values, and create `admin/setup.local.json` with restricted
permissions. First run an offline dry run if you only want to validate the answers:

```bash
bash admin/claude-gateway-setup.sh --interactive --dry-run
```

To save the prompted configuration and perform read-only Azure/Entra/Bicep preflight:

```bash
bash admin/claude-gateway-setup.sh --interactive --stage preflight
```

Review `admin/setup.local.json`, the selected subscription/tenant, tier limits, team
membership, model aliases, and pricing. Then authorize the full deployment:

```bash
bash admin/claude-gateway-setup.sh \
  --config admin/setup.local.json \
  --interactive \
  --yes
```

PowerShell requires a seed configuration. Create a local copy of the example, replace
the subscription and tenant placeholders, then let interactive mode prompt for the
remaining deployment and governance values:

```powershell
Copy-Item ./admin/setup.example.json ./admin/setup.local.json
pwsh ./admin/claude-gateway-setup.ps1 `
  -ConfigPath ./admin/setup.local.json `
  -Interactive `
  -Stage preflight

pwsh ./admin/claude-gateway-setup.ps1 `
  -ConfigPath ./admin/setup.local.json `
  -Interactive `
  -Yes
```

Interactive PowerShell uses an effective temporary configuration for the run; maintain
the reviewed `admin/setup.local.json` as the source of truth for repeatable deployment.
Preflight reads Azure and directory state and compiles Bicep but does not deploy Azure
resources. Interactive setup can ensure required Entra application state during
preflight, so it is not an entirely offline operation.

### Run administrator setup non-interactively

For CI/CD or a repeatable operator run, copy
[`admin/setup.example.json`](admin/setup.example.json) to a protected local or pipeline
configuration, replace every placeholder, and validate it offline:

```bash
bash admin/claude-gateway-setup.sh \
  --config admin/setup.local.json \
  --non-interactive \
  --dry-run
```

```powershell
pwsh ./admin/claude-gateway-setup.ps1 `
  -ConfigPath ./admin/setup.local.json `
  -NonInteractive `
  -DryRun
```

Dry run performs no login, installation, Azure call, inference, or resource change; it
is configuration validation, not an ARM what-if. Next run the read-only preflight, then
authorize deployment only after it passes:

```bash
bash admin/claude-gateway-setup.sh --config admin/setup.local.json \
  --non-interactive --stage preflight
bash admin/claude-gateway-setup.sh --config admin/setup.local.json \
  --non-interactive --yes
```

```powershell
pwsh ./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json `
  -NonInteractive -Stage preflight
pwsh ./admin/claude-gateway-setup.ps1 -ConfigPath ./admin/setup.local.json `
  -NonInteractive -Yes
```

The `--yes`/`-Yes` switch is the explicit authorization for changes. On Bash, add
`--debug --log-file logs/claude-gateway-setup.log` for timestamped diagnostics and a
persistent terminal log. Failed ARM deployments are not automatically reversed; fix
the reported issue and rerun with the same resource names after confirming no deployment
of the same name is still running.

### Administrator handoff to developers

After a successful full run, distribute these two files through an approved internal
channel:

1. The generated `developer/claude-client-configuration.json`.
2. The matching workstation script for the developer's platform:
   `developer/setup-claude-workstation.sh` or
   `developer/setup-claude-workstation.ps1`.

The JSON provides the gateway URL, OIDC issuer/client/scopes, and validated Opus,
Sonnet, and Haiku aliases. It deliberately excludes subscriptions, resource groups,
budgets, role inventories, passwords, keys, and tokens. The administrator must also
assign the developer, or the developer's governed team group, the gateway's
`Claude.User` app role and any required tier/team/profile roles. Newly assigned roles
appear only in newly issued tokens.

### Developer workstation setup

Developers do not need Bicep parameters, Azure resource names, Foundry keys, or the
admin configuration. They obtain all gateway parameters from the administrator-provided
`claude-client-configuration.json`; they must not reconstruct the file from screenshots
or replace its values with a direct Foundry endpoint.

Developer prerequisites are Azure CLI, a browser for Entra sign-in, `jq` on macOS,
PowerShell 7.2+ on Windows, and either an existing Claude Code installation or Node.js
and npm for the install option. The `code` command is required only when asking the
script to install the VS Code extension.

From the directory containing the handoff JSON and script, validate without changing
the workstation:

```bash
bash setup-claude-workstation.sh \
  --config ./claude-client-configuration.json \
  --dry-run
```

```powershell
pwsh ./setup-claude-workstation.ps1 `
  -ConfigPath ./claude-client-configuration.json `
  -DryRun
```

Then sign in to the tenant and gateway scope encoded in the handoff, configure Claude
Code, and run one small billable smoke-test request:

```bash
bash setup-claude-workstation.sh \
  --config ./claude-client-configuration.json \
  --login \
  --smoke-test
```

```powershell
pwsh ./setup-claude-workstation.ps1 `
  -ConfigPath ./claude-client-configuration.json `
  -Login `
  -SmokeTest
```

Add `--install-claude --install-vscode` on Bash or
`-InstallClaude -InstallVSCode` on PowerShell only when those components should be
installed. The setup merges `~/.claude/settings.json`, preserves unrelated settings,
creates a timestamped backup, sets the `/anthropic` gateway URL and model aliases, and
installs a local Azure CLI token helper under `~/.claude/gateway/`. It does not save the
token. Restart Claude Code or reload VS Code after setup.

Claude Desktop is configured separately in its Gateway provider UI using the field
mapping in [`developer/README.md`](developer/README.md). Use **Access token** as exported,
then select **Test connection**. For common `401`, `403`, `429`, model, login, settings,
and rollback cases, use that same developer guide; access and quota problems must be
resolved by the gateway administrator rather than bypassing APIM.

## Per-developer budgets

[TIERED-QUOTAS.md](TIERED-QUOTAS.md) covers the follow-on problem: three developer tiers,
a personal monthly dollar budget each, at roughly 100,000 developers. APIM has no
cost-limit policy — `llm-token-limit` counts tokens, and only prompt and completion ones
— so dollars need a second mechanism. Three layers: per-tier token limits in policy, a
near-real-time budget flag backed by Redis, and an Entra app role as the manual admin
lever.

Diagram: [`images/tiered-quotas-architecture.drawio`](images/tiered-quotas-architecture.drawio).

Team governance is opt-in through `teamGovernance.mode`. Setup reconciles direct-membership
security groups and their access, tier, team, and profile app-role assignments, deploys team
configuration to the Functions and APIM, and supports `off`, `observe`, and `enforce` rollout.
See [admin/README.md](admin/README.md) for approvals and operations and
[docs/team-governance-live-validation.md](docs/team-governance-live-validation.md) before promotion.

**The tier policy and budget processor have live verification recorded in the design and code,
but cost coverage is incomplete.** The Event Hub processor includes uncached input, output and cache
reads; cache writes are missing. The workbook also omits reads. The measured sample captured about
38% of actual cost in the processor, so these are partial-cost limits, not complete dollar ceilings.
[CACHE-TOKEN-ANALYSIS.md](CACHE-TOKEN-ANALYSIS.md) records the evidence, answers the remediation design
questions, and recommends a streaming meter for accurate per-user cache-write attribution. Its local
pricing/reporting corrections have not been deployed by this review.

## About the testing

The API, SDK, and Claude Code sections were executed against a live Foundry resource on
**25 August 2026**; every response shown in the guide is real output.

The Claude Desktop section follows the official
[Microsoft](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-claude-desktop)
and [Anthropic](https://claude.com/docs/third-party/claude-desktop/foundry) deployment guides, with
screenshots of the actual configuration dialog.

**The API Management section was executed against a live BasicV2 gateway on 1 September 2026**,
fronting the same Foundry resource, with both Claude Code and Claude Desktop driving it end to end
under per-user Entra sign-in. Three results contradicted the first draft: the token audience is the
bare application ID rather than `api://<guid>`; Claude Code sends its credential in `x-api-key`
while also sending a literal `Authorization: Bearer dummy` alongside it; and `llm-token-limit` does
throttle streamed traffic — an earlier draft said otherwise, on the strength of a test whose token
bucket refilled faster than the debit could be observed.

**The usage workbook was built and deployed against that live workspace on 2 September 2026.** All
22 of its queries were executed against real data before it shipped. Getting there turned up four
things worth knowing: the gateway logs carry no caller identity at all under Entra auth; a 429 never
reaches the backend, so throttled requests are anonymous unless identity is also emitted on the
response; `upn` does not exist in a v2 access token (`preferred_username` does); and `ModelName`
arrives dated from the Claude clients but bare from cURL.

One item is unresolved: `llm-emit-token-metric` produced no custom metric namespace, so per-user
attribution relies on `GatewayLlmLogs`.

Cloud capabilities move quickly. Verify against your own deployment before building on anything here.

## Running the site locally

```bash
bundle install
bundle exec jekyll serve
```

## License

Content licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Code snippets are MIT.
