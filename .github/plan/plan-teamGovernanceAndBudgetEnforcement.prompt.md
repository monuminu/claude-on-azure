## Plan: Team Governance and Budget Enforcement

Extend the deployed per-user Claude governance platform with team-scoped identity, synchronous token controls, near-real-time dollar controls, reporting, and operational guardrails. The implementation adds `infra/22-team-governance.bicep` for Azure-owned team governance resources, while idempotent Bash/PowerShell Graph scripts own Entra app roles, groups, membership, and enterprise-app assignments. Rollout is opt-in: deploy and observe first, reconcile identity and accounting, then switch to enforcement.

### Requirements

- REQ-001: Define FDPO Team 1 and FDPO Team 2 as direct-membership Entra security groups.
- REQ-002: Assign each team one runtime team identity, one team budget profile, and one default individual tier through gateway app roles.
- REQ-003: Enforce individual TPM, monthly tokens, and monthly cost limits.
- REQ-004: Enforce aggregate team TPM, monthly tokens, and monthly cost limits.
- REQ-005: Reject an authorized caller in enforcement mode when zero or multiple team roles are present.
- REQ-006: Preserve streaming, managed identity, replay protection, and current fail-open budget-service behavior.
- REQ-007: Provide team/user auditability, utilization reporting, alerts, reconciliation, and administrative guardrails.
- REQ-008: Introduce governance without disrupting the existing live gateway through off, observe, and enforce modes.

### Confirmed Configuration

- `fdpo-team-1`: members `nvelayudhan_microsoft.com#EXT#@fdpo.onmicrosoft.com`, `navg_microsoft.com#EXT#@fdpo.onmicrosoft.com`, and `sombanerjee_microsoft.com#EXT#@fdpo.onmicrosoft.com`; individual tier `pro`; team profile `power`; aggregate 500,000 TPM, 700,000,000 monthly tokens, and USD 2,500 monthly cost.
- `fdpo-team-2`: members `vrm_microsoft.com#EXT#@fdpo.onmicrosoft.com` and `mrajguru_microsoft.com#EXT#@fdpo.onmicrosoft.com`; individual tier `basic`; team profile `regular`; aggregate 100,000 TPM, 175,000,000 monthly tokens, and USD 1000 monthly cost.
- Enforce exactly one `Claude.Team.*` role and exactly one `Claude.TeamProfile.*` role per caller. Observe mode records violations but preserves individual-only behavior; enforce mode returns 403.
- Use app-role claims at runtime. Do not use Graph calls or `groups` claims in APIM; group overage and nested-group semantics make those unsafe.

### Target Contracts

- Canonical config in `admin/setup.example.json` and deployment config: `teamGovernance.mode`, `profiles[]`, and `teams[]`. Each profile has `name`, `roleValue`, `tpm`, `tokenQuota`, and `costQuota`; each team has stable `id`, `displayName`, `groupDisplayName`, `teamRoleValue`, `profile`, `defaultUserTier`, and direct `members`.
- Gateway app roles: existing `Claude.User`; individual roles `Claude.Tier.Pro`, `Claude.Tier.Basic`, and optional `Claude.Tier.Lite`; team roles `Claude.Team.FDPO1`, `Claude.Team.FDPO2`; profile roles `Claude.TeamProfile.Power`, `Claude.TeamProfile.Regular`; existing `Claude.Suspended` where enabled.
- APIM headers: existing `x-caller-oid`, `x-caller-upn`, `x-caller-tier`; add `x-caller-team-id`, `x-caller-team-profile`, and `x-team-governance-state` to backend/response diagnostics.
- Budget API: replace the user-only lookup with `GET /v2/budget/{teamId}/{oid}`. Return 200 when both scopes are allowed, 402 when either is exhausted, `x-budget-scope: user|team|both`, and non-200/non-402 as unknown so APIM fails open.
- Redis: `mtd:<month>:user:<oid>`, `mtd:<month>:team:<teamId>`, `over:user:<oid>`, `over:team:<teamId>`, and existing pairing/pricing/replay keys. Keep compatibility reads for legacy `over:<oid>` during migration.
- Cosmos usage documents: add `teamId`, `teamProfile`, `userTier`, `userCostQuota`, and `teamCostQuota`; retain `/oid` partitioning and correlation ID idempotency.

## Implementation Steps

### Phase 1: Configuration and Contract Foundation

1. Define and validate the canonical team schema in `admin/setup.example.json` and `admin/validate-config.jq`.
   - Require unique team IDs, group names, team roles, and profile names.
   - Require positive limits and valid tier/profile references.
   - Reject duplicate members across teams, unknown individual tiers, unsafe IDs, and missing members.
   - Require `mode` to be `off`, `observe`, or `enforce`; default existing deployments to `off` for backward compatibility.
2. Add matching parsing and parameter forwarding tests in `tests/test_gateway_scripts.mjs` for Bash and PowerShell.
3. Document the config contract and ownership: source-controlled limits, Graph-owned identity objects, ARM-owned Azure resources.

Tasks:
- [x] T001 [Plan:1.1] Extend `admin/setup.example.json` with the confirmed FDPO profiles and teams.
- [x] T002 [P] [Plan:1.1] Extend `admin/validate-config.jq` with structural, uniqueness, cross-reference, membership, and mode validation.
- [x] T003 [P] [Plan:1.2] Add valid and invalid team configuration fixtures to `tests/test_gateway_scripts.mjs`.
- [x] T004 [Plan:1.3] Document the canonical contract in `admin/README.md` and `infra/README.md`.

### Phase 2: Entra Provisioning and Drift Control

4. Add idempotent `admin/configure-claude-teams.sh` and `.ps1` workflows using Microsoft Graph through the authenticated Azure CLI context.
   - Preflight tenant, gateway application object, service principal, required Graph privileges, user existence, and Entra licensing for group app assignment.
   - Upsert required app-role definitions without changing existing role IDs or deleting unrelated roles.
   - Create or resolve security groups by an immutable recorded object ID after first creation; never trust display name alone when duplicates exist.
   - Reconcile direct membership for the declared users; nested groups are unsupported and must fail validation.
   - Assign each group to `Claude.User`, one `Claude.Team.*`, one `Claude.TeamProfile.*`, and one default `Claude.Tier.*` role on the gateway enterprise application.
   - Support `--check`, `--plan`, and explicit `--apply`; never remove undeclared members or assignments unless a separate destructive flag is approved.
   - Emit a machine-readable manifest containing user, group, role, and assignment object IDs for audits and subsequent checks.
5. Add a read-only reconciliation mode to detect missing users, duplicate team membership, ambiguous team/profile roles, stale role assignments, and config-to-directory drift.
6. Keep Graph credentials out of configuration; use delegated operator identity or workload identity with least-privilege Graph permissions and Entra audit logs.

Tasks:
- [ ] T005 [P] [Plan:2.4] Implement the Bash Graph provisioning/check workflow in `admin/configure-claude-teams.sh`.
- [ ] T006 [P] [Plan:2.4] Implement behaviorally equivalent PowerShell in `admin/configure-claude-teams.ps1`.
- [ ] T007 [Plan:2.4] Integrate opt-in team stages into `admin/claude-gateway-setup.sh` and `.ps1` after gateway app validation and before policy enforcement.
- [ ] T008 [Plan:2.5] Add mocked idempotency, ambiguity, missing-user, direct-membership, and no-destructive-default tests to `tests/test_gateway_scripts.mjs`.
- [ ] T009 [Plan:2.6] Document required Graph permissions, approval boundaries, fresh-token behavior, and audit evidence in `admin/README.md`.

### Phase 3: New Azure Team Governance Bicep Module

7. Create `infra/22-team-governance.bicep` with a narrow ARM ownership boundary.
   - Inputs: existing APIM name, Log Analytics workspace resource ID/location, optional action group IDs, `teamGovernanceMode`, profiles, and teams.
   - Reference existing APIM with `existing`; do not redeploy APIM, Redis, Cosmos, Function Apps, groups, users, or app roles.
   - Create `team-governance-mode` and profile limit named values: `team-profile-<name>-tpm`, `team-profile-<name>-token-quota`, and `team-profile-<name>-cost-quota`.
   - Create a saved Log Analytics function `ClaudeTeams()` containing stable team metadata and quotas for reports. Do not use it for enforcement.
   - Deploy a dedicated team-governance workbook from `infra/23-team-governance-workbook.json` showing user/team utilization, denials, ambiguous identities, processor lag, and profile distribution.
   - Optionally create scheduled query alerts when action group IDs are supplied: budget fail-open exceptions, missing/ambiguous team identity, processor lag, missing prices, and 70/85/95/100 percent utilization events emitted by the processor.
   - Use deterministic resource names, current stable API versions verified with Bicep schema, secure parameters only where secrets exist, resource tags, descriptions, and outputs for named values, function, workbook, and alerts.
8. Keep runtime configuration in existing owners: `04` consumes APIM named values/policy; `16` passes serialized team config to both Functions. Do not let module 22 replace Function App settings because ARM site configuration updates can erase unrelated settings.
9. Add Bicep lint/build and ARM what-if checks before deployment. Pin API versions; avoid preview versions unless a required capability lacks a stable version.

Tasks:
- [ ] T010 [Plan:3.7] Create `infra/22-team-governance.bicep` with named values, saved KQL function, workbook, optional alerts, tags, and outputs.
- [ ] T011 [P] [Plan:3.7] Create `infra/23-team-governance-workbook.json` using the existing workbook resource-ID replacement pattern.
- [ ] T012 [Plan:3.8] Add `teamGovernanceConfig` to `infra/16-budget-platform.bicep` and pass it as `CLAUDE_TEAM_GOVERNANCE` to processor and budget API settings.
- [ ] T013 [Plan:3.8] Update `infra/04-apim-gateway.bicep` diagnostics to capture the new team/governance headers and ensure the policy can reference module-22 named values.
- [ ] T014 [Plan:3.9] Add deployment of module 22 and output validation to both admin setup scripts, ordered before the updated APIM policy deployment.

### Phase 4: Team-Aware Accounting and Combined Budget API

10. Extend `snippets/17-usage-processor/function_app.py`.
   - Parse and validate `CLAUDE_TEAM_GOVERNANCE` once at startup without network calls.
   - Capture team ID/profile from GatewayLogs and park them in the existing identity half of the correlation join.
   - Price each completed request once, write the expanded Cosmos ledger record, then atomically claim replay protection and increment user/team Redis cost counters with one Lua script or transactional equivalent.
   - Set user and team over-budget flags with month-end TTL based on individual tier and team profile quotas.
   - Emit structured threshold events once per scope/month/threshold to support alerts without high-cardinality Azure metrics.
   - Preserve tier aggregate reporting and cache-write undercount disclosure.
11. Extend `snippets/18-budget-api/function_app.py` with the combined v2 endpoint.
   - Validate route IDs conservatively.
   - Read legacy user flag, v2 user flag, and team flag in one Redis pipeline.
   - Return the combined status and scope header; retain managed-identity Easy Auth, Data Reader access, one-second Redis timeout, and fail-open logging.
   - Keep v1 during rollout and remove it only after policy rollback windows expire.
12. Add focused Python tests covering user-only exhaustion, team-only exhaustion, both, neither, malformed identity, unknown profile, replay, month expiry, atomic increments, threshold deduplication, legacy compatibility, and Redis failure.

Tasks:
- [ ] T015 [Plan:4.10] Refactor accounting keys/config parsing and add team identity capture in `snippets/17-usage-processor/function_app.py`.
- [ ] T016 [Plan:4.10] Add atomic user/team accounting, flags, structured thresholds, and expanded Cosmos records.
- [ ] T017 [P] [Plan:4.11] Add the combined v2 contract and compatibility behavior in `snippets/18-budget-api/function_app.py`.
- [ ] T018 [Plan:4.12] Expand `tests/test_cache_accounting.py` for team accounting and budget outcomes.

### Phase 5: APIM Dual-Scope Enforcement

13. Extend `infra/03-apim-claude-policy.xml` while preserving current authentication and streaming order.
   - Parse exact team and profile role prefixes from the already materialized `roles` array; require one of each and map to stable lowercase IDs.
   - In `off`, skip team behavior. In `observe`, stamp state and continue individual controls for invalid/missing team identity. In `enforce`, return attributable 403 for zero/multiple team or profile roles.
   - Stamp team/governance headers on inbound, outbound, return-response, and on-error paths.
   - Replace the existing budget callout with one combined v2 lookup and one cache key `bud:v2:<teamId>:<oid>` because only one `cache-lookup-value` is permitted per policy section.
   - Preserve two-second timeout and fail-open semantics for unavailable budget infrastructure; distinguish 403 responses with `x-claude-denied-by: user-budget|team-budget|identity`.
   - Keep existing individual tier branches and add a second `llm-token-limit` selected by team profile with counter key `team:<profile>:<teamId>`.
   - Set an `enforcementScope` variable immediately before each token policy so on-error can attribute user versus team token denials.
   - Validate experimentally that two token policies charge completed streamed traffic to both counters and that rejection by the second policy does not corrupt the first counter.
14. Preserve the current model-discovery exemption and ensure `/v1/models` does not consume/check team budget.
15. Add policy lint/deploy tests for off, observe, enforce, valid roles, missing roles, duplicate roles, user/team cost flags, and user/team token limits.

Tasks:
- [ ] T019 [Plan:5.13] Add team/profile resolution, mode handling, and diagnostic headers to `infra/03-apim-claude-policy.xml`.
- [ ] T020 [Plan:5.13] Upgrade the single budget check to the combined v2 user/team verdict.
- [ ] T021 [Plan:5.13] Add profile-selected aggregate `llm-token-limit` branches and denial attribution.
- [ ] T022 [Plan:5.14] Preserve and test model discovery and existing suspension behavior.
- [ ] T023 [Plan:5.15] Extend script/static policy tests and add a live APIM validation checklist.

### Phase 6: Reporting, Operations, and Documentation

16. Deploy `ClaudeTeams()` and workbook views for team MTD cost/tokens, limits, percentage utilization, members, denials by scope, and drill-down from team to user.
17. Update the reconciler design to rebuild both user and team Redis counters/flags from Cosmos, validate each ledger row's team mapping against the immutable request-time team ID, and report historic membership changes rather than rewriting history.
18. Define operating procedures for onboarding, transfer between teams, tier/profile change, emergency suspension, monthly reset, exception approval, Redis rebuild, and rollback from enforce to observe.
19. Update `README.md`, `TIERED-QUOTAS.md`, `infra/README.md`, and `admin/README.md` with architecture, limits, ownership, latency/overspend window, Graph prerequisites, deployment order, and troubleshooting.

Tasks:
- [ ] T024 [P] [Plan:6.16] Complete workbook queries and alert queries against diagnostic and structured Function logs.
- [ ] T025 [Plan:6.17] Extend `snippets/20-cost-reconciler.py` and its Bicep settings to rebuild team counters and flags.
- [ ] T026 [P] [Plan:6.18] Document governance runbooks and approval responsibilities.
- [ ] T027 [Plan:6.19] Update architecture and deployment documentation across the four existing guides.

### Phase 7: Deployment, Validation, and Promotion

20. Pre-deployment gates:
   - Run config tests, Python tests, XML parse/static checks, `az bicep build` for changed templates, and ARM what-if for modules 16, 22, and 04.
   - Verify APIM v2 support, Azure regions, EP1 quota, Redis capacity, managed identities/RBAC, Log Analytics workspace, action groups, Graph permissions, and all four user object IDs.
21. Deploy in dependency order without enforcement:
   - Provision/reconcile app roles and groups in plan/check mode, then apply with captured manifest.
   - Deploy Function code and module 16 configuration while old v1 API/policy remains valid.
   - Deploy module 22 named values/function/workbook/alerts.
   - Deploy updated gateway module/policy with `team-governance-mode=observe`.
22. Observe and reconcile:
   - Obtain fresh tokens for all four users and verify expected `roles`, team ID, profile, and individual tier.
   - Send streamed requests from every user; correlate APIM GatewayLogs, GatewayLlmLogs, Event Hub processing, Redis user/team counters, Cosmos ledger, budget API verdict, workbook, and alerts.
   - Run replay tests and compare summed user costs with team costs within pricing tolerance.
   - Run controlled user/team cost and token exhaustion tests in an isolated test profile with low limits.
   - Maintain observe mode for an agreed burn-in period and require zero ambiguous identities, zero unexplained drift, healthy processor lag, and successful Redis reconstruction before promotion.
23. Promote by changing only the named value to `enforce`, obtaining fresh tokens, and rerunning valid/missing/ambiguous identity and all four denial-path smoke tests.
24. Rollback by setting mode to `observe`; retain individual enforcement and v1 budget compatibility. If Functions regress, restore previous packages/policy while leaving additive headers, roles, and ledger fields intact.

Tasks:
- [ ] T028 [Plan:7.20] Execute local validation and capture Bicep what-if outputs for approval.
- [ ] T029 [Plan:7.21] Apply Entra and Azure changes in observe mode following the dependency order.
- [ ] T030 [Plan:7.22] Execute end-to-end identity, streaming, accounting, replay, exhaustion, reconciliation, workbook, and alert validation.
- [ ] T031 [Plan:7.23] Record promotion approval and switch the governance named value to enforce.
- [ ] T032 [Plan:7.24] Execute and document rollback rehearsal before production sign-off.

## Relevant Files

- `infra/22-team-governance.bicep` - new team governance named values, KQL function, workbook, and alerts.
- `infra/23-team-governance-workbook.json` - new team/user governance dashboard.
- `infra/03-apim-claude-policy.xml` - runtime identity, combined budget, and dual token enforcement.
- `infra/04-apim-gateway.bicep` - policy deployment and diagnostic header capture.
- `infra/16-budget-platform.bicep` - serialized team config for existing Functions.
- `snippets/17-usage-processor/function_app.py` - atomic user/team accounting and ledger enrichment.
- `snippets/18-budget-api/function_app.py` - combined user/team budget verdict.
- `snippets/20-cost-reconciler.py` - Redis reconstruction for both scopes.
- `admin/setup.example.json`, `admin/validate-config.jq` - canonical team contract and validation.
- `admin/configure-claude-teams.sh`, `admin/configure-claude-teams.ps1` - new Graph-owned identity provisioning.
- `admin/claude-gateway-setup.sh`, `admin/claude-gateway-setup.ps1` - opt-in orchestration.
- `tests/test_cache_accounting.py`, `tests/test_gateway_scripts.mjs` - focused automated coverage.

## Azure Best-Practice Decisions

- Separate ARM/Bicep ownership from Microsoft Graph ownership; use `existing` resources and narrow module contracts.
- Use managed identities and data-plane least privilege; no Redis access keys or Graph secrets in app settings.
- Keep Redis off the durable-record role; Cosmos remains the rebuild source and request ledger.
- Keep budget infrastructure failures fail-open for availability, but alert loudly; synchronous APIM token ceilings remain the safety backstop.
- Avoid high-cardinality custom metrics; use structured logs, KQL functions, and workbooks.
- Keep API versions pinned and validate with Bicep lint/build plus what-if before deployment.
- Preserve public network settings in this iteration because changing them requires VNet integration/private endpoints for both Function Apps; track private networking as a separate security hardening project.
- Prefer Premium Redis for production resilience if budget allows; validate current Standard capacity and document rebuild RTO if retained.

## Verification

1. `node --test tests/test_gateway_scripts.mjs` passes Bash and PowerShell orchestration/config cases.
2. Python accounting tests pass all individual/team limit, replay, expiry, compatibility, and failure cases.
3. Changed Bicep templates compile and lint; resource-group what-if shows only intended additive/configuration changes.
4. Entra reconciliation proves each listed user belongs directly to exactly one declared team group and receives expected access, team, profile, and individual-tier app roles.
5. In observe mode, all four users complete streamed calls and APIM logs show expected team/profile/tier headers without team denials.
6. Every completed request produces one Cosmos row and exactly one increment to its user counter and team counter; replay does not change totals.
7. Controlled tests independently produce user budget, team budget, user token, team token, and identity denials with correct status/header attribution.
8. Budget API/Redis outage permits traffic under token controls and triggers fail-open alerts.
9. Workbook and alerts reflect both teams, drill down to members, and agree with Redis/Cosmos totals.
10. Mode-only rollback to observe restores access while preserving individual controls.

## Scope Boundaries

Included: the two FDPO teams, their four direct users, group/app-role provisioning, profile-driven team limits, per-user and team enforcement, accounting, alerts, reporting, reconciliation, documentation, and staged rollout.

Excluded: zero-overspend synchronous dollar reservations, nested group support, client changes, APIM product/subscription-key tiering, changing the existing Cosmos `/oid` partition key, replacing Redis with a durable database, private endpoint/VNet migration, active-active multi-region counter aggregation, and automatic destructive removal of Entra memberships.

## Requirement Mapping

| REQ | Plan Items | Evidence |
|---|---|---|
| REQ-001 | 1, 4, 5 | team config and Graph group/member manifest |
| REQ-002 | 1, 4, 13 | app-role definitions, assignments, and token claims |
| REQ-003 | 10, 11, 13 | user Redis keys, budget v2, existing user token policy |
| REQ-004 | 7, 10, 11, 13 | profile named values, team Redis keys, team token policy |
| REQ-005 | 13, 15, 22 | mode-aware identity validation and 403 tests |
| REQ-006 | 10, 11, 13, 14 | streaming tests, managed identity, replay, fail-open tests |
| REQ-007 | 5, 7, 16-19 | reconciliation, workbook, alerts, audit/runbooks |
| REQ-008 | 1, 20-24 | off/observe/enforce rollout and rollback evidence |
