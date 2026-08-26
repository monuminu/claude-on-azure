#!/usr/bin/env bash
# Verified working against a live Foundry resource on 2026-08-25.
# Replace RESOURCE with your Foundry resource name.
set -euo pipefail

RESOURCE="${ANTHROPIC_FOUNDRY_RESOURCE:?set ANTHROPIC_FOUNDRY_RESOURCE}"
BASE="https://${RESOURCE}.services.ai.azure.com/anthropic"
TOK=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
H=(-H "content-type: application/json" -H "Authorization: Bearer $TOK" -H "anthropic-version: 2023-06-01")

echo "== baseline messages call =="
curl -s -w "\nHTTP:%{http_code}\n" "$BASE/v1/messages" "${H[@]}" -d '{
  "model": "claude-opus-5",
  "max_tokens": 100,
  "messages": [{"role":"user","content":"Reply with exactly: Claude on Foundry is live."}]
}'

echo "== structured outputs (note: output_config.format, NOT output_format) =="
curl -s -w "\nHTTP:%{http_code}\n" "$BASE/v1/messages" "${H[@]}" -d '{
  "model": "claude-opus-5",
  "max_tokens": 300,
  "output_config": {"format": {"type":"json_schema","schema":{
    "type":"object","properties":{"city":{"type":"string"}},
    "required":["city"],"additionalProperties":false}}},
  "messages": [{"role":"user","content":"Capital of France?"}]
}'

echo "== server-side web_search tool =="
curl -s -w "\nHTTP:%{http_code}\n" "$BASE/v1/messages" "${H[@]}" -d '{
  "model": "claude-opus-5",
  "max_tokens": 1500,
  "tools": [{"type":"web_search_20250305","name":"web_search"}],
  "messages": [{"role":"user","content":"Use web search to find the capital of France."}]
}'

echo "== Files API =="
curl -s -w "\nHTTP:%{http_code}\n" "$BASE/v1/files" "${H[@]}"

echo "== Message Batches API (expected: 404 api_not_supported) =="
curl -s -w "\nHTTP:%{http_code}\n" "$BASE/v1/messages/batches" "${H[@]}"
