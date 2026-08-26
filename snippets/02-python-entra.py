"""Claude in Microsoft Foundry — Entra ID (keyless) auth.

Verified 2026-08-25 against a resource with disableLocalAuth=true.

    pip install -U anthropic azure-identity
    az login
    export ANTHROPIC_FOUNDRY_RESOURCE=<your-resource-name>
"""
import os

from anthropic import AnthropicFoundry
from azure.identity import DefaultAzureCredential, get_bearer_token_provider

RESOURCE = os.environ["ANTHROPIC_FOUNDRY_RESOURCE"]

token_provider = get_bearer_token_provider(
    DefaultAzureCredential(), "https://ai.azure.com/.default"
)

# NOTE: `resource` and `base_url` are MUTUALLY EXCLUSIVE, and the SDK reads
# ANTHROPIC_FOUNDRY_RESOURCE / ANTHROPIC_FOUNDRY_BASE_URL from the environment
# automatically. The Foundry portal's generated sample passes base_url=... —
# which raises ValueError if ANTHROPIC_FOUNDRY_RESOURCE is also set (as it will
# be if you configured Claude Code). Pass ONE of them. `resource` is cleaner.
client = AnthropicFoundry(
    azure_ad_token_provider=token_provider,
    resource=RESOURCE,
)

message = client.messages.create(
    # This is the DEPLOYMENT name, not the model ID. They match by default,
    # but diverge the moment someone names a deployment "claude-prod".
    model="claude-opus-5",
    max_tokens=1024,
    messages=[{"role": "user", "content": "What is the capital of France?"}],
)

print(message.content)
print("inference_geo:", message.usage.model_dump().get("inference_geo"))
