# Test Orca agent workspaces on CRC

This walkthrough takes a fresh Red Hat OpenShift Local (CRC) instance through
installing Eclipse Che, deploying Orca, and running OpenCode in separate agent
workspace pods. Use the browser on the machine running CRC.

The flow was exercised on an existing cluster on **macOS with Apple silicon, CRC 2.56.0, OpenShift
4.20.1, and Eclipse Che `next`**. The repository pins Orca to 1.4.219 and OpenCode
to 2.1.4. The commands below install the Che version supplied by your `chectl`;
record its version when reproducing a result. A fresh-cluster run of this entire
walkthrough has not been verified. Intel/macOS and Linux need an
AMD64 editor image; they have not been exercised end to end for this PoC.

This is a local evaluation setup. Agent pods use normal OpenShift container
isolation; this walkthrough does not enable Kata, gVisor, or Bubblewrap.

## 1. Prepare the host

Install:

- [CRC / Red Hat OpenShift Local](https://crc.dev/docs/installing/) and download
  an OpenShift pull secret through the linked Red Hat download page.
- [Podman](https://podman.io/docs/installation), Git, Bash, and Python 3.
- [chectl](https://eclipse.dev/che/docs/stable/administration-guide/installing-the-chectl-management-tool/).
- On macOS, Homebrew for the wildcard DNS setup below. `watch` is optional.

Use a host with enough capacity for CRC **and** the Podman build VM. Our CRC
configuration is 8 CPUs, 20 GiB RAM, and a 200 GiB virtual disk. These are PoC
allocations, not CRC's minimum requirements. Leave additional RAM and disk space
for the host OS, build dependencies, and registry/image caches. The UDI image alone
is about 8.9 GB unpacked. Repeated builds can fill a smaller CRC disk and evict images.

On macOS, start a Podman machine if one is not already running:

```bash
podman machine list
# Only if no Podman machine exists:
podman machine init
# Start your existing machine if it is stopped:
podman machine start
podman info
```

Run the remaining commands in one Bash or Zsh terminal unless stated otherwise.
Do not put your pull secret, registry credentials, or pairing URLs in the repository.

## 2. Create and start CRC

For a new instance:

```bash
crc config set preset openshift
crc config set cpus 8
crc config set memory 20480
crc config set disk-size 200
crc setup
crc start
crc status
```

Supply your downloaded OpenShift pull secret when prompted. Run CRC as your
normal user; its setup can request administrator access when needed.
See the [CRC startup documentation](https://crc.dev/docs/using/).

If CRC already exists, do not delete it just to follow this guide. Resource changes
may require `crc stop` followed by `crc start`. Stop workspaces first. A disk-size
increase is applied on startup; it does not shrink an existing disk.

Use CRC's `oc` binary and a dedicated kubeconfig so the walkthrough does not change
your normal cluster context:

```bash
eval "$(crc oc-env)"
mkdir -p "$HOME/.kube"
export KUBECONFIG="$HOME/.kube/che-orca-crc"
crc console --credentials
oc login -u kubeadmin https://api.crc.testing:6443
oc whoami
oc get nodes
```

Enter the administrator password printed by `crc console --credentials` at the
login prompt. Keep that output private. In a new terminal, export the same
`KUBECONFIG` and run `eval "$(crc oc-env)"` again.

The OpenShift console is at <https://console-openshift-console.apps-crc.testing>.

## 3. Install Eclipse Che

With `oc` still logged in as `kubeadmin`:

```bash
chectl --version
chectl server:deploy --platform crc --chenamespace eclipse-che
chectl server:status --chenamespace eclipse-che
oc get checluster -A
oc get pods -n eclipse-che
oc get crd devworkspaces.workspace.devfile.io
oc get checluster eclipse-che -n eclipse-che -o jsonpath='{.status.cheURL}{"\n"}'
```

Wait for the installation to complete. We explicitly choose `eclipse-che` as the
installation namespace; this is different from the user and agent namespaces below.
If Che is already installed, reuse it rather than installing a second instance.
Adjust the installation namespace and CheCluster name in subsequent commands to
match `oc get checluster -A`.

The [official Che-on-CRC guide](https://eclipse.dev/che/docs/stable/install/proc_installing-che-on-red-hat-openshift-local/)
describes the installation workflow. Installation can take several minutes.

Pre-pull the large development image before starting workspaces, so its download
does not consume the DevWorkspace startup timeout:

```bash
oc debug node/crc -q -- chroot /host crictl pull quay.io/devfile/universal-developer-image:latest
```

## 4. Configure browser DNS and certificate trust

Each agent pod gets a new Route hostname, such as
`orca-agent-<uuid>.apps-crc.testing`. The browser connects directly to that child
runtime. A hosts-file entry for the main Orca page is insufficient.

### Wildcard DNS on macOS

Install dnsmasq and add a dedicated configuration file. If you already run a DNS
service, integrate this zone with it instead of starting a conflicting listener.
These settings answer only for the CRC application domain, on localhost port 53.

```bash
brew install dnsmasq
BREW_PREFIX="$(brew --prefix)"
mkdir -p "$BREW_PREFIX/etc/dnsmasq.d"
cat > "$BREW_PREFIX/etc/dnsmasq.d/che-orca.conf" <<'DNS'
port=53
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
local=/apps-crc.testing/
address=/apps-crc.testing/127.0.0.1
DNS
sudo brew services restart dnsmasq
sudo mkdir -p /etc/resolver
printf 'nameserver 127.0.0.1\n' | sudo tee /etc/resolver/apps-crc.testing
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

The Homebrew dnsmasq service includes files from `etc/dnsmasq.d/*.conf`. Review
existing dnsmasq settings if it was already configured. Use port **53**, not 1053,
for this macOS scoped resolver setup.

Verify through macOS's resolver, not just a direct DNS query:

```bash
dscacheutil -q host -a name orca-agent-dns-check.apps-crc.testing
```

Expected: `ip_address: 127.0.0.1`. The Route need not exist for this DNS check.
The [dnsmasq manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
documents domain address overrides.

On Linux, first check CRC's native DNS configuration:

```bash
getent hosts orca-agent-dns-check.apps-crc.testing
```

If it does not resolve, configure your host resolver for `*.apps-crc.testing`
using the [CRC networking documentation](https://crc.dev/docs/networking/).
Use the address appropriate to that host's CRC networking mode; do not copy the
macOS loopback address onto a Linux host without checking it.

### Trust this CRC instance's ingress CA

Still using the administrator `oc` context, export the **public CA certificate**:

```bash
CRC_CERT_DIR="$HOME/.local/share/che-orca-crc"
mkdir -p "$CRC_CERT_DIR"
oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CRC_CERT_DIR/ingress-ca.crt"
openssl x509 -in "$CRC_CERT_DIR/ingress-ca.crt" -noout -subject -issuer -dates
```

On macOS, trust it for TLS in the system keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain "$CRC_CERT_DIR/ingress-ca.crt"
```

This adds trust for certificates issued by this local CRC cluster. Fully quit and
reopen your browser afterward. Browser-specific certificate stores may need a
separate import. On Linux, import this CA using your distribution/browser's trust
store procedure.

Trust is important for **every child hostname**: accepting a browser exception
for the main page alone may still leave child WebSocket connections blocked.
Recreating CRC also creates new certificates; export and trust the new CA then.

## 5. Initialize the Che user namespace

Open the Che URL from step 3, normally <https://eclipse-che.apps-crc.testing>.
Log in as **developer**, using the password from `crc console --credentials`.
Create one sample workspace from the dashboard, wait for it to start, then stop it.
This exercises Che and initializes its user namespace before deploying Orca.

Switch the terminal to that same user:

```bash
oc login -u developer https://api.crc.testing:6443
oc whoami
oc projects
oc get devworkspaces -n developer-devspaces
```

Locate the sample workspace's namespace. With the usual `<username>-devspaces`
configuration it is `developer-devspaces`. If yours differs, substitute your actual
namespace throughout this guide. Do not use the Che installation namespace.

```bash
oc project developer-devspaces
oc new-project developer-agent-devspaces
oc project developer-devspaces
```

If the agent project already exists, select it instead of recreating it. The agent
namespace must differ from the controller namespace. The local `developer` account
must have permission to create the templates, ConfigMap, Role, and RoleBinding
used by the deployment scripts in these namespaces.

## 6. Configure and deploy Orca

Use a checkout containing this PoC's agent-environment changes, including
`agent-workspaces.patch` and `integration/`. For a published revision:

```bash
git clone https://github.com/Firewall/che-orca.git
cd che-orca
git switch feat/orca-agent-workspaces
cp config.env.example config.env
```

Edit `config.env` (a local, gitignored Bash file):

```bash
NAMESPACE=developer-devspaces
ORCA_IMAGE=quay.io/YOUR_ORG/che-orca:crc-test
ORCA_PLATFORM=linux/arm64
ORCA_AGENT_NAMESPACE_TEMPLATE='<username>-agent-devspaces'
```

Use `ORCA_PLATFORM=linux/amd64` on an Intel/AMD host. Leave
`ORCA_AGENT_RUNTIME_CLASS` unset for CRC. Kata requires a separately configured
cluster and is outside this test flow.

Choose a registry repository you can push to and that the cluster can pull from.
For this walkthrough, make it public; a private repository additionally needs
workspace image-pull credentials. Authenticate Podman, then use the full workflow:

```bash
podman login quay.io
./deploy.sh
```

This builds and pushes the image, registers the main and agent editor templates,
creates agent provisioning RBAC and configuration, and starts `orca-workspace`.

The final output contains the main workspace URL behind the Che gateway. Open
it and log in as `developer`; the gateway serves an auto-pairing page. You can
also open `orca-workspace` from the Che dashboard. The controller manages child
pairing credentials, so you do not paste child pairing URLs manually. Keep runtime
readiness files and deployment logs private.

Check the deployment:

```bash
oc get devworkspaces -n developer-devspaces
oc get pods -n developer-devspaces
oc get devworkspacetemplate orca-agent-editor -n developer-agent-devspaces
oc get configmap orca-agent-environment -n developer-devspaces
```

The main workspace should reach `Running`. The agent namespace has no child pods
until you create a workspace in Orca.

The templates come from this repository's `devfile.yaml`: an injector supplying Orca and OpenCode and a runtime contribution. The main
workspace opens through Che login; children use UDI containers and direct Routes. The provisioner currently
**does not use the cloned project's own devfile**.

## 7. Create two isolated agent workspaces

In the main Orca workspace terminal:

```bash
git clone https://github.com/octocat/Hello-World.git /projects/hello-world
```

In the Orca UI:

1. Add `/projects/hello-world` as a Git project.
2. Create a workspace, choose **Che DevWorkspace** as its execution target, and
   accept or replace the suggested name.
3. Wait for provisioning and the child connection to finish.
4. Create a second workspace using the same execution target.

Choose **Che DevWorkspace** rather than a local worktree. Each successful creation
should produce an `orca-agent-<uuid>` DevWorkspace, its own pod, Route, and persistent
storage in `developer-agent-devspaces`. The browser needs DNS and TLS trust for the
new child Routes.

The sidebar shows one collapsible group per agent environment. Inside each group,
the named worktree is visible; its backing primary checkout stays on disk but is
hidden once the named worktree exists. The controller's primary checkout remains
visible. Agents within one workspace share that workspace's pod.

## 8. Verify isolation and run OpenCode

On the host terminal:

```bash
oc get devworkspaces -n developer-agent-devspaces
oc get pods -n developer-agent-devspaces -o wide
oc get pvc -n developer-agent-devspaces
oc get routes -n developer-agent-devspaces
oc get pods -n developer-agent-devspaces -o custom-columns='WORKSPACE:.metadata.labels.controller\.devfile\.io/devworkspace_name,POD:.metadata.name,CONTAINER_IDS:.status.containerStatuses[*].containerID'
```

The two workspaces should have distinct pod names and container IDs. In each
workspace's Orca terminal:

```bash
echo "$DEVWORKSPACE_NAME"
hostname
pwd
command -v opencode
opencode --version
opencode models --standalone
```

Expected: different workspace names/hostnames, a named worktree directory, and
`/orca/bin/opencode` reporting V2.1.4. To start a coding session:

```bash
opencode
```

Select a free model with `/models`; free-model availability is controlled by the
provider and can change. No provider credentials are needed for the free models
used in this PoC. Ask it to create a small hello-world program in that workspace.
Check that the file appears there and is absent from the other workspace.

To inspect agents from the host, choose a pod name from `oc get pods`:

```bash
oc exec -it -n developer-agent-devspaces POD_NAME -c orca-runtime -- ps -eo pid,ppid,user,args --forest
```

For a refreshing view with green pod headings (`brew install watch` on macOS if
needed):

```bash
watch -c -n 2 'for pod in $(oc get pods -n developer-agent-devspaces -o name); do printf "\n\033[1;32m=== %s ===\033[0m\n" "$pod"; oc exec -n developer-agent-devspaces "$pod" -c orca-runtime -- ps -eo pid,ppid,user,args --forest; done'
```

Press Ctrl+C to stop. Each pod's tree should show its own `opencode` process after
launching an agent there. The model itself runs at the provider, not in this pod.

## 9. Exercise the lifecycle

Use Orca's controls on one agent workspace while watching:

```bash
oc get devworkspaces -n developer-agent-devspaces -w
```

- **Sleep:** the selected DevWorkspace reaches `Stopped`; the other one stays running.
- **Wake:** it returns to `Running`; the file created earlier is still present.
- **Cleanup:** the selected DevWorkspace, Service, and Route are removed. Its
  successfully cleaned runtime is hidden from the lifecycle list. Failed cleanup
  remains visible for retry.

Container IDs can change on wake or pod replacement. Check storage retention
separately; it follows the DevWorkspace/cluster policy. Do not use cleanup as a
substitute for backing up code.

## Troubleshooting

### Child pod runs, but Orca says it cannot connect

Check resolution of the **actual child Route**, using the host's native resolver,
then request its web client without disabling certificate validation:

```bash
oc get routes -n developer-agent-devspaces
curl https://CHILD_ROUTE_HOST/web-index.html
```

On macOS, `dscacheutil -q host -a name CHILD_ROUTE_HOST` should resolve to
`127.0.0.1`. If `curl --cacert "$CRC_CERT_DIR/ingress-ca.crt"` works while ordinary
`curl` fails, check certificate trust and restart the browser. The UI's generic
Tailscale suggestion does not mean Tailscale is required for this local CRC flow.
Failed connection setup can trigger cleanup, so inspect resources during a retry.

### Workspace startup times out while pulling images

Inspect events and disk usage:

```bash
crc status
oc get events -n developer-devspaces --sort-by=.lastTimestamp
oc get events -n developer-agent-devspaces --sort-by=.lastTimestamp
```

Large uncached image pulls can exceed the operator's startup timeout. As
`kubeadmin`, pre-pull both the UDI and your published editor image with
`oc debug node/crc -q -- chroot /host crictl pull IMAGE_REFERENCE`. Switch back to
`developer`, then retry the failed workspace. To restart the main workspace:

```bash
oc patch devworkspace orca-workspace -n developer-devspaces --type=merge -p '{"spec":{"started":false}}'
oc wait devworkspace/orca-workspace -n developer-devspaces --for=jsonpath='{.status.phase}'=Stopped --timeout=120s
oc patch devworkspace orca-workspace -n developer-devspaces --type=merge -p '{"spec":{"started":true}}'
```

If disk pressure keeps evicting images, increase CRC's disk allocation and restart
CRC. An image being cached once does not guarantee it remains cached.

### Main workspace waits for its health check / gateway returns 504

Inspect `workspace-ingress` and other NetworkPolicies in the user namespace:

```bash
oc get networkpolicy -n developer-devspaces
oc get networkpolicy workspace-ingress -n developer-devspaces -o yaml
```

A reused namespace can allow a previous Che installation namespace while blocking
its current gateway. If that is the cause, add a narrow allow rule for the gateway
namespace used in this guide:

```bash
oc apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: che-orca-gateway-ingress
  namespace: developer-devspaces
spec:
  podSelector:
    matchLabels:
      controller.devfile.io/devworkspace_name: orca-workspace
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: eclipse-che
YAML
```

Adjust both namespaces if yours differ. This additional rule is only needed when
an existing policy blocks the Che gateway.

### Networking fails with `Multus ... Unauthorized` after a CRC restart

Inspect events to confirm that error, then, as `kubeadmin`, restart the Multus
DaemonSet and wait for recovery:

```bash
oc rollout restart daemonset/multus -n openshift-multus
oc rollout status daemonset/multus -n openshift-multus --timeout=120s
```

Switch back to `developer` and retry. Do not reset networking for unrelated errors.

### New devfile/image changes do not appear in existing workspaces

`./deploy.sh` updates the templates and published image. Existing child
DevWorkspaces retain their copied definitions. Recreate disposable test children
to pick up changed devfile settings. Restart the main workspace to rerun its
injector after an image update. A browser refresh alone only reloads the client.

### Permission denied when creating an agent workspace

Verify `oc whoami`, both namespaces, and `ORCA_AGENT_NAMESPACE_TEMPLATE` in
`config.env`. The template resolves from the user running `./deploy.sh`; deploying
as `kubeadmin` would resolve a different agent namespace than `developer`.
Check the `orca-workspace-provisioner` Role/RoleBinding and rerun `./deploy.sh`
as the intended user after fixing permissions.

## 10. Remove the PoC

From this repository, with the same kubeconfig, user, and `config.env`:

```bash
./teardown.sh
```

This removes the Orca deployment and its controller-owned agent resources. It keeps
the agent namespace; PVC retention follows cluster policy. If you added the optional
gateway NetworkPolicy, remove that separately:

```bash
oc delete networkpolicy che-orca-gateway-ingress -n developer-devspaces --ignore-not-found
```

Stop CRC when finished:

```bash
crc stop
```

`crc delete` is an optional full reset that destroys the entire CRC cluster and its
data, including unrelated workloads. It is not required for Orca teardown.

If you remove CRC entirely, remove the scoped resolver file and the CA trust you
added. Stop dnsmasq only if you installed it solely for this walkthrough:

```bash
sudo rm /etc/resolver/apps-crc.testing
sudo security remove-trusted-cert -d "$CRC_CERT_DIR/ingress-ca.crt"
# Only for a dnsmasq service dedicated to this walkthrough:
sudo brew services stop dnsmasq
```
