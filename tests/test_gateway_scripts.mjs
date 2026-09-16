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
    foundryAccountName: 'test-foundry', publisherEmail: 'admin@example.test', publisherName: 'true', apimLocation: 'centralus',
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
} else if (command.startsWith('cognitiveservices account deployment list')) {
  emit(models);
} else if (command.startsWith('resource show')) {
  emit(config.workspaceLocation);
} else if (command.startsWith('ad app show')) {
  emit(args.includes('--query') ? [config.tokenResource] : {id: 'gateway-object-id', api: {requestedAccessTokenVersion: 2, oauth2PermissionScopes: [{id: '${gatewayScope}', value: 'access_as_user', isEnabled: true}]}, identifierUris: [config.tokenResource], appRoles: [{value: 'Claude.User', isEnabled: true}]});
} else if (command.startsWith('ad app list')) {
  emit(fs.existsSync(process.env.MOCK_DESKTOP_APP) ? [JSON.parse(fs.readFileSync(process.env.MOCK_DESKTOP_APP))] : []);
} else if (command.startsWith('ad app create')) {
  const app = {appId: '${desktopClient}', id: 'desktop-object-id', displayName: option('--display-name'), signInAudience: 'AzureADMyOrg', isFallbackPublicClient: true, publicClient: {redirectUris: ['http://127.0.0.1/callback', 'http://localhost']}};
  fs.writeFileSync(process.env.MOCK_DESKTOP_APP, JSON.stringify(app));
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
  if (name === '16-budget-platform') values = {redisHost: 'test-redis.redis.cache.windows.net', processorPrincipalId: 'processor-oid', budgetApiPrincipalId: 'budget-oid', eventHubAuthorizationRuleId: '/rule/id', eventHubName: 'claude-gateway-logs', budgetApiBaseUrl: 'https://budget.test'};
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
      config.budgetLocation = 'eastus';
      writeFileSync(configPath, JSON.stringify(config));
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, env);
      assert.notEqual(result.status, 0, 'reject cross-region diagnostic Event Hub');
      assert.equal(existsSync(log), false);
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
        '04-apim-gateway', '14-claude-tiers', '16-budget-platform', 'pricing-access', '04-apim-gateway', '09-workbook', '10-claude-usage-summary-rule', '11-grafana'
      ]);
      for (const call of deployments.slice(0, 3)) assert.deepEqual(call.parameters.tiersConfig.value, config.tiersConfig);
      assert.equal(deployments[1].args[deployments[1].args.indexOf('--resource-group') + 1], 'log-rg');
      assert.equal(deployments[2].parameters.apimIdentityClientId.value, 'mi-application-id-not-object-id');
      assert.equal(deployments[0].parameters.publisherName.value, 'true', 'string parameters must not be coerced into booleans');
      assert.equal(deployments[4].parameters.budgetApiAudience.value, config.budgetApiAudience);
      assert.equal(deployments[4].parameters.eventHubAuthorizationRuleId.value, '/rule/id');
      assert.equal(calls.filter(call => call.tool === 'func').length, 2);
      const pricing = calls.find(call => call.tool === 'mock-python' && call.args[0].endsWith('15-load-pricing.py'));
      assert.ok(pricing.args.includes('--redis-host') && pricing.args.includes('--dcr-endpoint'));
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
      assert.equal(calls.filter(call => call.parameters?.apimName).length, 1, 'rerun must skip placeholder bootstrap');
      assert.equal(calls.filter(call => call.tool === 'az' && call.args.slice(0, 3).join(' ') === 'ad app create').length, 0, 'rerun must reuse Desktop client');
      writeFileSync(log, '');
      result = invoke(`admin/claude-gateway-setup.${suffix}`, args, {...env, MOCK_EXISTING: '1', MOCK_FAIL_PUBLISH: '1'});
      assert.notEqual(result.status, 0, 'publication failure must propagate');
      calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
      assert.equal(calls.filter(call => call.parameters?.apimName).length, 0, 'do not wire final gateway after publication failure');
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