import assert from 'node:assert/strict';
import test from 'node:test';
import { configuration, DevWorkspaceProvider } from './devworkspace-provider.mjs';

for (const env of [undefined, [{ name: 'ORCA_PAIRING_ADDRESS', value: 'old' }, { name: 'KEEP', value: 'yes' }]]) {
  test(`child startup is independent of gateway-only editor settings (env=${!!env})`, async () => {
    const template = { components: [
      { name: 'orca-injector', container: { image: 'example/editor:test' } },
      { name: 'orca-runtime', attributes: { 'controller.devfile.io/container-contribution': true },
        container: { image: 'example/editor:test', ...(env ? { env } : {}),
          endpoints: [{ name: 'orca', exposure: 'public', path: '/web-index.html' }] } }
    ] };
    let created;
    const client = { async request(method, path, body) {
      if (method === 'GET' && path.endsWith('/orca-agent-editor')) return { spec: template };
      if (method === 'POST' && body.kind === 'DevWorkspace') created = body;
      return {};
    } };
    const config = configuration({ ORCA_AGENT_NAMESPACE: 'developer-agent-devspaces',
      DEVWORKSPACE_NAMESPACE: 'developer-devspaces', DEVWORKSPACE_NAME: 'orca-workspace' });
    const provider = new DevWorkspaceProvider(config, client);
    provider.routeHost = async () => 'agent.apps.example.test';
    provider.ready = async () => ({ ready: true });
    await provider.create(provider.allocation('00000000-0000-0000-0000-000000000000'), 'https://github.com/example/repo.git');
    const runtime = created.spec.template.components[1];
    assert.equal(runtime.container.image, 'quay.io/devfile/universal-developer-image:latest');
    assert.equal(runtime.container.mountSources, true);
    assert.deepEqual(runtime.container.env.filter((item) => item.name === 'ORCA_PAIRING_ADDRESS'),
      [{ name: 'ORCA_PAIRING_ADDRESS', value: 'wss://agent.apps.example.test/' }]);
    if (env) assert.ok(runtime.container.env.some((item) => item.name === 'KEEP'));
    assert.equal(runtime.container.endpoints[0].exposure, 'internal');
    assert.equal(runtime.attributes['controller.devfile.io/container-contribution'], undefined);
    assert.equal(created.spec.template.attributes['controller.devfile.io/storage-type'], 'per-workspace');
    assert.equal(created.spec.routingClass, 'basic');
    assert.equal(template.components[1].container.image, 'example/editor:test');
    assert.equal(template.components[1].container.endpoints[0].exposure, 'public');
    assert.equal(created.spec.template.components[0].container.image, 'example/editor:test');
  });
}

const agentConfig = () => configuration({ ORCA_AGENT_NAMESPACE: 'developer-agent-devspaces',
  DEVWORKSPACE_NAMESPACE: 'developer-devspaces', DEVWORKSPACE_NAME: 'orca-workspace' });
const resource = (provider) => provider.allocation('00000000-0000-0000-0000-000000000000');
const httpError = (statusCode) => Object.assign(new Error(`HTTP ${statusCode}`), { statusCode });

test('failures before the DevWorkspace exists allow a fallback to the source host', async () => {
  const client = { async request(method, path, body) {
    if (method === 'POST' && body.kind === 'DevWorkspace') throw httpError(403);
    if (method === 'GET' && path.endsWith('/orca-agent-editor')) return { spec: { components: [] } };
    return {};
  } };
  const provider = new DevWorkspaceProvider(agentConfig(), client);
  provider.routeHost = async () => 'agent.apps.example.test';
  await assert.rejects(provider.create(resource(provider), 'https://github.com/example/repo.git'),
    (error) => error.fallback === true);
  await assert.rejects(provider.create(resource(provider), 'http://example.test/repo.git'),
    (error) => error.fallback === true);
});

test('failures after the DevWorkspace starts, or after cancellation, do not fall back', async () => {
  const client = { async request(method, path) {
    if (method === 'GET' && path.endsWith('/orca-agent-editor')) return { spec: { components: [] } };
    return {};
  } };
  const provider = new DevWorkspaceProvider(agentConfig(), client);
  provider.routeHost = async () => 'agent.apps.example.test';
  provider.ready = async () => { throw new Error('Timed out'); };
  await assert.rejects(provider.create(resource(provider), 'https://github.com/example/repo.git'),
    (error) => error.fallback === undefined);
  const cancelled = new AbortController();
  cancelled.abort();
  provider.prepare = async () => { throw new Error('Provisioning cancelled.'); };
  await assert.rejects(provider.create(resource(provider), 'https://github.com/example/repo.git', cancelled.signal),
    (error) => error.fallback === undefined);
});

test('reports why the agent namespace cannot be used', async () => {
  const provider = (template, allowed = () => true) => new DevWorkspaceProvider(agentConfig(), { async request(method, path, body) {
    if (method === 'GET') return template();
    return { status: { allowed: allowed(body.spec.resourceAttributes.resource) } };
  } });
  assert.equal(await provider(() => ({})).unavailable(), null);
  assert.match(await provider(() => { throw httpError(404); }).unavailable(), /template is missing/);
  assert.match(await provider(() => { throw httpError(403); }).unavailable(), /no access/);
  assert.match(await provider(() => ({}), (name) => name !== 'routes').unavailable(), /cannot create routes/);
});
