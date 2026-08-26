# Claude on Azure

A working guide to running Anthropic's Claude inside the Microsoft ecosystem — **Claude in Microsoft
Foundry**, **Claude Code**, and **Claude Desktop** (including how to run Cowork against your own
Azure endpoint).

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
- CCU billing, RBAC, monitoring, and a decision table for Foundry vs the direct Claude API

## Repo contents

```
index.md            the guide
images/             screenshots (tenant identifiers replaced)
snippets/
  01-curl-entra.sh  cURL against the Foundry Anthropic endpoint, Entra auth
  02-python-entra.py  AnthropicFoundry + DefaultAzureCredential
  TEST-LOG.md       what each call actually returned
```

## About the testing

The API, SDK, and Claude Code sections were executed against a live Foundry resource on
**25 August 2026**; every response shown in the guide is real output. `snippets/TEST-LOG.md` records
what each call returned, including the results that contradicted my expectations.

The Claude Desktop section follows the official
[Microsoft](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-claude-desktop)
and [Anthropic](https://claude.com/docs/third-party/claude-desktop/foundry) deployment guides, with
screenshots of the actual configuration dialog.

Cloud capabilities move quickly. Verify against your own deployment before building on anything here.

## Running the site locally

```bash
bundle install
bundle exec jekyll serve
```

## License

Content licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Code snippets are MIT.
