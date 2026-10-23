# Orca agent workspaces: what this branch adds

## In plain English

Orca runs inside one Eclipse Che workspace. Until now, every project and every
coding agent shared that workspace's container, disk, and CPU.

This branch lets Orca give each new Orca workspace its own Che workspace, called an
**agent environment**. Each one has its own pod, storage, clone of the project, and
OpenCode installation. You still open Orca through your normal Che login. When you
create a workspace in Orca, you pick **Che DevWorkspace** as the target and Orca
starts the new environment. It then connects the browser to it, and you work in it
as if it were local. You can put an environment to sleep, wake it, or delete it from
Orca, and Orca cleans up everything it created.

The goal comes from a request for "a DevWorkspace per agent, in a separate
namespace, optionally under kata-containers". We interpreted it as one DevWorkspace
per **Orca workspace**, not per agent. Agents in the same Orca workspace share a
worktree, so they share a pod.

This is a prototype. Its configuration is shaped like a proposed
`devAgentEnvironments` section of the CheCluster, so it can later move into
che-operator.

## Architecture

```
Browser ──Che login──▶ Che gateway ──▶ Controller workspace (orca-workspace)
   │                                    namespace: <user>-devspaces
   │                                    orcad + cheWorkspace.* RPC methods
   │                                          │ Kubernetes API (scoped RBAC)
   │                                          ▼
   └──TLS Route + Orca pairing──────▶ Agent environment (DevWorkspace)
                                       namespace: <user>-agent-devspaces
                                       orcad, OpenCode, own PVC, Git clone
```

- **Controller:** the existing Orca workspace. It is the only thing behind Che
  login. It holds the credentials to create, manage, and delete agent environments.
- **Agent environment:** a DevWorkspace in a separate namespace for each Orca
  workspace. It runs its own `orcad`, serves the web client, and is reachable
  through its own Route.
- **Two access paths:** the controller is protected by Che's gateway. A child has
  no Che login in front of it, so its Route is protected by Orca's own pairing
  code. The controller stores that code and hands it to the browser.

## What was built

### Provisioning (`integration/src/main/che/devworkspace-provider.mjs`)

Talks to the Kubernetes API directly, with no `oc` or `kubectl` binary in the image.

- **create:**
  1. Creates a Service.
  2. Creates a Route that uses `spec.subdomain` and reads the final host from the
     Route's status. A host built as `<name>-<namespace>` can exceed DNS's
     63-character limit.
  3. Copies the shared editor template into a new DevWorkspace.
  4. Sets the child's pairing address to its Route.
  5. Selects the Universal Developer Image (UDI) as the runtime.
  6. Gives the child its own per-workspace storage.
  7. Clones the project's Git origin into `/projects/source`.
  8. Waits for the child to report ready, then reads its pairing code. It reads the
     code from a private file in the child over `pods/exec`, so the code never goes
     into a Kubernetes object.
- **suspend / resume:** stops and starts the DevWorkspace. Storage persists, and the
  controller reconnects after resume.
- **destroy:** deletes the DevWorkspace, Route, and Service, which also removes the
  PVC. Deletes check ownership labels and a UID precondition, so the provider only
  removes what it created. Errors include the failing request, and a failed cleanup
  stays recorded for retry.
- **runtime class:** an optional `runtimeClassName` (for example `kata`) is applied
  to agent pods. It is off by default.

### Controller methods (`integration/src/main/che/che-workspaces.ts`)

Adds `cheWorkspace.*` RPC methods to `orcad`: list recipes, provision, resume,
suspend, and cleanup. Upstream Orca's remote-environment recipes only run in its
Electron main process, so the browser build cannot use them. These methods expose
the same behaviour over `orcad`'s RPC.

- Provisioning can be cancelled. Cancelling, or failing, rolls back whatever was created.
- One lifecycle operation per environment runs at a time.
- Each environment is recorded in Orca's existing ephemeral runtime store, so Orca
  needs no new state model.

### Browser side (`integration/src/renderer/…`)

- `web-che-workspaces-api.ts` and `web-che-environments.ts` connect the web client's
  `ephemeralVm` API to the new RPC methods and register each child as a runtime
  environment.
- `agent-primary-workspaces.ts` hides a child's backing primary checkout once a named
  worktree exists. The controller's own checkout stays visible.

### Upstream patch (`agent-workspaces.patch`)

Applied after `web-client.patch` at image build. It touches the upstream Orca files
that need to know about the new target:

- RPC method registration and parameter parity.
- The long-poll list.
- The composer's run-target options, target selection, and recipe hook.
- The web environments API and session. Children get a client each, and disconnect and
  remove behave correctly for them.
- The execution-host registry, sidebar grouping, and server settings, which group
  runtimes under **Agent environments**.

The new files in `integration/` mirror upstream's `src/` tree and are copied in
before the patch applies. The patch applies cleanly to Orca v1.4.219.

### Image and entrypoints

- **OpenCode 2.1.4** is bundled from the target architecture's pinned npm package.
  It is fetched without running target code, for both `amd64` and `arm64`.
  `entrypoint.sh` runs `opencode --version` before advertising a usable runtime.
- **Child startup mode:** if `ORCA_PAIRING_ADDRESS` is set, `orcad` binds
  `0.0.0.0`, advertises that address, and serves the plain web client. Otherwise it
  keeps the gateway behaviour, with loopback binding and a private auto-pairing page.
  The same image and devfile serve both roles.
- **Injector fix:** `entrypoint-init-container.sh` copies directory contents rather
  than the directories themselves. On a surviving volume the old code nested
  `runtime/runtime` and left stale binaries behind.
  `tests/injector.sh` checks this against a built image.
- **`ORCA_PLATFORM`** overrides the build platform, which defaults to `linux/amd64`.
  Use `linux/arm64` for CRC on Apple silicon.

### Deploy tooling (`shared/agent-workspaces.sh`)

`./deploy.sh` stands in for che-operator. If `ORCA_AGENT_NAMESPACE_TEMPLATE` is set,
it does the following:

1. Resolves `<username>` with `oc whoami`, for example `<username>-agent-devspaces`.
   It rejects invalid names and names equal to the user namespace.
2. Checks that the namespace exists. Creating it just in time needs the operator;
   until then, create it with `oc new-project`.
3. Applies the `orca-agent-editor` template to the agent namespace, rendered from the
   same `devfile.yaml`.
4. Applies the `orca-workspace-provisioner` Role and binds it to the user namespace's
   ServiceAccounts.
5. Creates the `orca-agent-environment` ConfigMap in the user namespace. The
   DevWorkspace Operator mounts it as environment variables into the user's
   workspaces. It carries the agent namespace and runtime class, so the editor
   template has no per-user settings.

`./teardown.sh` removes the ConfigMap, the controller's children (found by ownership
labels), the Role and binding, and the template. It never deletes the namespace.

### Configuration

| Variable | Effect |
| --- | --- |
| `ORCA_AGENT_NAMESPACE_TEMPLATE` | Enables the feature. For example `'<username>-agent-devspaces'`. Quote it, because bash reads `<` as a redirection. |
| `ORCA_AGENT_RUNTIME_CLASS` | Optional `runtimeClassName` for agent pods, for example `kata`. |
| `ORCA_PLATFORM` | Build platform: `linux/amd64` (default) or `linux/arm64`. |

## Security model

- **The controller's RBAC is a namespaced Role, not cluster access.** It allows
  create, get, patch, and delete on DevWorkspaces. It allows create, get, and delete
  on Services and Routes. It allows get on the one editor template by name. It allows
  get and list on pods, and `pods/exec`.
- **What it cannot do:** read Secrets, list DevWorkspaces, change RBAC, create
  namespaces, or touch other namespaces. This was checked on a cluster and returned
  403.
- **Children have no RBAC in the agent namespace.** The DevWorkspace Operator still
  mounts a ServiceAccount token, because its `automountServiceAccountToken` override
  is ignored. That token only grants basic authenticated access.
- **Child Routes are reachable by anyone who can reach the cluster's ingress,**
  protected by Orca pairing only. Pairing URLs and codes are credentials. The scripts redact them, and
  the controller keeps them in browser memory only.
- **Ownership labels** `orca.eclipse.org/controller-namespace` and
  `orca.eclipse.org/controller` scope every delete and teardown to the controller
  that created the resource.
- **Isolation is plain OpenShift container isolation.** Kata is supported by the
  setting but has not been tested.

## Documentation added

- `README.md`: an **Agent environments** section, config rows, and layout entries.
- `docs/CRC.md`: a step-by-step walkthrough for installing Che on CRC, deploying Orca,
  creating agent workspaces, and troubleshooting.

## Tested

- ShellCheck, devfile render check, and the provider's regression tests.
- Upstream typechecks and the touched areas' tests.
- The patch applies cleanly to Orca v1.4.219.
- On CRC 2.56.0 / OpenShift 4.20.1 / Che `next` with Apple silicon:
  - Provision in about 22 s, connect through the Route, and run OpenCode 2.1.4.
  - Suspend and resume with storage kept.
  - Cleanup removes all resources.
  - Forced cleanup failure with retry, and cancel with full rollback.
  - Scoped RBAC, with 403 for forbidden calls.
  - Che login to the main workspace and the agent groups in the UI.

## Not tested

- `amd64` execution.
- Kata, or any non-default runtime class.
- A fresh-cluster run of the whole CRC walkthrough.
- Full compatibility with OpenCode 2 and Orca's APIs.
- Just-in-time namespace creation and the real `devAgentEnvironments` CheCluster
  field. Both need che-operator changes.

## Limits and follow-ups

- **Operator integration:** `shared/agent-workspaces.sh` should become che-operator
  reconciliation of `devAgentEnvironments`, which would also create the namespace
  just in time.
- **Git state:** only the project's Git origin is cloned. Uncommitted changes and
  unpublished branches in the controller are not copied. Credentials embedded in
  HTTPS Git URLs are rejected. Git and agent credentials must be configured in the
  agent namespace.
- **Folder projects** are not supported as agent environments.
- **Cold starts:** Che stops an idle workspace, and a node under disk pressure can
  evict cached images. Large images, such as the 8.9 GB UDI, can exceed the
  DevWorkspace Operator's 5-minute start timeout on a cold node.
