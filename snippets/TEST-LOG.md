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
