import https from 'node:https';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const SA = '/var/run/secrets/kubernetes.io/serviceaccount';
const CONTROLLER_NAMESPACE = 'orca.eclipse.org/controller-namespace';
const CONTROLLER = 'orca.eclipse.org/controller';
const DW = '/apis/workspace.devfile.io/v1alpha2';
const ROUTES = '/apis/route.openshift.io/v1';
const NAME = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;

// ORCA_AGENT_* comes from the agent environment ConfigMap that the provisioner mounts into
// workspaces in the user namespace. The DevWorkspace Operator injects DEVWORKSPACE_*.
export function configuration(env = process.env) {
  const namespace = env.ORCA_AGENT_NAMESPACE;
  if (!namespace) return null;
  const source = env.DEVWORKSPACE_NAMESPACE;
  const controller = env.DEVWORKSPACE_NAME;
  if (!NAME.test(namespace) || namespace.length > 63 || !source || !controller) {
    throw new Error('Agent environments need ORCA_AGENT_NAMESPACE and the DevWorkspace identity.');
  }
  if (namespace === source) throw new Error('Agent workspaces require a separate namespace.');
  return {
    namespace,
    labels: { [CONTROLLER_NAMESPACE]: source, [CONTROLLER]: controller },
    runtimeClass: env.ORCA_AGENT_RUNTIME_CLASS || '',
    timeoutMs: 300_000,
    template: 'orca-agent-editor'
  };
}

// Only the controlling workspace's ServiceAccount has RBAC in the agent namespace.
export class KubernetesClient {
  constructor(env = process.env) {
    const host = env.KUBERNETES_SERVICE_HOST;
    this.origin = `https://${host?.includes(':') ? `[${host}]` : host}:${env.KUBERNETES_SERVICE_PORT_HTTPS || '443'}`;
  }

  credentials() {
    return {
      ca: readFileSync(`${SA}/ca.crt`),
      headers: { Authorization: `Bearer ${readFileSync(`${SA}/token`, 'utf8').trim()}` }
    };
  }

  request(method, path, body, signal) {
    return new Promise((resolve, reject) => {
      const data = body === undefined ? undefined : JSON.stringify(body);
      const credentials = this.credentials();
      const request = https.request(new URL(path, this.origin), {
        ...credentials, method, signal, timeout: 30_000,
        headers: { ...credentials.headers,
          'Content-Type': method === 'PATCH' ? 'application/merge-patch+json' : 'application/json',
          // Node does not frame DELETE bodies by default; unframed bytes corrupt the next keep-alive request.
          ...(data === undefined ? {} : { 'Content-Length': Buffer.byteLength(data) }) }
      }, (response) => {
        let text = '';
        response.setEncoding('utf8');
        response.on('data', (chunk) => {
          text += chunk;
          if (text.length > 4 * 1024 * 1024) request.destroy(new Error('Kubernetes response too large.'));
        });
        response.on('end', () => {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            // Do not echo API response bodies: they can contain request credentials or pairing data.
            reject(Object.assign(new Error(`Kubernetes ${method} ${path.split('?')[0]} returned HTTP ${response.statusCode}.`),
              { statusCode: response.statusCode }));
            return;
          }
          try { resolve(text ? JSON.parse(text) : {}); } catch { reject(new Error('Invalid Kubernetes JSON response.')); }
        });
        response.on('error', reject);
      });
      request.on('timeout', () => request.destroy(new Error('Kubernetes request timed out.')));
      request.on('error', reject);
      request.end(data);
    });
  }

  async readiness(namespace, pod, signal) {
    const { default: WebSocket } = await import('ws');
    const query = new URLSearchParams({ container: 'orca-runtime', stdout: 'true', stderr: 'true' });
    for (const command of ['node', '-e',
      'process.stdout.write(require("fs").readFileSync("/projects/.che-orca/ready.jsonl","utf8"))']) {
      query.append('command', command);
    }
    const url = new URL(`/api/v1/namespaces/${namespace}/pods/${pod}/exec?${query}`, this.origin);
    url.protocol = 'wss:';
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url, ['v4.channel.k8s.io'], this.credentials());
      let output = '';
      let succeeded = false;
      let finished = false;
      const timer = setTimeout(() => finish(new Error('Reading Orca readiness timed out.')), 15_000);
      const abort = () => finish(new Error('Provisioning cancelled.'));
      const finish = (error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        socket.terminate();
        error ? reject(error) : resolve(output);
      };
      socket.on('error', () => finish(new Error('Cannot read Orca readiness through Kubernetes exec.')));
      socket.on('close', () => finish(succeeded ? undefined : new Error('Orca readiness is not available yet.')));
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) { abort(); return; }
      socket.on('message', (data) => {
        if (data[0] === 1) output += data.subarray(1).toString();
        if (output.length > 1024 * 1024) { finish(new Error('Orca readiness output too large.')); return; }
        if (data[0] === 3) {
          try { succeeded = JSON.parse(data.subarray(1).toString()).status === 'Success'; } catch { /* retry on next poll */ }
        }
      });
    });
  }
}

export function pairingFromReadiness(text, host) {
  for (const line of text.split('\n')) {
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    if (record.type !== 'orca_server_ready' || record.schemaVersion !== 1 || !record.pairing?.available) continue;
    const value = record.pairing.url;
    if (typeof value !== 'string') continue;
    // The runtime must advertise the Route selected before it starts.
    let advertised;
    try { advertised = new URL(record.advertisedEndpoint); } catch { continue; }
    if (advertised.protocol !== 'wss:' || advertised.host !== host) continue;
    return value;
  }
  return null;
}

export class DevWorkspaceProvider {
  constructor(config, client = new KubernetesClient(), wait = delay) {
    this.config = config;
    this.client = client;
    this.wait = wait;
  }

  allocation(id = randomUUID()) {
    return { namespace: this.config.namespace, name: `orca-agent-${id}` };
  }

  paths(resource) {
    if (resource.namespace !== this.config.namespace || !/^orca-agent-[a-f0-9-]{36}$/.test(resource.name)) {
      throw new Error('Invalid agent environment resource.');
    }
    const suffix = `/namespaces/${resource.namespace}`;
    return { workspace: `${DW}${suffix}/devworkspaces`, template: `${DW}${suffix}/devworkspacetemplates`,
      service: `/api/v1${suffix}/services`, route: `${ROUTES}${suffix}/routes`, pods: `/api/v1${suffix}/pods` };
  }

  async get(path, resource, signal) {
    const existing = await this.client.request('GET', `${path}/${resource.name}`, undefined, signal);
    const labels = existing.metadata?.labels ?? {};
    if (Object.entries(this.config.labels).some(([key, value]) => labels[key] !== value)) {
      throw new Error('Refusing to use an environment owned by another Orca controller.');
    }
    return existing;
  }

  async owned(method, path, resource, body, signal) {
    let existing;
    try { existing = await this.get(path, resource, signal); }
    catch (error) { if (error.statusCode === 404 && method === 'DELETE') return; throw error; }
    // UID preconditions prevent a delete racing with replacement of the resource.
    return this.client.request(method, `${path}/${resource.name}`, method === 'DELETE'
      ? { preconditions: { uid: existing.metadata.uid } } : body, signal);
  }

  // The caller removes partially created resources with destroy() if this fails.
  async create(resource, repoUrl, signal) {
    const paths = this.paths(resource);
    if (!/^(https:\/\/|ssh:\/\/|git@)/.test(repoUrl) || /[\r\n]/.test(repoUrl)) {
      throw new Error('The project needs an HTTPS or SSH Git origin accessible from the agent namespace.');
    }
    if (repoUrl.startsWith('https://')) {
      const url = new URL(repoUrl);
      if (url.username || url.password || url.search) throw new Error('Use a namespace Git credential Secret instead of credentials in the Git URL.');
    }
    const metadata = { name: resource.name, labels: this.config.labels };
    await this.client.request('POST', paths.service, { apiVersion: 'v1', kind: 'Service', metadata,
      spec: { selector: { 'controller.devfile.io/devworkspace_name': resource.name }, ports: [{ port: 6768, targetPort: 6768 }] } }, signal);
    // A subdomain keeps the host within DNS label limits, unlike <name>-<namespace>.
    await this.client.request('POST', paths.route, {
      apiVersion: 'route.openshift.io/v1', kind: 'Route', metadata,
      spec: { subdomain: resource.name, to: { kind: 'Service', name: resource.name }, port: { targetPort: 6768 },
        tls: { termination: 'edge', insecureEdgeTerminationPolicy: 'Redirect' } }
    }, signal);
    const host = await this.routeHost(resource, signal);
    const editor = await this.client.request('GET', `${paths.template}/${this.config.template}`, undefined, signal);
    const template = structuredClone(editor.spec);
    for (const component of template.components ?? []) {
      // Inlined, orca-runtime is the workspace's own container; as a contribution
      // the DevWorkspace Operator would add the injector init container twice.
      delete component.attributes?.['controller.devfile.io/container-contribution'];
      if (component.name === 'orca-runtime' && component.container) {
        // Children need a development toolchain even without a project devfile.
        component.container.image = 'quay.io/devfile/universal-developer-image:latest';
        component.container.mountSources = true;
        component.container.env = [
          ...(component.container.env ?? []).filter((env) => env.name !== 'ORCA_PAIRING_ADDRESS'),
          { name: 'ORCA_PAIRING_ADDRESS', value: `wss://${host}/` }
        ];
      }
      // The direct Route above is the only way in.
      for (const endpoint of component.container?.endpoints ?? []) endpoint.exposure = 'internal';
    }
    template.attributes = { ...template.attributes,
      'controller.devfile.io/storage-type': 'per-workspace',
      ...(this.config.runtimeClass ? { 'controller.devfile.io/runtime-class': this.config.runtimeClass } : {}) };
    template.projects = [{ name: 'source', git: { remotes: { origin: repoUrl } } }];
    await this.client.request('POST', paths.workspace, {
      apiVersion: 'workspace.devfile.io/v1alpha2', kind: 'DevWorkspace',
      metadata, spec: { started: true, routingClass: 'basic', template }
    }, signal);
    return this.ready(resource, host, signal);
  }

  async routeHost(resource, signal) {
    const paths = this.paths(resource);
    for (let attempt = 0; attempt < 30; attempt++) {
      const route = await this.get(paths.route, resource, signal);
      const host = route.spec?.host || route.status?.ingress?.find((ingress) => ingress.host)?.host;
      if (host && /^[a-zA-Z0-9.-]+$/.test(host)) return host;
      await this.wait(1000, undefined, { signal });
    }
    throw new Error('OpenShift did not assign a Route hostname.');
  }

  async ready(resource, host, signal) {
    const paths = this.paths(resource);
    const deadline = Date.now() + this.config.timeoutMs;
    while (Date.now() < deadline) {
      signal?.throwIfAborted();
      const workspace = await this.client.request('GET', `${paths.workspace}/${resource.name}`, undefined, signal);
      if (['Failed', 'Error', 'Failing'].includes(workspace.status?.phase)) throw new Error('The agent DevWorkspace failed to start. Check its status conditions.');
      const selector = encodeURIComponent(`controller.devfile.io/devworkspace_name=${resource.name}`);
      const pods = await this.client.request('GET', `${paths.pods}?labelSelector=${selector}`, undefined, signal);
      const pod = pods.items?.find((item) => !item.metadata.deletionTimestamp &&
        item.status?.conditions?.some((condition) => condition.type === 'Ready' && condition.status === 'True'));
      if (pod) {
        let text;
        try { text = await this.client.readiness(resource.namespace, pod.metadata.name, signal); }
        catch { signal?.throwIfAborted(); }
        const pairingCode = text && pairingFromReadiness(text, host);
        if (pairingCode) return { schemaVersion: 1, pairingCode, projectRoot: '/projects/source', userData: resource };
      }
      await this.wait(2000, undefined, { signal });
    }
    throw new Error('Timed out waiting for the agent DevWorkspace and Orca runtime.');
  }

  async suspend(resource, signal) {
    const paths = this.paths(resource);
    await this.owned('PATCH', paths.workspace, resource, { spec: { started: false } }, signal);
    const deadline = Date.now() + this.config.timeoutMs;
    while (Date.now() < deadline) {
      const workspace = await this.client.request('GET', `${paths.workspace}/${resource.name}`, undefined, signal);
      if (workspace.status?.phase === 'Stopped') return;
      if (workspace.status?.phase === 'Failed') throw new Error('The agent DevWorkspace failed while stopping.');
      await this.wait(2000, undefined, { signal });
    }
    throw new Error('Timed out waiting for the agent DevWorkspace to stop.');
  }

  async resume(resource, signal) {
    const paths = this.paths(resource);
    const host = await this.routeHost(resource, signal);
    await this.owned('PATCH', paths.workspace, resource, { spec: { started: true } }, signal);
    return this.ready(resource, host, signal);
  }

  async destroy(resource) {
    const paths = this.paths(resource);
    const errors = [];
    for (const path of [paths.workspace, paths.route, paths.service]) {
      try { await this.owned('DELETE', path, resource); } catch (error) { errors.push(error); }
    }
    if (errors.length) {
      throw new Error(`Could not remove all agent environment resources: ${errors.map((error) => error.message).join(' ')}`);
    }
  }
}
