# Claude Client Configuration

Obtain `claude-client-configuration.json` from your administrator along with the appropriate
setup script. The admin generates it using [Export Claude Client Configuration](../admin/README.md#export-claude-client-configuration).
Do not replace its values with screenshot examples or a Foundry API key.

This single handoff contains settings for Claude Desktop, the Claude Code VS Code
extension, and the Claude Code CLI. It contains no gateway deployment inventory.
The scripts configure CLI/VS Code; Desktop uses the UI mapping below.

## Claude Desktop

Open Desktop's inference-provider Gateway configuration and enter these values.
This is a field mapping, not a claim that Desktop can import this JSON directly.

| Desktop field | Exported value |
|---|---|
| Inference provider | `provider`: `gateway` (Gateway) |
| Credential kind | `credentialKind`: `interactive_sign_in` (Interactive sign-in) |
| Gateway base URL | `gatewayUrl` |
| Sign-in session lifetime (seconds) | `signInSessionLifetime`; leave blank for null |
| Gateway sign-in flow | `gatewaySignInFlow`: `browser` |
| OIDC Client ID | `gatewaySso.clientId` |
| OIDC Issuer URL | `gatewaySso.issuerUrl` |
| Bearer token selection | `gatewaySso.bearerToken`: Access token or ID token |
| Scopes | `gatewaySso.scopes` |
| Redirect port | `gatewaySso.redirectPort`; leave blank for null |
| Additional redirect referrer hosts | `gatewaySso.additionalRedirectReferrerHosts`; leave blank for an empty array |
| Artifact preview iframe origin | `artifactPreviewIframeOrigin`; leave blank for null |
| Custom inference headers | `customInferenceHeaders`; leave blank for an empty object |
| Stream idle timeout (seconds) | `streamIdleTimeout`; default 300 |
| Model deployment names | `models.opus`, `models.sonnet`, `models.haiku` in the corresponding model fields |

The repository gateway uses **Access token**, even if Desktop initially shows
ID token as its default. Use the exported choice. Ask your administrator to verify
the Desktop registration's redirects, delegated API permissions, consent, and
your `Claude.User` role. Select **Test connection** after configuring Desktop;
it may make a billable inference request. The exporter does not test Desktop login.

## CLI and VS Code

Follow the workstation steps below. Desktop-only session lifetime, sign-in flow,
OIDC client ID/bearer selection, redirect options, artifact origin, headers, and
stream idle timeout are not applied to CLI/VS Code. Those clients share Claude Code
user settings and obtain access tokens from Azure CLI. The helper derives the
tenant from the OIDC issuer and API resource from the configured scopes, not from
the Desktop client ID.

## Prerequisites

- An assigned `Claude.User` application role on the gateway. Optional tier roles
  are managed by your administrator, not by the workstation script.
- Azure CLI and a browser available for Entra login.
- macOS: Bash and `jq`. Windows: PowerShell **7.2+** (`pwsh`), not Windows PowerShell 5.1.
- Claude Code already installed, or Node.js/npm for the optional installation flag.
- For VS Code extension installation, the `code` command on PATH. Install into
  VS Code Insiders separately with `code-insiders --install-extension anthropic.claude-code`.

Use an approved installer/package manager for these tools. The scripts do not
elevate privileges or relax PowerShell execution policy.

## macOS

From the directory containing your script and handoff JSON:

```bash
bash setup-claude-workstation.sh --config ./claude-client-configuration.json --dry-run
bash setup-claude-workstation.sh --config ./claude-client-configuration.json --login --smoke-test
```

Add `--install-claude` to install the npm package and `--install-vscode` to install
the VS Code extension. These flags are explicit and are not enabled by default.

## Windows / PowerShell

```powershell
./setup-claude-workstation.ps1 -ConfigPath ./claude-client-configuration.json -DryRun
./setup-claude-workstation.ps1 -ConfigPath ./claude-client-configuration.json -Login -SmokeTest
```

Add `-InstallClaude` or `-InstallVSCode` as needed. Run these commands in PowerShell
7.2+; follow your organization's script-signing/execution policy requirements.

## What Changes

The scripts merge user settings in `~/.claude/settings.json`, preserving unrelated
settings and making a timestamped backup before replacement. Use `--claude-dir`
or `-ClaudeDir` for another location, or set `CLAUDE_CONFIG_DIR` consistently for
both setup and subsequent Claude sessions.

They set the `/anthropic` gateway URL and Opus/Sonnet/Haiku aliases, then create a
token helper and a local client-configuration copy under the Claude settings `gateway/` folder.
The helper acquires a gateway-scoped Entra token using Azure CLI and prints only
the token for Claude Code to consume. No token is saved in settings or the JSON.
Helper results are cached by Claude Code for 45 minutes.

Conflicting user-setting API keys, auth tokens, direct Foundry/Bedrock/Vertex
provider selectors, and forced login settings are removed. Conflicting inherited
environment variables cause setup to stop; unset them in your shell/profile and
retry. Organization-managed and project settings may still override user settings.
Restart Claude Code or reload VS Code after setup.

`--dry-run` / `-DryRun` validates and previews without writes, login, installations,
or network calls. `--test-only` / `-TestOnly` runs smoke checks without changing
settings or installing software. Smoke checks require the gateway role and make
one small billable inference request; they expect unauthenticated **401** and
authenticated **200**, using Claude Code's `x-api-key` plus dummy Authorization
header pattern. They do not prove budget accounting or tier exhaustion behavior.

## Troubleshooting

- **No token / expired login:** rerun with `--login` / `-Login`. Authentication stays
  in Azure CLI's credential store; never paste access tokens into the config.
- **401:** confirm tenant, gateway token resource, v2 audience, and `Claude.User`
  assignment with the administrator. Allow time for role propagation.
- **403 / 429:** ask the administrator to inspect suspension, dollar budget, token
  quota, or rate-limit diagnostics. Do not bypass the gateway.
- **Model not found:** request a fresh export after the administrator checks the
  deployed aliases. Missing Haiku requires an explicit admin-selected fallback.
- **Settings unchanged at runtime:** inspect higher-precedence managed/project
  settings and shell environment. The scripts configure Claude Code; configure
  Desktop separately using the field mapping above.
- **Rollback:** close Claude Code, restore the desired settings backup, and remove
  the generated `gateway/` folder only when no settings still refer to its helper.

The PowerShell scripts have been exercised using PowerShell on macOS with isolated
mocks; native Windows execution and live Azure inference remain environment-specific
checks. Treat the JSON as trusted internal configuration even though it contains
no credentials.