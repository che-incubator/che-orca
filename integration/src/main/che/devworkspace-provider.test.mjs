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
