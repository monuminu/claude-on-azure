import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, mkdirSync, chmodSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname ?? new URL('..', import.meta.url).pathname, import.meta.dirname ? '..' : '.');
const tenant = '11111111-1111-4111-8111-111111111111';
const audience = '22222222-2222-4222-8222-222222222222';
const desktopClient = '44444444-4444-4444-8444-444444444444';
const gatewayScope = '55555555-5555-4555-8555-555555555555';
const deployment = { properties: {
  provisioningState: 'Succeeded',
  parameters: { gatewayAudience: { value: audience }, apimName: { value: 'test-apim' } },
  outputs: { gatewayBaseUrl: { value: 'https://test-apim.azure-api.net/anthropic' }, tiers: { value: [
    { name: 'pro', tpm: 40000, tokenQuota: 350000000, costQuota: 1000 }
  ] } }
} };

for (const platform of ['bash', 'pwsh']) {
  test(`${platform}: offline export, workstation dry run, failed deployment rejection`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'gateway scripts '));
    const source = join(directory, 'deployment.json');
    const output = join(directory, 'claude-client-configuration.json');
    const target = join(directory, 'user settings');
    const invoke = (script, args) => spawnSync(platform,
      [...(platform === 'pwsh' ? ['-NoProfile', '-File'] : []), join(root, script), ...args], { encoding: 'utf8' });
    const exportArgs = platform === 'bash' ? [
      '--subscription-id', tenant, '--tenant-id', tenant, '--resource-group', 'test-rg',
      '--opus-model', 'opus', '--sonnet-model', 'sonnet', '--haiku-model', 'haiku',
      '--client-id', tenant, '--scopes', `api://${audience}/access_as_user`,
      '--deployment-file', source, '--output', output
    ] : [
      '-SubscriptionId', tenant, '-TenantId', tenant, '-ResourceGroup', 'test-rg',
      '-OpusModel', 'opus', '-SonnetModel', 'sonnet', '-HaikuModel', 'haiku',
      '-ClientId', tenant, '-Scopes', `api://${audience}/access_as_user`,
      '-DeploymentFile', source, '-Output', output
    ];
    const suffix = platform === 'bash' ? 'sh' : 'ps1';
    try {
      writeFileSync(source, JSON.stringify(deployment));
      let result = invoke(`admin/export-claude-client-configuration.${suffix}`, exportArgs);
      assert.equal(result.status, 0, result.stderr);
      const config = JSON.parse(readFileSync(output));
      assert.equal(config.gatewaySso.scopes, `api://${audience}/access_as_user`);
      assert.equal(config.gatewaySso.clientId, tenant);
      assert.equal(config.gatewayUrl, deployment.properties.outputs.gatewayBaseUrl.value);
      assert.deepEqual(Object.keys(config).sort(), ['provider', 'credentialKind', 'gatewayUrl', 'signInSessionLifetime', 'gatewaySignInFlow', 'gatewaySso', 'artifactPreviewIframeOrigin', 'customInferenceHeaders', 'streamIdleTimeout', 'models'].sort());
      result = invoke(`admin/export-claude-client-configuration.${suffix}`, exportArgs);
      assert.notEqual(result.status, 0, 'must not overwrite without force');
      result = invoke(`developer/setup-claude-workstation.${suffix}`, platform === 'bash'
        ? ['--config', output, '--claude-dir', target, '--dry-run']
        : ['-ConfigPath', output, '-ClaudeDir', target, '-DryRun']);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(existsSync(target), false, 'dry run must not create settings');
      writeFileSync(output, JSON.stringify({...config, gatewaySso: {...config.gatewaySso, scopes: `api://${config.gatewaySso.clientId}/access_as_user`}}));
      result = invoke(`developer/setup-claude-workstation.${suffix}`, platform === 'bash'
        ? ['--config', output, '--claude-dir', target, '--dry-run']
        : ['-ConfigPath', output, '-ClaudeDir', target, '-DryRun']);
      assert.notEqual(result.status, 0, 'workstation setup must reject a Desktop client ID used as the API resource');
      writeFileSync(output, JSON.stringify(config));
      writeFileSync(source, JSON.stringify({ properties: { provisioningState: 'Failed' } }));
      result = invoke(`admin/export-claude-client-configuration.${suffix}`, [...exportArgs, platform === 'bash' ? '--force' : '-Force']);
      assert.notEqual(result.status, 0);
      assert.deepEqual(JSON.parse(readFileSync(output)), config, 'failure must preserve previous export');
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });
}

for (const platform of ['bash', 'pwsh']) {
  test(`${platform}: client export prompts, screenshot fields, overrides and invalid input`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'client export '));
    const source = join(directory, 'deployment.json');
    const output = join(directory, 'client.json');
    const options = join(directory, 'options.json');
    const suffix = platform === 'bash' ? 'sh' : 'ps1';
    const args = platform === 'bash'
      ? ['--deployment-file', source, '--tenant-id', tenant, '--client-id', tenant, '--scopes', `openid profile api://${audience}/access_as_user`, '--output', output, '--force']
      : ['-DeploymentFile', source, '-TenantId', tenant, '-ClientId', tenant, '-Scopes', `openid profile api://${audience}/access_as_user`, '-Output', output, '-Force'];
    const invoke = (input, extra = []) => spawnSync(platform,
      [...(platform === 'pwsh' ? ['-NoProfile', '-File'] : []), join(root, `admin/export-claude-client-configuration.${suffix}`), ...args, ...extra],
      {encoding: 'utf8', input, timeout: 10000});
    try {
      writeFileSync(source, JSON.stringify(deployment));
      let result = invoke('\n\n\n');
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout + result.stderr, /Opus model deployment name.*claude-opus-5/);
      assert.match(result.stdout + result.stderr, /Sonnet model deployment name.*claude-sonnet-5/);
      assert.match(result.stdout + result.stderr, /Haiku model deployment name.*claude-haiku-5-4/);
      const defaults = JSON.parse(readFileSync(output));
      assert.deepEqual(defaults.models, {opus: 'claude-opus-5', sonnet: 'claude-sonnet-5', haiku: 'claude-haiku-5-4'});
      assert.equal(defaults.provider, 'gateway');
      assert.equal(defaults.credentialKind, 'interactive_sign_in');
      assert.equal(defaults.gatewaySignInFlow, 'browser');
      assert.equal(defaults.signInSessionLifetime, null);
      assert.equal(defaults.artifactPreviewIframeOrigin, null);
      assert.deepEqual(defaults.customInferenceHeaders, {});
      assert.equal(defaults.streamIdleTimeout, 300);
      assert.deepEqual(defaults.gatewaySso, {clientId: tenant, issuerUrl: `https://login.microsoftonline.com/${tenant}/v2.0`, bearerToken: 'access_token', scopes: `openid profile api://${audience}/access_as_user`, redirectPort: null, additionalRedirectReferrerHosts: []});
      assert.notEqual(defaults.gatewaySso.clientId, audience);
      result = invoke('custom-opus\ncustom-sonnet\ncustom-haiku\n');
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(JSON.parse(readFileSync(output)).models, {opus: 'custom-opus', sonnet: 'custom-sonnet', haiku: 'custom-haiku'});
      const customSettings = {signInSessionLifetime: 3600, bearerToken: 'id_token', redirectPort: 8765, additionalRedirectReferrerHosts: ['login.example.test'], artifactPreviewIframeOrigin: 'https://artifacts.example.test', customInferenceHeaders: {'x-client-team': 'engineering'}, streamIdleTimeout: 600};
      writeFileSync(options, JSON.stringify(customSettings));
      const optionArgs = platform === 'bash' ? ['--client-settings', options] : ['-ClientSettings', options];
      result = invoke('\n\n\n', optionArgs);
      assert.equal(result.status, 0, result.stderr);
      const configured = JSON.parse(readFileSync(output));
      for (const key of ['signInSessionLifetime', 'artifactPreviewIframeOrigin', 'customInferenceHeaders', 'streamIdleTimeout']) assert.deepEqual(configured[key], customSettings[key]);
      for (const key of ['bearerToken', 'redirectPort', 'additionalRedirectReferrerHosts']) assert.deepEqual(configured.gatewaySso[key], customSettings[key]);
      const before = readFileSync(output, 'utf8');
      result = invoke('');
      assert.notEqual(result.status, 0, 'EOF must fail instead of silently choosing defaults');
      assert.equal(result.error, undefined, 'EOF must not hang');
      assert.equal(readFileSync(output, 'utf8'), before);
      const clientAsResource = platform === 'bash'
        ? ['--scopes', `openid profile api://${tenant}/access_as_user`]
        : ['-Scopes', `openid profile api://${tenant}/access_as_user`];
      result = invoke('\n\n\n', clientAsResource);
      assert.notEqual(result.status, 0, 'Desktop client ID must not be used as the gateway API resource');
      assert.equal(readFileSync(output, 'utf8'), before, 'invalid client resource preserves previous export');
      for (const invalid of [{redirectPort: 65536}, {streamIdleTimeout: false}, {subscriptionId: tenant}, {customInferenceHeaders: {Authorization: 'not-a-real-token'}}]) {
        writeFileSync(options, JSON.stringify(invalid));
        result = invoke('\n\n\n', optionArgs);
        assert.notEqual(result.status, 0, JSON.stringify(invalid));
        assert.equal(readFileSync(output, 'utf8'), before, 'invalid settings preserve previous export');
      }
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });
}

function adminConfig(directory) {
  const config = JSON.parse(readFileSync(join(root, 'admin/setup.example.json')));
  Object.assign(config, {
    subscriptionId: tenant, tenantId: tenant, resourceGroup: 'test-rg', apimName: 'test-apim',
    foundryResourceGroup: 'test-foundry-rg', foundryAccountName: 'test-foundry', publisherEmail: 'admin@example.test', publisherName: 'true', apimLocation: 'centralus',
    budgetLocation: 'centralus', cosmosLocation: 'centralus', workspaceLocation: 'eastus', workbookLocation: 'eastus',
    workspaceResourceId: `/subscriptions/${tenant}/resourceGroups/log-rg/providers/Microsoft.OperationalInsights/workspaces/test-logs`,
    namePrefix: 'testbudget', gatewayAudience: audience, budgetApiAudience: '33333333-3333-4333-8333-333333333333',
    tokenResource: `api://${audience}`, pricingPublisherPrincipalId: tenant, pythonExecutable: 'mock-python',
    onboardingOutput: join(directory, 'output.json'), grafanaName: 'test-grafana', grafanaLocation: 'centralus',
    grafanaAdminPrincipalId: tenant
  });
  config.clientConfiguration = {clientId: '', scopes: '', settingsFile: ''};
  Object.assign(config.options, { pricesReviewed: true, workbook: true, summaryRule: true, grafana: true, reconcile: true });
  return config;
}

function mockEnvironment(directory, config) {
  const bin = join(directory, 'bin');
  mkdirSync(bin);
  const shim = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(process.env.MOCK_CONFIG));
const option = name => args[args.indexOf(name) + 1];
const command = args.join(' ');
const call = {tool, args, cwd: process.cwd()};
if (tool === 'az' && command.startsWith('deployment group create')) {
  call.parameters = JSON.parse(fs.readFileSync(option('--parameters').slice(1)));
}
fs.appendFileSync(process.env.MOCK_LOG, JSON.stringify(call) + '\\n');
const emit = value => console.log(typeof value === 'string' ? value : JSON.stringify(value));
const models = ['opus', 'sonnet', 'haiku'].map(family => ({name: family + '-deployment', properties: {model: {name: 'claude-' + family}}}));
if (process.env.MOCK_AMBIGUOUS) models.push({...models[0], name: 'second-opus'});
if (tool === 'mock-python') {
  if (command.includes('get_token')) emit({oid: config.pricingPublisherPrincipalId, tid: config.tenantId});
} else if (tool === 'func') {
  if (process.env.MOCK_FAIL_PUBLISH) process.exit(7);
} else if (tool === 'claude') {
  emit('mock Claude');
} else if (tool === 'curl') {
  emit(args.includes('--config') ? '200' : '401');
} else if (tool !== 'az') {
  throw new Error('Unexpected tool ' + tool);
} else if (command.startsWith('login ')) {
  // Interactive authentication is represented by a successful no-output call.
} else if (command.startsWith('account get-access-token')) {
  emit('fixture-token-never-real');
} else if (command.startsWith('account show')) {
  emit(args.includes('--query') ? config.tenantId : {tenantId: config.tenantId});
} else if (command.startsWith('account set')) {
  // Main setup selects the subscription once; tenant-scoped az ad calls inherit it.
} else if (command.startsWith('cognitiveservices account deployment list')) {
  emit(models);
} else if (command.startsWith('resource show')) {
  emit(config.workspaceLocation);
} else if (command.startsWith('ad app show')) {
  emit(args.includes('--query') ? [config.tokenResource] : {id: 'gateway-object-id', api: {requestedAccessTokenVersion: 2, oauth2PermissionScopes: [{id: '${gatewayScope}', value: 'access_as_user', isEnabled: true}]}, identifierUris: [config.tokenResource], appRoles: [{value: 'Claude.User', isEnabled: true}]});
} else if (command.startsWith('ad app list')) {
  emit(option('--display-name').startsWith('Claude Gateway') ? [] : fs.existsSync(process.env.MOCK_DESKTOP_APP) ? [JSON.parse(fs.readFileSync(process.env.MOCK_DESKTOP_APP))] : []);
} else if (command.startsWith('ad app create')) {
  const gateway = option('--display-name').startsWith('Claude Gateway');
  const app = gateway
    ? {appId: config.gatewayAudience, id: 'gateway-object-id', displayName: option('--display-name'), signInAudience: 'AzureADMyOrg'}
    : {appId: '${desktopClient}', id: 'desktop-object-id', displayName: option('--display-name'), signInAudience: 'AzureADMyOrg', isFallbackPublicClient: true, publicClient: {redirectUris: ['http://127.0.0.1/callback', 'http://localhost']}};
  if (!gateway) fs.writeFileSync(process.env.MOCK_DESKTOP_APP, JSON.stringify(app));
  emit(app);
} else if (command.startsWith('ad app permission add')) {
  // Permission addition is idempotent in the setup workflow.
} else if (command.startsWith('ad sp create')) {
  emit({appId: '${desktopClient}', id: 'desktop-service-principal-id'});
} else if (command.startsWith('ad sp list')) {
  emit([]);
} else if (command.startsWith('ad sp show')) {
  if (args.includes('--query')) emit('mi-application-id-not-object-id');
} else if (command.startsWith('resource list')) {
  emit(process.env.MOCK_EXISTING ? [{type: 'Microsoft.ApiManagement/service', name: config.apimName, location: config.apimLocation}] : []);
} else if (command.startsWith('quota show')) {
  emit({properties: {limit: {value: 10}}});
} else if (command.startsWith('quota usage show')) {
  emit({properties: {usages: {value: 0}}});
} else if (command.startsWith('apim show')) {
  emit({identity: {principalId: 'mi-object-id'}});
} else if (command.startsWith('functionapp list')) {
  emit([{name: 'processor-app', identity: {principalId: 'processor-oid'}}, {name: 'budget-app', identity: {principalId: 'budget-oid'}}]);
} else if (command.startsWith('deployment group create')) {
  const name = option('--name');
  let values = {};
  if (name === '14-claude-tiers') values = {pricingDcrEndpoint: 'https://ingestion.test', pricingDcrImmutableId: 'dcr-id'};
  if (name === '16-budget-platform') values = {redisHost: 'test-redis.redis.cache.windows.net', cosmosEndpoint: 'https://test-cosmos.documents.azure.com:443/', cosmosAccountName: 'test-cosmos', cosmosDatabaseName: 'claude', cosmosContainerName: 'usage', processorPrincipalId: 'processor-oid', budgetApiPrincipalId: 'budget-oid', eventHubAuthorizationRuleId: '/rule/id', eventHubName: 'claude-gateway-logs', budgetApiBaseUrl: 'https://budget.test'};
  if (name === '22-team-governance') values = {teamGovernanceModeNamedValue: 'team-governance-mode', teamsJsonNamedValue: 'team-governance-teams-json', profilesJsonNamedValue: 'team-governance-profiles-json', workbookId: '/workbooks/team-governance', claudeTeamsFunctionName: 'ClaudeTeams', alertsCreated: false};
  if (name === '04-apim-gateway') {
    values = {gatewayBaseUrl: 'https://test-apim.azure-api.net/anthropic', tiers: config.tiersConfig};
    fs.writeFileSync(process.env.MOCK_DEPLOYMENT, JSON.stringify({properties: {provisioningState: 'Succeeded', parameters: call.parameters, outputs: Object.fromEntries(Object.entries(values).map(([key, value]) => [key, {value}]))}}));
  }
  emit({properties: {provisioningState: 'Succeeded', outputs: Object.fromEntries(Object.entries(values).map(([key, value]) => [key, {value}]))}});
} else if (command.startsWith('deployment group show')) {
  emit(JSON.parse(fs.readFileSync(process.env.MOCK_DEPLOYMENT)));
} else if (!['group show', 'cognitiveservices account show', 'extension show', 'extension add', 'bicep build', 'provider register', 'resource wait', 'rest ', 'grafana dashboard create'].some(prefix => command.startsWith(prefix))) {
  throw new Error('Unexpected Azure command ' + command);
}
`;
  for (const tool of ['az', 'func', 'mock-python', 'claude', 'curl']) {
    const file = join(bin, tool);
    writeFileSync(file, shim);
    chmodSync(file, 0o755);
  }
  const configPath = join(directory, 'admin.json');
  const log = join(directory, 'commands.jsonl');
  writeFileSync(configPath, JSON.stringify(config));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MOCK_CONFIG: configPath, MOCK_LOG: log, MOCK_DEPLOYMENT: join(directory, 'deployed.json'), MOCK_DESKTOP_APP: join(directory, 'desktop-app.json') };
  for (const name of Object.keys(env)) {
    if (name.startsWith('ANTHROPIC_') || name.startsWith('CLAUDE_CODE_USE_')) delete env[name];
  }
  return {env, configPath, log};
}

function governanceMockEnvironment(directory, config) {
  const bin = join(directory, 'bin');
  mkdirSync(bin);
  const statePath = join(directory, 'governance-state.json');
  const log = join(directory, 'governance-commands.jsonl');
  const users = Object.fromEntries(config.teamGovernance.teams.flatMap(team => team.members).map((upn, index) => [upn, `user-${index + 1}`]));
  writeFileSync(statePath, JSON.stringify({
    roles: [{id: 'access-role', value: 'Claude.User', displayName: 'Claude User', description: 'existing', isEnabled: true, allowedMemberTypes: ['User']},
      {id: 'unrelated-role', value: 'Other.Product', displayName: 'Other', description: 'preserve', isEnabled: true, allowedMemberTypes: ['User']}],
    users,
    groups: [{id: 'group-1', displayName: config.teamGovernance.teams[0].groupDisplayName, members: [{id: 'extra-user', userPrincipalName: 'extra@example.test'}]}],
    assignments: {}
  }));
  const shim = `#!${process.execPath}
import fs from 'node:fs';
const args = process.argv.slice(2);
const command = args.join(' ');
const option = name => args[args.indexOf(name) + 1];
const statePath = process.env.GOVERNANCE_STATE;
const state = JSON.parse(fs.readFileSync(statePath));
fs.appendFileSync(process.env.GOVERNANCE_LOG, JSON.stringify(args) + '\\n');
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
const emit = value => process.stdout.write(typeof value === 'string' ? value : JSON.stringify(value));
const body = () => { const raw = option('--body'); return JSON.parse(raw.startsWith('@') ? fs.readFileSync(raw.slice(1)) : raw); };
if (command.startsWith('account show')) emit({tenantId: '${tenant}'});
else if (command.startsWith('ad app show')) emit({id: 'gateway-app-object', appRoles: state.roles});
else if (command.startsWith('ad sp show')) emit('gateway-sp-object');
else if (command.startsWith('ad group list')) {
  const filter = option('--filter');
  emit(state.groups.filter(group => filter.includes(group.displayName.replaceAll("'", "''"))));
} else if (command.startsWith('ad group create')) {
  const group = {id: 'group-' + (state.groups.length + 1), displayName: option('--display-name'), members: []};
  state.groups.push(group); save(); emit(group);
} else if (command.startsWith('ad user show')) {
  const upn = option('--id'); if (!state.users[upn]) process.exit(3); emit({id: state.users[upn], userPrincipalName: upn});
} else if (command.startsWith('ad group member list')) {
  emit(state.groups.find(group => group.id === option('--group')).members);
} else if (command.startsWith('ad group member add')) {
  const group = state.groups.find(item => item.id === option('--group'));
  const id = option('--member-id'); const upn = Object.keys(state.users).find(key => state.users[key] === id);
  group.members.push({id, userPrincipalName: upn}); save();
} else if (args[0] === 'rest' && option('--method').toUpperCase() === 'PATCH') {
  state.roles = body().appRoles; save();
} else if (args[0] === 'rest' && option('--method').toUpperCase() === 'GET') {
  const groupId = option('--url').split('/groups/')[1].split('/')[0]; emit({value: state.assignments[groupId] || []});
} else if (args[0] === 'rest' && option('--method').toUpperCase() === 'POST') {
  const assignment = body(); (state.assignments[assignment.principalId] ||= []).push(assignment); save();
} else if (command.startsWith('deployment group create')) {
  const parameterArg = option('--parameters');
  state.deploymentParameters = JSON.parse(fs.readFileSync(parameterArg.slice(1)));
  save();
  const values = {teamGovernanceModeNamedValue: 'team-governance-mode', teamsJsonNamedValue: 'team-governance-teams-json', profilesJsonNamedValue: 'team-governance-profiles-json', workbookId: '/workbooks/team-governance', claudeTeamsFunctionName: 'ClaudeTeams', alertsCreated: false};
  emit({properties: {provisioningState: 'Succeeded', outputs: Object.fromEntries(Object.entries(values).map(([key, value]) => [key, {value}]))}});
} else { process.stderr.write('Unexpected Azure command: ' + command); process.exit(4); }
`;
  const az = join(bin, 'az');
  writeFileSync(az, shim);
  chmodSync(az, 0o755);
  const configPath = join(directory, 'admin.json');
  writeFileSync(configPath, JSON.stringify(config));
  return {configPath, statePath, log, env: {...process.env, PATH: `${bin}:${process.env.PATH}`, GOVERNANCE_STATE: statePath, GOVERNANCE_LOG: log}};
}

test('bash: minimum-input live export prompts and discovers gateway settings', () => {
  const directory = mkdtempSync(join(tmpdir(), 'interactive client export '));
  const output = join(directory, 'client.json');
  try {
    const config = adminConfig(directory);
    const {env, log} = mockEnvironment(directory, config);
    writeFileSync(env.MOCK_DEPLOYMENT, JSON.stringify(deployment));
    const result = spawnSync('bash', [join(root, 'admin/export-claude-client-configuration.sh'), '--output', output], {
      encoding: 'utf8',
      env,
      input: `${tenant}\ntest-rg\n${tenant}\n\n\n\n`,
      timeout: 10000
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stderr, /Azure subscription ID/);
    assert.match(result.stderr, /Gateway resource group/);
    assert.match(result.stderr, /Desktop OIDC client ID/);
    const exported = JSON.parse(readFileSync(output));
    assert.equal(exported.gatewayUrl, deployment.properties.outputs.gatewayBaseUrl.value);
    assert.equal(exported.gatewaySso.issuerUrl, `https://login.microsoftonline.com/${tenant}/v2.0`);
    assert.equal(exported.gatewaySso.scopes, `openid profile api://${audience}/access_as_user`);
    const calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    assert.ok(calls.some(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'deployment group show'));
    assert.ok(calls.some(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad app show'));
  } finally { rmSync(directory, {recursive: true, force: true}); }
});

for (const platform of ['bash', 'pwsh']) {
  const suffix = platform === 'bash' ? 'sh' : 'ps1';
  const invoke = (script, args, env) => spawnSync(platform,
    [...(platform === 'pwsh' ? ['-NoProfile', '-File'] : []), join(root, script), ...args], {encoding: 'utf8', env});
  test(`${platform}: offline admin dry run and invalid config`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'admin dry run '));
    try {
      const config = adminConfig(directory);
      const {env, configPath, log} = mockEnvironment(directory, config);
      const args = platform === 'bash' ? ['--config', configPath, '--dry-run'] : ['-ConfigPath', configPath, '-DryRun'];
      let result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(existsSync(log), false, 'dry run must not invoke tools');
      assert.equal(existsSync(config.onboardingOutput), false);
      delete config.foundryResourceGroup;
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stderr, 'legacy config must default Foundry to the gateway resource group');
      config.foundryResourceGroup = 'test-foundry-rg';
      config.budgetLocation = 'eastus';
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.notEqual(result.status, 0, 'reject cross-region diagnostic Event Hub');
      assert.equal(existsSync(log), false);
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: interactive admin dry run builds team config without Azure calls`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'admin interactive dry run '));
    try {
      const config = adminConfig(directory);
      const {env, configPath, log} = mockEnvironment(directory, config);
      const args = platform === 'bash'
        ? [join(root, `admin/claude-gateway-setup.${suffix}`), '--config', configPath, '--interactive', '--dry-run']
        : ['-NoProfile', '-File', join(root, `admin/claude-gateway-setup.${suffix}`), '-ConfigPath', configPath, '-Interactive', '-DryRun'];
      const input = `${'\n'.repeat(11)}yes\nPlatform Team\none@example.test,two@example.test\n\n\n\n1,3\nno\n`;
      const result = spawnSync(platform, args, {encoding: 'utf8', env, input});
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stderr, /Team role \[platform-team\.regular\]/);
      assert.match(result.stderr, /1=claude-sonnet-5, 2=claude-haiku-4-5, 3=claude-opus-5/);
      assert.match(result.stdout, /DRY RUN: configuration validated/);
      assert.equal(existsSync(log), false, 'interactive dry run must not invoke tools');
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: interactive preflight creates the named gateway identity`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'admin gateway identity '));
    try {
      const config = adminConfig(directory);
      const {env, configPath, log} = mockEnvironment(directory, config);
      const args = platform === 'bash'
        ? [join(root, `admin/claude-gateway-setup.${suffix}`), '--config', configPath, '--interactive', '--stage', 'preflight']
        : ['-NoProfile', '-File', join(root, `admin/claude-gateway-setup.${suffix}`), '-ConfigPath', configPath, '-Interactive', '-Stage', 'preflight'];
      const input = `${'\n'.repeat(4)}eastus\n${'\n'.repeat(6)}no\n`;
      const result = spawnSync(platform, args, {encoding: 'utf8', env, input});
      assert.equal(result.status, 0, result.stderr);
      const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
      const createdApp = calls.find(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad app create');
      assert.equal(createdApp.args[createdApp.args.indexOf('--display-name') + 1], 'Claude Gateway - test-apim');
      assert.ok(calls.some(call => call.tool === 'az' && call.args[0] === 'rest' && call.args.includes('PATCH')));
      assert.ok(calls.some(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad sp create' && call.args.includes(config.gatewayAudience)));
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: teamGovernance config validation`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'admin team governance '));
    try {
      const config = adminConfig(directory);
      const {env, configPath} = mockEnvironment(directory, config);
      const args = platform === 'bash' ? ['--config', configPath, '--dry-run'] : ['-ConfigPath', configPath, '-DryRun'];
      let result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stderr, 'example teamGovernance config must be valid');

      for (const team of config.teamGovernance.teams) delete team.allowedModels;
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stderr, 'omitting allowedModels must allow all supported models for backward compatibility');

      delete config.teamGovernance;
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stderr, 'omitting teamGovernance must remain valid for backward compatibility');

      const mutations = [
        config => { config.teamGovernance.mode = 'bogus'; },
        config => { config.teamGovernance.teams[1].id = config.teamGovernance.teams[0].id; },
        config => { config.teamGovernance.teams[1].groupDisplayName = config.teamGovernance.teams[0].groupDisplayName; },
        config => { config.teamGovernance.teams[0].profile = 'nonexistent'; },
        config => { config.teamGovernance.teams[0].defaultUserTier = 'enterprise'; },
        config => { config.teamGovernance.teams[1].members[0] = config.teamGovernance.teams[0].members[0]; },
        config => { config.teamGovernance.profiles[1].roleValue = config.teamGovernance.profiles[0].roleValue; },
        config => { config.teamGovernance.actionGroupIds = ['/not/an/action-group']; },
        config => { config.teamGovernance.teams[0].members = []; },
        config => { config.teamGovernance.teams[0].allowedModels = []; },
        config => { config.teamGovernance.teams[0].allowedModels = ['claude-sonnet-5', 'claude-sonnet-5']; },
        config => { config.teamGovernance.teams[0].allowedModels = ['claude-unknown']; }
      ];
      for (const mutate of mutations) {
        const invalid = adminConfig(directory);
        mutate(invalid);
        writeFileSync(configPath, JSON.stringify(invalid));
        result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
        assert.notEqual(result.status, 0, `expected rejection for ${mutate}`);
      }
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: standalone team governance converges additively and fails safely`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'team governance workflow '));
    try {
      const config = adminConfig(directory);
      config.teamGovernance.mode = 'observe';
      const {env, configPath, statePath, log} = governanceMockEnvironment(directory, config);
      const manifestPath = join(directory, 'manifest.json');
      const applyArgs = platform === 'bash'
        ? ['--config', configPath, '--yes', '--manifest-output', manifestPath]
        : ['-ConfigPath', configPath, '-Yes', '-ManifestOutput', manifestPath];
      let result = invoke(`admin/setup-teams-governance-claude-gateway.${suffix}`, applyArgs, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      const manifest = JSON.parse(readFileSync(manifestPath));
      assert.equal(manifest.ambiguousMembers.length, 0);
      assert.ok(manifest.teams.every(team => team.roleAssignments.length === 4));
      let state = JSON.parse(readFileSync(statePath));
      assert.ok(state.roles.some(role => role.value === 'Other.Product'), 'unrelated app roles survive');
      assert.ok(state.groups[0].members.some(member => member.id === 'extra-user'), 'undeclared members survive');
      assert.ok(state.groups.every(group => (state.assignments[group.id] || []).length === 4), JSON.stringify(state.assignments));
      assert.equal(state.deploymentParameters.apimName.value, config.apimName);
      assert.equal(state.deploymentParameters.logAnalyticsWorkspaceId.value, config.workspaceResourceId);
      assert.equal(state.deploymentParameters.logAnalyticsWorkspaceName.value, config.workspaceResourceId.split('/').at(-1));
      assert.equal(state.deploymentParameters.workbookLocation.value, config.workbookLocation);
      assert.equal(state.deploymentParameters.teamGovernanceMode.value, config.teamGovernance.mode);
      assert.deepEqual(state.deploymentParameters.profiles.value, config.teamGovernance.profiles);
      assert.deepEqual(state.deploymentParameters.teams.value, config.teamGovernance.teams);
      assert.deepEqual(state.deploymentParameters.actionGroupIds.value, config.teamGovernance.actionGroupIds);
      const firstCalls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
      assert.ok(firstCalls.every(args => !(args[0] === 'ad' && args.includes('--subscription'))));
      assert.equal(firstCalls.filter(args => args.slice(0, 3).join(' ') === 'deployment group create').length, 1);

      writeFileSync(log, '');
      result = invoke(`admin/setup-teams-governance-claude-gateway.${suffix}`, applyArgs, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      const rerun = readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      assert.equal(rerun.filter(args => args.slice(0, 3).join(' ') === 'deployment group create').length, 1, 'direct apply redeploys module 22 idempotently');
      assert.equal(rerun.filter(args => args.includes('PATCH') || args.includes('POST') || args.slice(0, 4).join(' ') === 'ad group create --display-name' || args.slice(0, 4).join(' ') === 'ad group member add').length, 0, 'converged rerun performs no writes');

      writeFileSync(log, '');
      const checkArgs = platform === 'bash'
        ? ['--config', configPath, '--check', '--manifest-output', manifestPath]
        : ['-ConfigPath', configPath, '-Check', '-ManifestOutput', manifestPath];
      result = invoke(`admin/setup-teams-governance-claude-gateway.${suffix}`, checkArgs, env);
      assert.notEqual(result.status, 0, 'check mode reports preserved extra membership as drift');
      assert.equal(JSON.parse(readFileSync(manifestPath)).checkMode, true);
      const checkCalls = readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      assert.equal(checkCalls.filter(args => args.slice(0, 3).join(' ') === 'deployment group create').length, 0, 'check mode must not deploy module 22');
      assert.equal(checkCalls.filter(args => args.includes('PATCH') || args.includes('POST') || args.slice(0, 3).join(' ') === 'ad group create' || args.slice(0, 4).join(' ') === 'ad group member add').length, 0, 'check mode performs no writes');

      const missing = JSON.parse(readFileSync(configPath));
      missing.teamGovernance.teams[0].members[0] = 'missing@example.test';
      writeFileSync(configPath, JSON.stringify(missing));
      result = invoke(`admin/setup-teams-governance-claude-gateway.${suffix}`, applyArgs, env);
      assert.notEqual(result.status, 0, 'missing users must fail apply');

      writeFileSync(configPath, JSON.stringify(config));
      state = JSON.parse(readFileSync(statePath));
      state.groups.push({...state.groups[0], id: 'duplicate-group'});
      writeFileSync(statePath, JSON.stringify(state));
      result = invoke(`admin/setup-teams-governance-claude-gateway.${suffix}`, applyArgs, env);
      assert.notEqual(result.status, 0, 'duplicate group display names must fail');
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: mocked admin deployment, rerun, discovery and publication failure`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'admin workflow '));
    try {
      const config = adminConfig(directory);
      const {env, configPath, log} = mockEnvironment(directory, config);
      const args = platform === 'bash' ? ['--config', configPath, '--yes'] : ['-ConfigPath', configPath, '-Yes'];
      let result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      let calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
      const deployments = calls.filter(call => call.parameters);
      assert.deepEqual(deployments.map(call => call.args[call.args.indexOf('--name') + 1]), [
        '04-apim-gateway', '14-claude-tiers', '16-budget-platform', 'pricing-access', '22-team-governance', '04-apim-gateway', '09-workbook', '10-claude-usage-summary-rule', '11-grafana'
      ]);
      for (const call of deployments.slice(0, 3)) assert.deepEqual(call.parameters.tiersConfig.value, config.tiersConfig);
      assert.equal(deployments[1].args[deployments[1].args.indexOf('--resource-group') + 1], 'log-rg');
      assert.equal(deployments[2].parameters.apimIdentityClientId.value, 'mi-application-id-not-object-id');
      assert.deepEqual(deployments[2].parameters.teamGovernanceConfig.value, config.teamGovernance);
      assert.equal(deployments[0].parameters.foundryResourceGroup.value, config.foundryResourceGroup);
      assert.equal(deployments[3].parameters.foundryResourceGroup.value, config.foundryResourceGroup);
      assert.equal(deployments[3].parameters.cosmosAccountName.value, 'test-cosmos');
      assert.equal(deployments[3].parameters.enableReconciler.value, true);
      assert.equal(deployments[0].parameters.publisherName.value, 'true', 'string parameters must not be coerced into booleans');
      assert.equal(deployments[0].parameters.deployPolicy.value, false, 'bootstrap must not reference module-22 named values');
      assert.equal(deployments[4].parameters.teamGovernanceMode.value, config.teamGovernance.mode);
      assert.deepEqual(deployments[4].parameters.profiles.value, config.teamGovernance.profiles);
      assert.deepEqual(deployments[4].parameters.teams.value, config.teamGovernance.teams);
      assert.deepEqual(deployments[4].parameters.actionGroupIds.value, config.teamGovernance.actionGroupIds);
      assert.equal(deployments[5].parameters.deployPolicy.value, true);
      assert.equal(deployments[5].parameters.budgetApiAudience.value, config.budgetApiAudience);
      assert.equal(deployments[5].parameters.eventHubAuthorizationRuleId.value, '/rule/id');
      assert.equal(calls.filter(call => call.tool === 'func').length, 2);
      const pricing = calls.find(call => call.tool === 'mock-python' && call.args[0].endsWith('15-load-pricing.py'));
      assert.ok(pricing.args.includes('--redis-host') && pricing.args.includes('--dcr-endpoint'));
      const reconciler = calls.find(call => call.tool === 'mock-python' && call.args[0].endsWith('20-cost-reconciler.py'));
      assert.ok(reconciler, 'reconciliation must run when enabled');
      assert.match(reconciler.args[reconciler.args.indexOf('--resource-id') + 1], /resourceGroups\/test-foundry-rg\/providers\/Microsoft\.CognitiveServices\/accounts\/test-foundry$/);
      for (const call of calls.filter(call => call.tool === 'az' && call.args[0] === 'cognitiveservices')) {
        assert.equal(call.args[call.args.indexOf('--resource-group') + 1], config.foundryResourceGroup);
      }
      for (const [option, expected] of [
        ['--cosmos-endpoint', 'https://test-cosmos.documents.azure.com:443/'],
        ['--cosmos-database', 'claude'],
        ['--cosmos-container', 'usage'],
        ['--redis-host', 'test-redis.redis.cache.windows.net']
      ]) assert.equal(reconciler.args[reconciler.args.indexOf(option) + 1], expected);
      assert.deepEqual(JSON.parse(reconciler.args[reconciler.args.indexOf('--tiers-json') + 1]), config.tiersConfig);
      assert.deepEqual(JSON.parse(reconciler.args[reconciler.args.indexOf('--team-governance-json') + 1]), config.teamGovernance);
      const exported = JSON.parse(readFileSync(config.onboardingOutput));
      assert.equal(exported.models.opus, 'opus-deployment');
      assert.equal(exported.tiers, undefined);
      assert.equal(exported.gatewaySso.clientId, desktopClient);
      assert.ok(calls.some(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad app create'));
      assert.ok(calls.some(call => call.tool === 'az' && call.args.slice(0, 4).join(' ') === 'ad app permission add'));
      assert.ok(calls.some(call => call.tool === 'az' && call.args[0] === 'rest' && call.args.includes('PATCH')));
      writeFileSync(log, '');
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, {...env, MOCK_EXISTING: '1'});
      assert.equal(result.status, 0, result.stdout + result.stderr);
      calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
      assert.equal(calls.filter(call => call.parameters?.apimName).length, 2, 'rerun deploys governance resources and final APIM, but skips placeholder bootstrap');
      assert.equal(calls.filter(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad app create').length, 0, 'rerun must reuse Desktop client');
      writeFileSync(log, '');
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, {...env, MOCK_EXISTING: '1', MOCK_FAIL_PUBLISH: '1'});
      assert.notEqual(result.status, 0, 'publication failure must propagate');
      calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
      assert.equal(calls.filter(call => call.parameters?.apimName).length, 0, 'do not deploy governance or wire final gateway after publication failure');
      assert.ok(calls.every(call => !call.args.some(arg => ['delete', 'purge'].includes(arg))));
      const exportArgs = platform === 'bash'
        ? ['--subscription-id', tenant, '--resource-group', config.resourceGroup, '--client-id', tenant, '--opus-model', 'opus', '--sonnet-model', 'sonnet', '--haiku-model', 'haiku', '--output', config.onboardingOutput, '--force']
        : ['-SubscriptionId', tenant, '-ResourceGroup', config.resourceGroup, '-ClientId', tenant, '-OpusModel', 'opus', '-SonnetModel', 'sonnet', '-HaikuModel', 'haiku', '-Output', config.onboardingOutput, '-Force'];
      result = invoke(`admin/export-claude-client-configuration.${suffix}`, exportArgs, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      result = invoke(`admin/export-claude-client-configuration.${suffix}`, exportArgs, {...env, MOCK_AMBIGUOUS: '1'});
      assert.equal(result.status, 0, 'model selection no longer depends on discovery');
      config.tokenResource = 'api://custom-gateway';
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/export-claude-client-configuration.${suffix}`, exportArgs, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(JSON.parse(readFileSync(config.onboardingOutput)).gatewaySso.scopes, `openid profile ${config.tokenResource}/access_as_user`);
      config.models = {opus: 'opus', sonnet: 'sonnet', haiku: 'haiku'};
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, [...args, ...(platform === 'bash' ? ['--stage', 'export'] : ['-Stage', 'export'])], env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });

  test(`${platform}: workstation merge, backup, idempotence and token helper`, () => {
    const directory = mkdtempSync(join(tmpdir(), 'workstation settings '));
    try {
      const config = adminConfig(directory);
      const {env, log} = mockEnvironment(directory, config);
      const target = join(directory, 'user settings');
      mkdirSync(target);
      const settingsPath = join(target, 'settings.json');
      const original = {theme: 'light', permissions: {allow: ['Read']}, env: {KEEP_ME: 'yes', ANTHROPIC_API_KEY: 'old-key'}, forceLoginMethod: 'claudeai'};
      writeFileSync(settingsPath, JSON.stringify(original));
      writeFileSync(config.onboardingOutput, JSON.stringify({provider: 'gateway', credentialKind: 'interactive_sign_in', gatewayUrl: 'https://test-apim.azure-api.net/anthropic', gatewaySso: {clientId: tenant, issuerUrl: `https://login.microsoftonline.com/${tenant}/v2.0`, scopes: `${config.tokenResource}/access_as_user openid profile`, bearerToken: 'access_token'}, models: {opus: 'opus', sonnet: 'sonnet', haiku: 'haiku'}}));
      const args = platform === 'bash' ? ['--config', config.onboardingOutput, '--claude-dir', target] : ['-ConfigPath', config.onboardingOutput, '-ClaudeDir', target];
      let result = invoke(`developer/setup-claude-workstation.${suffix}`, args, env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.ok(!result.stdout.includes('fixture-token-never-real'));
      const merged = JSON.parse(readFileSync(settingsPath));
      assert.equal(merged.theme, original.theme);
      assert.deepEqual(merged.permissions, original.permissions);
      assert.equal(merged.env.KEEP_ME, 'yes');
      assert.equal(merged.env.ANTHROPIC_API_KEY, undefined);
      assert.equal(merged.forceLoginMethod, undefined);
      const backup = readdirSync(target).find(name => name.startsWith('settings.json.backup.'));
      assert.deepEqual(JSON.parse(readFileSync(join(target, backup))), original);
      result = invoke(`developer/setup-claude-workstation.${suffix}`, [...args, platform === 'bash' ? '--login' : '-Login'], env);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      const loginCall = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line))
        .find(call => call.tool === 'az' && call.args[0] === 'login');
      assert.equal(loginCall.args[loginCall.args.indexOf('--scope') + 1], `${config.tokenResource}/access_as_user`);
      assert.deepEqual(JSON.parse(readFileSync(settingsPath)), merged);
      result = spawnSync(platform, platform === 'bash' ? ['-c', merged.apiKeyHelper] : ['-NoProfile', '-Command', merged.apiKeyHelper], {env, encoding: 'utf8'});
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), 'fixture-token-never-real');
      result = invoke(`developer/setup-claude-workstation.${suffix}`, args, {...env, ANTHROPIC_AUTH_TOKEN: 'conflict'});
      assert.notEqual(result.status, 0);
      assert.deepEqual(JSON.parse(readFileSync(settingsPath)), merged);
      if (platform === 'bash') {
        result = invoke('developer/setup-claude-workstation.sh', [...args, '--test-only'], env);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /Smoke tests passed/);
      } else {
        const harness = join(directory, 'http-smoke.ps1');
        writeFileSync(harness, `
function Invoke-WebRequest {
  param($Uri, $Method, $ContentType, $Headers, $Body, $TimeoutSec, [switch]$SkipHttpErrorCheck)
  if ($Uri -ne 'https://test-apim.azure-api.net/anthropic/v1/messages' -or $Method -ne 'Post') { throw 'Unexpected request' }
  if ($Headers['x-api-key']) {
    if ($Headers['x-api-key'] -ne 'fixture-token-never-real' -or $Headers.Authorization -ne 'Bearer dummy') { throw 'Incorrect Claude Code headers' }
    return @{StatusCode = 200}
  }
  return @{StatusCode = 401}
}
& $env:MOCK_SETUP -ConfigPath $env:MOCK_OUTPUT -ClaudeDir $env:MOCK_CLAUDE_DIR -TestOnly
`);
        result = spawnSync('pwsh', ['-NoProfile', '-File', harness], {encoding: 'utf8', env: {...env, MOCK_SETUP: join(root, 'developer/setup-claude-workstation.ps1'), MOCK_OUTPUT: config.onboardingOutput, MOCK_CLAUDE_DIR: target}});
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /Smoke tests passed/);
      }
      assert.deepEqual(JSON.parse(readFileSync(settingsPath)), merged, 'test-only must not change settings');
    } finally { rmSync(directory, {recursive: true, force: true}); }
  });
}

test('bash: config-free interactive dry run builds config and non-interactive mode requires a file', () => {
  const localConfig = join(root, 'admin/setup.local.json');
  const original = readFileSync(localConfig, 'utf8');
  const workspaceId = `/subscriptions/${tenant}/resourceGroups/log-rg/providers/Microsoft.OperationalInsights/workspaces/test-logs`;
  const input = [
    tenant, tenant, '',
    'test-rg', 'test-foundry-rg', 'test-apim', 'centralus', 'eastus', 'eastus', 'admin@example.test', audience,
    workspaceId, 'test-foundry', 'testbudget', 'no'
  ].join('\n') + '\n';
  try {
    let result = spawnSync('bash', [join(root, 'admin/claude-gateway-setup.sh'), '--interactive', '--dry-run'],
      {encoding: 'utf8', input, timeout: 10000});
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /generated configuration was validated but not written/);
    assert.match(result.stdout, /DRY RUN: configuration validated/);
    assert.equal(readFileSync(localConfig, 'utf8'), original, 'dry run must not write generated config');

    result = spawnSync('bash', [join(root, 'admin/claude-gateway-setup.sh'), '--non-interactive', '--dry-run'],
      {encoding: 'utf8', timeout: 10000});
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Non-interactive mode requires --config FILE/);
  } finally {
    writeFileSync(localConfig, original);
  }
});

test('bash: debug mode streams timestamped output to the terminal and a log file', () => {
  const directory = mkdtempSync(join(tmpdir(), 'gateway debug '));
  const configPath = join(directory, 'setup.json');
  const logPath = join(directory, 'logs', 'setup.log');
  try {
    writeFileSync(configPath, readFileSync(join(root, 'admin/setup.local.json')));
    const result = spawnSync('bash', [join(root, 'admin/claude-gateway-setup.sh'),
      '--config', configPath, '--dry-run', '--debug', '--log-file', logPath],
    {encoding: 'utf8', timeout: 10000});

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /DEBUG: Debug logging enabled/);
    assert.match(result.stdout, /DRY RUN: configuration validated/);
    assert.equal(existsSync(logPath), true);
    const log = readFileSync(logPath, 'utf8');
    assert.match(log, /Streaming setup output to/);
    assert.match(log, /DEBUG: Debug logging enabled/);
    assert.match(log, /DRY RUN: configuration validated/);
  } finally { rmSync(directory, {recursive: true, force: true}); }
});

test('admin setup scripts install and verify missing local prerequisites', () => {
  const bash = readFileSync(join(root, 'admin/claude-gateway-setup.sh'), 'utf8');
  const powershell = readFileSync(join(root, 'admin/claude-gateway-setup.ps1'), 'utf8');

  assert.match(bash, /brew install azure-functions-core-tools@4/);
  assert.match(bash, /"\$PYTHON" -m pip install azure-identity azure-monitor-ingestion requests redis/);
  assert.ok(bash.indexOf('DRY RUN: configuration validated') < bash.indexOf('\nensure_prerequisites\n'), 'Bash dry run must exit before installing prerequisites');

  assert.match(powershell, /winget install --id Microsoft\.Azure\.FunctionsCoreTools/);
  assert.match(powershell, /choco install azure-functions-core-tools-4 --yes/);
  assert.match(powershell, /brew install azure-functions-core-tools@4/);
  assert.match(powershell, /-m pip install azure-identity azure-monitor-ingestion requests redis/);
  assert.ok(powershell.indexOf("if ($DryRun)") < powershell.indexOf('\n    Install-Prerequisites\n'), 'PowerShell dry run must exit before installing prerequisites');
});

test('interactive admin setup derives the gateway audience from a named Entra application', () => {
  const bash = readFileSync(join(root, 'admin/claude-gateway-setup.sh'), 'utf8');
  const powershell = readFileSync(join(root, 'admin/claude-gateway-setup.ps1'), 'utf8');

  for (const script of [bash, powershell]) {
    assert.match(script, /Enter a name for the gateway service principal/);
    assert.doesNotMatch(script, /Gateway audience application ID/);
    assert.match(script, /ad app create --display-name .* --sign-in-audience AzureADMyOrg/);
    assert.match(script, /ad sp create --id/);
    assert.match(script, /gatewayAudience =/);
    assert.match(script, /tokenResource =/);
  }
});

test('APIM policy preserves phase 5 governance contracts', () => {
  const policy = readFileSync(join(root, 'infra/03-apim-claude-policy.xml'), 'utf8');
  assert.match(policy, /GET \/v1\/models|\/v1\/models/);
  assert.match(policy, /Claude\.Suspended/);
  assert.match(policy, /bud:v2:/);
  assert.match(policy, /user-budget/);
  assert.match(policy, /team-budget/);
  assert.match(policy, /x-caller-team-id/);
  assert.match(policy, /x-caller-team-profile/);
  assert.match(policy, /x-team-governance-state/);
  assert.match(policy, /FromBase64String\(&quot;\{\{team-governance-teams-json\}\}&quot;\)/);
  assert.match(policy, /FromBase64String\(&quot;\{\{team-governance-profiles-json\}\}&quot;\)/);
  assert.match(policy, /preserveContent: true/);
  assert.match(policy, /team-model-policy/);
  assert.match(policy, /allowedModels/);
  assert.doesNotMatch(policy, /claude-opus-4-5/);
  assert.match(policy, /name="enforcementScope" value="user-token-limit"/);
  assert.match(policy, /name="enforcementScope" value="team-token-limit"/);
  assert.ok((policy.match(/<llm-token-limit/g) || []).length >= 4, 'user and profile-selected team token policies must coexist');
  assert.ok(policy.indexOf('context.Request.Url.Path.Contains(&quot;/models&quot;)') < policy.indexOf('Claude.Suspended&quot;) >= 0'), 'model discovery exemption must precede suspension and budget enforcement');
  assert.ok(policy.indexOf('team-model-policy') < policy.indexOf('bud:v2:'), 'team model denial must precede budget accounting');
});

test('standalone team governance scripts preserve role and safety parity', () => {
  const bash = readFileSync(join(root, 'admin/setup-teams-governance-claude-gateway.sh'), 'utf8');
  const powershell = readFileSync(join(root, 'admin/setup-teams-governance-claude-gateway.ps1'), 'utf8');
  for (const [platform, source] of [['bash', bash], ['pwsh', powershell]]) {
    assert.match(source, /Claude\.User/, `${platform} must assign gateway access`);
    assert.match(source, /Claude\.Tier\./, `${platform} must assign the configured individual tier`);
    assert.match(source, /teamRoleValue|TEAM_ROLE_VALUE/, `${platform} must assign one team role`);
    assert.match(source, /roleValue|PROFILE_ROLE_VALUE/, `${platform} must assign one profile role`);
    assert.doesNotMatch(source, /ad group member remove|--method DELETE/i, `${platform} must remain additive-only`);
  }
  assert.match(bash, /azure\(\) \{ az "\$@" --only-show-errors; \}/);
  assert.match(powershell, /& az @args --only-show-errors/);
  assert.doesNotMatch(bash, /azure\(\) \{[^}]*--subscription/);
  assert.doesNotMatch(powershell, /& az @args --subscription/);
});