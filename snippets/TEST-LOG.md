---
layout: page
title: "Test log"
description: "What each call against a live Microsoft Foundry resource actually returned."
---

# Verification log — Claude on Microsoft Foundry

Resource names below are placeholders. Region: swedencentral.
Endpoint base: `https://{resource}.services.ai.azure.com/anthropic/v1/*`

## Deployments present

| Deployment | Model | Version | SKU | Capacity |
|---|---|---|---|---|
| claude-opus-5 | claude-opus-5 | 2 | GlobalStandard | 40 |
| claude-sonnet-5 | claude-sonnet-5 | 1 | GlobalStandard | 20 |
| claude-opus-4-5 | claude-opus-4-5 | 20251101 | GlobalStandard | 40 |
| claude-haiku-4-5 | claude-haiku-4-5 | 20251001 | GlobalStandard | 20 |

## Finding 1 — this resource is keyless (Entra-only)

```
$ az cognitiveservices account keys list -n <resource> -g <rg>
ERROR: (BadRequest) Failed to list key. disableLocalAuth is set to be true
```

`disableLocalAuth: true` removes API-key auth entirely. The Foundry portal's **Key** field is
therefore unavailable on this resource — the only path is Entra ID. Good enterprise default; worth
calling out in the blog as the posture to aim for.

## Finding 2 — Entra ID auth works, HTTP 200

```
TOK=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl https://<resource>.services.ai.azure.com/anthropic/v1/messages \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $TOK" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-5","max_tokens":100,
       "messages":[{"role":"user","content":"Reply with exactly: Claude on Foundry is live."}]}'
```

Response (verbatim):

```json
{"model":"claude-opus-5","id":"msg_011CeNuMuP2qSHCggPsDdSmK","type":"message","role":"assistant",
 "content":[{"type":"text","text":"Claude on Foundry is live."}],
 "stop_reason":"end_turn",
 "usage":{"input_tokens":25,"output_tokens":13,"service_tier":"standard","inference_geo":"global"}}
```
HTTP 200.

## Finding 3 — CORRECTION: `output_format` is deprecated

First structured-outputs attempt returned 400 on **both** deployments:

```json
{"type":"error","error":{"type":"invalid_request_error",
 "message":"output_format: This field is deprecated. Use 'output_config.format' instead."}}
```

This is a **parameter-name deprecation, not a hosting restriction**. Any blog post using
`output_format` is out of date. Correct form is `output_config.format`.

## Finding 4 — the planned "Azure-hosted returns 400" test did not reproduce for these two features

Anthropic's docs state that deployments *hosted on Azure* reject structured outputs, server-side
tools, MCP connector, Agent Skills, and the Files API with `400 Bad Request`. Against this resource:

| Feature | claude-opus-5 (v2) | claude-sonnet-5 (v1) |
|---|---|---|
| `output_config.format` structured output | **200** — returned `{"city":"Paris"}` | **200** — returned `{"city": "Paris"}` |
| `web_search_20250305` server-side tool | **200** — real `server_tool_use` + `web_search_tool_result` | **200** |

Both features work on both deployments. Hosting option was unknown at this point — resolved below,
and the full feature matrix is in Finding 5.

**Azure's deployment metadata does not expose the hosting option** — `properties.model` returns
`{"format":"Anthropic","name":"claude-opus-5","version":"2","publisher":null,"source":null}`.
The ARM API is not a usable source for this.

### Hosting option RESOLVED from the portal UI

Foundry portal → Build → Models → select deployment → **Edit** → **Model version settings**. The
version dropdown labels each version with its hosting option (screenshot `03`):

- version **1** → **"Hosted on Anthropic infrastructure"**
- version **2** → **"Hosted on Azure"**

So `claude-opus-5` (v2) **is** Hosted on Azure, and `claude-sonnet-5` (v1) is Hosted on Anthropic.
The portal is the only reliable place to read this.

Corroborating signal: `usage.inference_geo` was `"global"` on opus-5 (Azure-hosted) and
`"not_available"` on sonnet-5 (Anthropic-hosted).

## Finding 5 — documented Azure-hosted restrictions, measured

All run against `claude-opus-5`, **confirmed Hosted on Azure**, on 25 Aug 2026:

| Feature | Docs say (Azure-hosted) | Measured | Detail |
|---|---|---|---|
| Structured outputs (`output_config.format`) | 400 | **200** | returned `{"city":"Paris"}` |
| Server-side tool — `web_search` | 400 | **200** | real `server_tool_use` + `web_search_tool_result` |
| Server-side tool — `code_execution` | 400 | **400** | `code_execution not supported in your workspace.` |
| MCP connector | 400 | **400*** | `Connection error while communicating with MCP server.` — the parameter was **accepted** and a connection to my dummy URL was attempted. Not a platform-level rejection. |
| Files API (`GET /v1/files`) | 400 | **200** | `{"data":[],"next_page":null}` |
| Message Batches API | unsupported on Foundry | **404** | `api_not_supported` — matches docs |

**Conclusion for the blog:** the Azure-hosted feature gap is materially *narrower* than the docs
describe. Structured outputs, web search, and the Files API all work. `code_execution` fails, and
its error reads like a workspace-enablement issue rather than a hosting restriction. The MCP
connector was not rejected.

Publish this as a dated, measured observation — "here is what this returned on 25 Aug 2026" — not as
"the docs are wrong". Capabilities plainly shipped after the doc text was written.

## Finding 6 — API-key auth visibly disabled in the portal

The deployment Details pane renders **"API Key authentication is disabled"** in place of the key
field (screenshot `01`), matching `disableLocalAuth: true`. The portal's generated Python sample
defaults to `AnthropicFoundry` + `DefaultAzureCredential` + `get_bearer_token_provider`.

## Finding 7 — Claude Code on Foundry works with Entra, no key

```bash
export CLAUDE_CODE_USE_FOUNDRY=1
export ANTHROPIC_FOUNDRY_RESOURCE=<resource>
export ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-5'
export ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-5'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5'
claude -p "Reply with exactly: Claude Code is running on Microsoft Foundry." --model claude-opus-5
```

Output: `Claude Code is running on Microsoft Foundry.` (Claude Code v2.1.233)

No API key set anywhere — auth came from the `az login` default credential chain.

## Finding 8 — the unpinned-alias gotcha REPRODUCES

With `ANTHROPIC_DEFAULT_OPUS_MODEL` unset:

```
$ claude -p "say hi" --model opus
The model claude-opus-4-6 is not available on your foundry deployment.
Try --model to switch to claude-opus-4-5, or ask your admin to enable this model.
```

Confirms the documented behaviour: the bare `opus` alias resolves to Claude Code's built-in Foundry
default (Opus 4.6), which is not deployed here. Claude Code fails with a clear, actionable message
rather than an opaque error. **Pin every alias before rolling out to a team.**

## Finding 9 — the portal's generated Python sample crashes in a Claude Code environment

`anthropic==0.122.0`. The Foundry portal Details tab generates:

```python
client = AnthropicFoundry(azure_ad_token_provider=token_provider, base_url=endpoint)
```

With `ANTHROPIC_FOUNDRY_RESOURCE` exported (required for Claude Code):

```
ValueError: base_url and resource are mutually exclusive
```

The SDK auto-reads `ANTHROPIC_FOUNDRY_RESOURCE` / `ANTHROPIC_FOUNDRY_BASE_URL` from the environment,
so an explicit `base_url` collides with the env-supplied resource. Pass exactly one.

Working form (verified — returned "The capital of France is **Paris**...", `inference_geo: global`):

```python
client = AnthropicFoundry(azure_ad_token_provider=token_provider, resource=RESOURCE)
```

## Screenshots captured

All sanitized **at the DOM level before capture** (tenant strings replaced in the live page), so no
unsanitized originals were ever written to disk. Resource → `contoso-foundry`, user →
`admin@contoso.com`, RG → `rg-foundry`, GUIDs → zeros, avatar blurred.

| File | Shows |
|---|---|
| `01-deployments-list.png` | 4 Claude deployments; "API Key authentication is disabled" |
| `02-hosting-option-hosted-on-azure.png` | Edit pane, Model version 2 = Hosted on Azure, TPM slider |
| `03-hosting-options-dropdown.png` | v1 Hosted on Anthropic infrastructure / v2 Hosted on Azure |
| `04-playground-claude-opus-5.png` | Foundry playground on claude-opus-5 |
| `05-anthropic-model-catalog.png` | Public Anthropic catalog, 12 models, 1000k context (signed out) |

**Not captured:** Claude Code `/status`. It is unavailable in `-p` mode
(`/status isn't available in this environment.`) and I did not fake it. The Foundry-specific error in
Finding 8 is stronger evidence of the connection anyway.

## Finding 10 — streaming and extended thinking on Foundry

**Streaming works.** `"stream": true` returns proper SSE (`message_start`, `content_block_start`,
`ping`, ...) from the Foundry endpoint.

**Extended thinking works, but the old parameter shape is rejected on Opus 5:**

```json
{"thinking": {"type": "enabled", "budget_tokens": 1024}}
```
```
400 "thinking.type.enabled" is not supported for this model.
    Use "thinking.type.adaptive" and "output_config.effort" to control thinking.
```

Working form (verified, HTTP 200, thinking block present):

```json
{"thinking": {"type": "adaptive"}, "output_config": {"effort": "high"}}
```

Model-generation change, not Foundry-specific — but it breaks ported code.

## Finding 11 — the `az apim` CLI gaps are real (verified locally, no Azure resources touched)

Checked against **azure-cli 2.81.0**. These are the three CLI claims in Part 5, and all three hold.

**The v2 SKUs cannot be created from the CLI.**

```
$ az apim create --help | grep -A2 'sku-name'
    --sku-name  : The sku of the api management instance.  Allowed values: Basic,
                  Consumption, Developer, Isolated, Premium, Standard.  Default: Developer.
```

No `BasicV2`, `StandardV2`, or `PremiumV2`. Since the `llm-*` policies only understand the Anthropic
Messages schema on a v2 tier, `az apim create` cannot produce a usable instance for this design at
all. Bicep, ARM, or portal.

**There is no `az apim api policy`.** Subgroups under `az apim api` are `operation`, `release`,
`revision`, `schema`, `versionset` — no policy. The only policy command anywhere in the tree:

```
$ az apim graphql resolver --help
Subgroups:
    policy : Manage Azure API Management GraphQL API's Resolvers Policies.
```

GraphQL resolvers only. API, product, and global policies need ARM/Bicep or REST.

## Finding 12 — `04-apim-gateway.bicep` compiles, and the `&quot;` escaping survives it

```
$ bicep build 04-apim-gateway.bicep --outfile /tmp/apim-gateway.json
$ echo $?
0
```

No errors, no warnings. Nine resources emitted at the expected API versions.

Two things worth recording about how Bicep handles the policy file:

**`loadTextContent` hoists the file into a variable**, so the policy resource's `value` compiles to
`"[variables('$fxv#0')]"` — 21 characters. That looks like truncation and isn't; the variable holds
the full 5,983-character document.

**The `&quot;` entities decode correctly.** Parsing the embedded XML and reading attributes back
gives exactly the expressions APIM expects:

```
<set-variable value=...>     @(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("oid", "unknown"))
<llm-token-limit counter-key=...>  @((string)context.Variables["callerOid"])
<dimension value=...>        @((string)context.Variables["callerOid"])
```

So the document is well-formed in transit and the runtime sees real quotes. Element-content
expressions (the `<value>` blocks) keep raw quotes and are fine as-is.

**Still unverified:** compiling is not deploying. Nothing here proves APIM accepts the policy, that
the managed identity can reach Foundry, or that any of it returns a completion.

## Part 5 — APIM gateway, executed 1 September 2026

Deployed against a real gateway rather than a fresh one: **a BasicV2 instance in East US**
in front of the same Foundry resource used above (swedencentral). Cross-region on
purpose — it works. APIM's system-assigned identity was granted **Cognitive Services User** scoped
to the Foundry account, and an Entra app registration (`claude-gateway-api`) exposes the audience
and a `Claude.User` app role.

## Finding 11 — the `az apim` CLI gaps are real

azure-cli 2.81.0.

```
$ az apim create --help | grep -A2 'sku-name'
    --sku-name  : The sku of the api management instance.  Allowed values: Basic,
                  Consumption, Developer, Isolated, Premium, Standard.  Default: Developer.
```

No `BasicV2`/`StandardV2`/`PremiumV2`. Since the `llm-*` policies only understand the Anthropic
schema on a v2 tier, `az apim create` cannot produce a usable instance for this design.

`az apim api` has subgroups `operation`, `release`, `revision`, `schema`, `versionset` — no policy.
The only policy command in the tree is `az apim graphql resolver policy` (GraphQL resolvers only).
The policy in this repo was therefore applied with `az rest --method PUT` against
`.../apis/claude-anthropic/policies/policy?api-version=2024-05-01`.

## Finding 12 — the Bicep compiles and the `&quot;` escaping survives it

`bicep build` exits 0, no warnings, nine resources. `loadTextContent` hoists the policy into a
variable, so the resource's `value` compiles to `"[variables('$fxv#0')]"` — 21 characters. That
looks like truncation and isn't. Parsing the embedded XML and reading attributes back yields the
decoded expressions APIM expects, e.g. `@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("oid", "unknown"))`.

## Finding 13 — CORRECTION: the audience is the bare app ID, not `api://<guid>`

The app registration was created with `requestedAccessTokenVersion: 2`. Decoding a real token:

```
aud                  11111111-2222-3333-4444-555555555555
iss                  https://login.microsoftonline.com/<tenant>/v2.0
ver                  2.0
oid                  aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
roles                ['Claude.User']
scp                  user_impersonation
```

**`aud` is the bare application ID.** Only v1 tokens carry the `api://<guid>` identifier URI. The
first draft of `03-apim-claude-policy.xml` listed `api://{{...}}` and would have rejected every
request. Corrected to a named value holding the raw GUID.

`roles` and `oid` are both present, so app-role gating and per-user counter keys work as designed.

Note: `az account get-access-token --resource api://<appId>` only works after adding the Azure CLI
client (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) to the app's `preAuthorizedApplications`. The scope
must exist before it can be pre-authorized — a single combined PATCH fails with
`Property api.preAuthorizedApplications.delegatedPermissionIds has a Permission Id that cannot be
found in the AppPermissions sets.` Two PATCHes, in order.

## Finding 14 — `resource="https://ai.azure.com"` WORKS

This was the largest documented unknown in Part 5. No Microsoft doc shows this value inside
`authentication-managed-identity`. It is correct:

```
$ curl https://<apim>.azure-api.net/anthropic/v1/messages \
    -H "Authorization: Bearer $TOK" -H "anthropic-version: 2023-06-01" ...
{"model":"claude-opus-5","id":"msg_011CecTcdgAiiowvdS3HsREo","type":"message",
 "content":[{"type":"text","text":"through the gateway."}],
 "usage":{"input_tokens":20,"output_tokens":8,...}}
HTTP:200
```

APIM minted a token with its own managed identity, Foundry accepted it, and the gateway returned a
real completion. Negative cases behave as configured:

| Case | Result |
|---|---|
| Valid token + `Claude.User` role | **200** |
| No token | **401** `Unauthorized. Access token is missing or invalid.` |
| Token for `https://ai.azure.com` (wrong audience) | **401**, identical message |

The wrong-audience 401 is indistinguishable from the no-token 401. Nothing in the response mentions
audiences. That is exactly the failure that reads as "the gateway is broken."

## Finding 15 — Claude Code sends `Authorization: Bearer dummy` AND `x-api-key`

The single most useful result of this exercise. Claude Code with `ANTHROPIC_BASE_URL` +
`apiKeyHelper` first failed through the gateway:

```
$ claude --settings ./settings.json -p "..." --model claude-opus-5
Failed to authenticate. API Error: 401 Unauthorized. Access token is missing or invalid.
```

That message is the policy's own `failed-validation-error-message`, so the request reached APIM and
was rejected there. Pointing `ANTHROPIC_BASE_URL` at a local echo server showed why (claude-cli
2.1.233, `@anthropic-ai/sdk` 0.112.1):

```
POST /v1/messages?beta=true
Authorization: Bearer dummy
x-api-key: eyJ0eXAiOiJKV1QiLC...<2096 chars>
anthropic-version: 2023-06-01
```

It sends **both**: a literal `Bearer dummy` placeholder in `Authorization`, and the real
`apiKeyHelper` output in `x-api-key`. So a `set-header ... exists-action="skip"` normalisation never
fires — `Authorization` already exists, it just contains the word `dummy` — and
`validate-azure-ad-token` dutifully rejects it.

Fix, verified: override only when `x-api-key` is present, which leaves Desktop traffic alone.

```xml
<choose>
  <when condition="@(context.Request.Headers.ContainsKey(&quot;x-api-key&quot;))">
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + context.Request.Headers.GetValueOrDefault("x-api-key", ""))</value>
    </set-header>
  </when>
</choose>
```

After redeploying, both header shapes return 200:

```
Desktop-style (Authorization only)              HTTP:200
Claude Code style (dummy Authorization + x-api-key)  HTTP:200
```

And end to end:

```
$ claude --settings ./settings.json -p "Reply with exactly: Claude Code is running through APIM."
Claude Code is running through APIM.
```

## Finding 16 — `llm-token-limit` does not debit the bucket on streamed Anthropic traffic

Non-streamed accounting is exact. Streamed accounting is not merely "estimated" — it is absent.

```
stream call 1: x-tokens-consumed: 14 | x-tokens-remaining: 20000
stream call 2: x-tokens-consumed: 14 | x-tokens-remaining: 20000
stream call 3: x-tokens-consumed: 14 | x-tokens-remaining: 20000
non-stream   : x-tokens-consumed: 75 | x-tokens-remaining: 19925
  actual usage from body: input 15 output 60 total 75
```

Three consecutive streamed calls each report the prompt-token count only, and `remaining` never
moves off the full 20000 bucket. The non-streamed call that follows debits exactly 75 — its own
usage and nothing else — proving the three streams contributed zero.

Note that even the 14 reported prompt tokens are not charged: `consumed` shows them, `remaining`
does not move. So this is not "completion tokens are missed" — nothing is debited at all.

**Mechanism unknown.** An earlier draft of this entry claimed the cause was that response headers
are emitted before the body streams, so completion tokens don't exist at header time. That explains
a stale header, not an undebited bucket — a limiter could charge the counter after the stream ends.
And calls 2 and 3 were issued seconds after call 1 finished, with the bucket still full. Retracted:
the behaviour is measured, the cause is not established.

**Consequence for a rollout:** Claude Code and Claude Desktop always stream. A `tokens-per-minute`
limit on this API therefore does not constrain them at all. Treat `llm-token-limit` as effective for
non-streaming application traffic, and do capacity control for the interactive clients at the
Foundry deployment's TPM instead. Reconcile spend against Foundry's own usage metrics.

Streaming itself passes through correctly with `buffer-response="false"` — `Content-Type:
text/event-stream`, events relayed as produced (`message_start`, `content_block_start`, `ping`,
`content_block_delta`...).

## Still not verified

- Claude Desktop in Gateway mode with OIDC. The app registration is configured for it (public
  client, redirect `http://127.0.0.1/callback`, `Claude.User` role), and the Desktop-style header
  shape returns 200, but no Desktop client has actually signed in through this gateway.
- The four-minute idle timeout on a long `effort: max` turn.
- `llm-emit-token-metric` dimension caps at scale — a single-user test cannot reach the 100-value
  limit.

## Finding 17 — Foundry does not implement `GET /v1/models`, so Desktop auto-discovery is unavailable

Claude Desktop's Gateway mode probes `GET /v1/models` to populate its model list. Foundry has no
such endpoint — direct, bypassing APIM entirely:

```
$ curl https://<resource>.services.ai.azure.com/anthropic/v1/models -H "Authorization: Bearer $TOK"
{"error":{"code":"api_not_supported","message":"Requested API is currently not supported",
          "details":"Requested API is currently not supported"}}
HTTP:404
```

Same `api_not_supported` family as the Message Batches API (Finding 5). **Consequence:** behind a
Foundry-backed gateway you must set `inferenceModels` explicitly in the Desktop configuration.
Auto-discovery is not an option you are choosing not to use — it cannot work.

Defining the `GET /v1/models` operation on the APIM API is still worth doing: without it APIM
answers the probe with its own generic `{"statusCode":404,"message":"Resource not found"}`, whereas
with it the probe reaches Foundry and returns the meaningful `api_not_supported` body.

## Finding 18 — APIM can serve `/v1/models` itself, and Desktop discovery then works

Claude Desktop surfaces the Finding 17 gap directly at launch:

```
Model discovery — Gateway /v1/models returned HTTP 404.
404 https://<apim>.azure-api.net/anthropic/v1/models
```

Rather than switching discovery off on every device, a `return-response` in the inbound policy
answers the probe from the gateway. Placed after `validate-azure-ad-token`, so the list is still
behind the `Claude.User` app role. Verified:

```
GET  /v1/models   (valid token)   200  {"data":[{"type":"model","id":"claude-opus-5",...}],...}
POST /v1/messages (valid token)   200  (regression — unaffected)
GET  /v1/models   (no token)      401  (still gated)
```

This is the better answer for a fleet: the model list becomes a central policy edit instead of an
MDM push to every device, which is the whole argument for having a gateway.

## Finding 19 — token accounting DOES work, via `GatewayLlmLogs` — and it is exact on streams

This corrects the pessimistic reading of Finding 16.

**The trap first.** `az monitor diagnostic-settings create` defaults to legacy **Azure diagnostics**
mode, which writes everything to the `AzureDiagnostics` table. The dedicated
`ApiManagementGatewayLlmLog` table is only populated in **resource-specific** mode
(`--export-to-resource-specific true`). Querying the dedicated table returned 0 rows for over an
hour and looked like a broken pipeline; the data was in `AzureDiagnostics` the whole time.

```kusto
AzureDiagnostics
| where Category == "GatewayLlmLogs"
| project TimeGenerated, promptTokens_d, completionTokens_d, totalTokens_d,
          isStreamCompletion_b, modelName_s
```

**The result.** A marker pair with known values, fired at 11:13:10 UTC:

| Sent | Body usage | Logged prompt/completion/total | `isStreamCompletion_b` |
|---|---|---|---|
| non-streamed | 14 in / 100 out | 14 / 100 / **114** | `False` |
| streamed | 15 in / 100 out | 15 / 100 / **115** | `True` |

Both exact. **`GatewayLlmLogs` captures streamed completion tokens accurately**, which
`llm-token-limit` does not (Finding 16). So the gateway *can* give you per-request, per-model token
accounting for Claude Code and Claude Desktop traffic — through logs, not through the limit policy.

Rows for non-inference requests carry zeros with an empty `modelName_s`: `/v1/models` served by the
policy responder, 401s, and a `HEAD /anthropic/api/hello` probe Claude Desktop issues at startup.
That is correct behaviour, not missing data.

**Corrected guidance:** use `GatewayLlmLogs` for cost attribution and chargeback. Use
`llm-token-limit` only for non-streaming application traffic, and cap the interactive clients at the
Foundry deployment TPM.

## Open item — `llm-emit-token-metric` produced no custom metric namespace

After ~40 minutes and several hundred requests through the gateway, the APIM resource still reports
only `Microsoft.ApiManagement-service` from `az monitor metrics list-namespaces`. No `claude-gateway`
namespace, and `list-definitions --namespace claude-gateway` returns nothing.

Configuration looks correct: the policy applies cleanly, requests return 200, and the service has an
`azuremonitor` logger of type `azureMonitor` with a service-level diagnostic at 100% sampling.

Not yet resolved. Candidate explanations, none confirmed:
- custom-metric ingestion or namespace-discovery latency beyond what was waited
- a BasicV2 constraint (the policy reference banner and the policy matrix disagree on tier support)
- an additional prerequisite not documented in the policy reference

Do not claim in the article that per-user token metrics work until this is settled. `llm-token-limit`
header output (`x-tokens-consumed`) is verified working — that is a different policy.

Note this is now the ONLY unresolved observability gap — `GatewayLlmLogs` works (Finding 19), so
per-user attribution is achievable regardless. Keyed on `CorrelationId`, LLM log rows join to
`GatewayLogs` rows for URL, method and status.

## Finding 20 — resource-specific mode, and the Bicep shape for it

Recreated the diagnostic setting with `--export-to-resource-specific true`, which sets
`logAnalyticsDestinationType: Dedicated`. Data then lands in `ApiManagementGatewayLlmLog` with
proper column names (`PromptTokens`, `CompletionTokens`, `TotalTokens`, `IsStreamCompletion`,
`ModelName`) rather than the `promptTokens_d` style of the `AzureDiagnostics` catch-all.

In Bicep the equivalent is `logAnalyticsDestinationType: 'Dedicated'` on
`Microsoft.Insights/diagnosticSettings`. Two schema notes recorded while writing it:

- `Microsoft.ApiManagement/service/apis/diagnostics` accepts `largeLanguageModel`, but Bicep's type
  definition does not know the property and emits **BCP037**. The ARM API accepts it (verified by
  direct PUT) and it survives into the compiled template, so `#disable-next-line BCP037` above the
  property is the right handling. Confirm it is still present in the compiled ARM afterwards —
  suppressing a warning and silently dropping the property would look identical at build time.
- `largeLanguageModel.requests.messages` and `.responses.messages` are rejected with
  `Invalid field ... specified`. Only `{ logs: 'enabled' }` is accepted — which is also what you
  want, since body capture buffers responses and buffering breaks SSE.

`04-apim-gateway.bicep` now provisions the `azuremonitor` logger, the API diagnostic, and the
diagnostic setting, and compiles with zero warnings.

### Confirmed against the dedicated table

After switching to `Dedicated` and firing marker pairs, `ApiManagementGatewayLlmLog` populated with
exact counts. Every marker matched its response body:

| Sent | Logged prompt / completion / total | `IsStreamCompletion` |
|---|---|---|
| opus-5 non-streamed, 14 in / 90 out | 14 / 90 / **104** | `False` |
| haiku-4-5 streamed, 12 in / 49 out | 12 / 49 / **61** | `True` |
| opus-5 non-streamed, 15 in / 70 out | 15 / 70 / **85** | `False` |
| opus-5 streamed | 14 / 70 / **84** | `True` |

Streamed rows carry full completion tokens, confirming Finding 19 on the dedicated table as well.
Streamed rows also report the fully-versioned deployment name (`claude-haiku-4-5-20251001`).

Interleaved Claude Desktop traffic logged correctly alongside — e.g. 26 / 1085 / 1111 on opus-5.
Zero-token rows with an empty `ModelName` are the `/v1/models` responder and 401s, as expected.
