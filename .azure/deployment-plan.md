# Per-Team Claude Model Authorization Plan

Status: Implemented (No Deployment Performed)

## Scope

Add a per-team Claude model allowlist to the existing team-governance configuration and enforce it in Azure API Management. No Azure resources will be deployed while implementing or validating this change.

## Configuration Contract

- Add `allowedModels` to each `teamGovernance.teams[]` entry.
- Permit a non-empty, unique subset of exactly:
  - `claude-sonnet-5`
  - `claude-haiku-4-5`
  - `claude-opus-5`
- Preserve backward compatibility: a missing `allowedModels` property means all three models.
- In interactive Bash and PowerShell setup, show numbered model choices and accept comma-separated multi-selection for each team.

## Gateway Behavior

1. Extend `infra/22-team-governance.bicep` to serialize each team's effective allowlist into the existing `team-governance-teams-json` APIM named value.
2. Extend team identity resolution in `infra/03-apim-claude-policy.xml` to retain the resolved team's allowlist.
3. In `teamGovernance.mode=enforce`, filter `GET /v1/models` to the resolved team's allowed models.
4. In `teamGovernance.mode=enforce`, parse `/v1/messages` with `preserveContent: true` and return an attributable HTTP 403 before budget checks or backend forwarding when the requested model is not allowed.
5. Preserve rollout semantics: `off` and `observe` do not deny or filter models; existing team identity enforcement remains unchanged.

## Implementation

1. Extend example configuration and JQ validation.
2. Add reusable terminal multi-select prompting and collect model choices per team in both admin setup entry points.
3. Serialize allowlists through module 22 and expose them to APIM policy expressions.
4. Add model discovery filtering and message-request enforcement in the APIM policy.
5. Update administrator and tier-governance documentation.
6. Add focused tests for valid/invalid allowlists, interactive selections, Bicep parameter forwarding, policy body preservation, filtered discovery, and attributable denial.

## Validation

- Bash and PowerShell syntax checks.
- `jq` configuration validation tests.
- `az bicep build --file infra/22-team-governance.bicep`.
- Focused Node gateway-script tests, then the full suite.
- Workspace diagnostics and `git diff --check`.

## Safety

- No live Azure deployment.
- No credential or secret values stored in the allowlist.
- Enforcement occurs before budget API calls, managed-identity token acquisition, token counters, and Foundry forwarding.
- Rejections include team attribution and `x-claude-denied-by: team-model-policy`.