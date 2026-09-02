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
- Building an **admin usage workbook** — per-developer token and cost reporting, Claude Code vs
  Claude Desktop, and who is hitting their limits, from gateway logs that start out anonymous
- Setting up the **Microsoft 365 connector** by hand in Entra when your Global Admin has no Claude
  account, and the Conditional Access limitation that will break it
- CCU billing, RBAC, monitoring, and a decision table for Foundry vs the direct Claude API

## Repo contents

```
index.md            the guide
images/             screenshots (tenant identifiers replaced)
snippets/
  01-curl-entra.sh  cURL against the Foundry Anthropic endpoint, Entra auth
  02-python-entra.py  AnthropicFoundry + DefaultAzureCredential
  03-apim-claude-policy.xml   APIM inbound policy: Entra validation + MI backend auth
  04-apim-gateway.bicep       APIM v2 + system identity + API + role assignment
  05-gateway-smoke-test.sh    positive, negative, and streaming cases for the gateway
  06-claude-code-managed-settings.json  admin-pushed Claude Code settings
  07-claude-gateway-token.sh  apiKeyHelper that mints a per-user Entra token
  08-claude-usage-workbook.json  4-page admin workbook, 26 tiles
  09-workbook.bicep           deploys the workbook against your workspace
  10-claude-usage-summary-rule.bicep  hourly rollup, for history past raw retention
  11-grafana.bicep            Azure Managed Grafana + RBAC (billable, ~$31/month)
  11a-grafana-workspace-rbac.bicep    cross-resource-group role assignment module
  12-claude-usage-grafana-dashboard.json  16-panel Grafana dashboard
  13-import-grafana-dashboard.sh  imports it (no ARM path for AMG dashboards)
```

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
