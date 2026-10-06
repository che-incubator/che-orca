# Orca for Eclipse Che

Run [Orca](https://github.com/stablyai/orca) as an editor in an Eclipse Che workspace, with [OpenCode](https://opencode.ai) and optional KServe model discovery. Orca provides a browser environment for coding agents and parallel Git worktrees.

This repository contains the container recipe, devfile, and scripts that build an image and create a workspace in your user namespace.

This is an experiment. A direct OpenShift Route works around Che gateway routing limitations, and upstream Orca changes can break the integration. It is a community project with no production support commitment.

| | |
| --- | --- |
| Upstream | [stablyai/orca](https://github.com/stablyai/orca) v1.4.219 |
| Agent | OpenCode 1.18.34, with optional KServe model discovery |
| Port | 6768 |
| Authentication | Browser pairing URL |
| Client | Browser |

## How it works

The devfile adds two components to the workspace:

- **`orca-injector`** runs as a `preStart` init container. It copies the Orca standalone runtime, prebuilt web client, OpenCode, and the Google Cloud SDK out of the image and onto the shared `orca` volume mounted at `/orca`.
- **`orca-runtime`** is a container contribution to the standard [universal developer image](https://quay.io/devfile/universal-developer-image). A `postStart` command launches `/orca/entrypoint.sh`, which starts `orcad` on port 6768 and serves the web client from `/orca/web`.

Keeping the runtime on a volume means your workspace keeps the full universal developer image toolchain; Orca is injected alongside it rather than replacing it.

Orca advertises its own WebSocket address in the pairing URL it hands to the browser, so `deploy.sh` creates the direct Route *before* starting the workspace and passes the resulting `wss://` hostname in as `ORCA_PAIRING_ADDRESS`.

## Requirements

- An OpenShift cluster with Eclipse Che installed.
- Bash and `podman` on your machine. The deploy script uses Podman.
- Python 3 and the dependency in `requirements.txt` for devfile rendering.
- The `oc` CLI, logged in to the cluster.
- Permission to create DevWorkspaces, DevWorkspaceTemplates, Services, and Routes in your Che user workspace namespace.
- A registry you can push to and that workspace pods can pull from. A public image is convenient on shared clusters where you cannot configure pull credentials.

Cluster-wide editor registration additionally needs admin permissions. Google Vertex AI is optional and requires a Google Cloud project with access to your chosen models.

Install the renderer dependency in a virtual environment and activate it before deploying, registering, or running tests:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

## Configure

```bash
cp config.env.example config.env
${EDITOR:-vi} config.env
```

Set `NAMESPACE` to your Che user workspace namespace and `ORCA_IMAGE` to a registry you can push to:

```env
NAMESPACE=che-user-workspaces
ORCA_IMAGE=quay.io/my-org/che-orca:latest
```

Run `oc project -q` to check your current namespace. The scripts require an explicit `NAMESPACE`; the namespace hosting the Che operator is usually different from your user namespace.

| Variable | Required | Purpose |
| --- | --- | --- |
| `NAMESPACE` | yes | Che user workspace namespace to deploy into |
| `ORCA_IMAGE` | yes | Image to build and push |
| `REDHAT_AI_NAMESPACE` | no | Namespace to scan for KServe InferenceServices. Empty skips discovery. |
| `GOOGLE_CLOUD_PROJECT` | no | Only for Google Vertex AI |
| `CLOUD_ML_REGION` | no | Vertex AI region, defaults to `us-central1` |
| `ORCA_PAIRING_ADDRESS` | no | Only for manual registration; `deploy.sh` sets this itself |

`config.env` is a local, gitignored Bash file.

## Deploy

```bash
./deploy.sh
```

The script builds and pushes a `linux/amd64` image, creates the direct Service and Route, renders the devfile into a `DevWorkspaceTemplate`, creates the `orca-workspace` DevWorkspace, waits for the pod, and then prints the pairing URL:

```
=== Orca is ready ===

URL:      https://<route-host>/#<pairing-fragment>
Shell:    oc exec -it <pod> -c orca-runtime -n <namespace> -- bash
```

Keep that output private. The URL is a credential.

The workspace starts with no source repository. Clone your code under `/projects` after connecting. Resource names are fixed, so rerunning the script updates the same workspace, template, Service, and Route.

If the script times out waiting for the pairing URL, check the startup log:

```bash
oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- cat /orca/entrypoint-logs.txt
```

## Access and credentials

The direct Route bypasses the Che gateway and terminates TLS, redirecting HTTP to HTTPS. Orca's browser pairing controls access to that Route.

Orca writes a readiness JSON stream to `/projects/.che-orca/ready.jsonl` with mode `600`, inside a directory with mode `700`. To retrieve the pairing URL later:

```bash
source ./config.env
POD=$(oc get pods -n "$NAMESPACE" \
  -l controller.devfile.io/devworkspace_name=orca-workspace \
  --no-headers | awk '$3 != "Completed" && $1 !~ /cleanup/ {print $1; exit}')
oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- \
  cat /projects/.che-orca/ready.jsonl
```

Use the full `pairing.webClientUrl` from the `orca_server_ready` record, **including the URL fragment**. Keep pairing URLs, logs, and generated model configuration out of issues and pull requests.

## AI providers

### KServe model discovery

On startup the entrypoint looks for KServe InferenceServices in `REDHAT_AI_NAMESPACE` and writes the matching OpenCode providers to `/projects/opencode.json`. The workspace service account needs permission to list those InferenceServices and to authenticate to their model endpoints. Discovery skips missing or unreachable services, and leaving `REDHAT_AI_NAMESPACE` empty disables it entirely.

In Orca, open a terminal in your repository, run `opencode`, and pick a model with `/models`. The entrypoint exports `OPENCODE_CONFIG=/projects/opencode.json`, so discovery also applies inside cloned repositories and worktrees under `/projects`. OpenCode merges that config with your user and project settings.

Orca runs OpenCode as an interactive agent and keeps its default tools and permissions.

### Other providers

See [OpenCode's provider documentation](https://opencode.ai/docs/providers/) for external providers. Configure them from an Orca terminal or with `oc exec -it`.

For Google Vertex AI, set `GOOGLE_CLOUD_PROJECT` and `CLOUD_ML_REGION` in `config.env`, then authenticate from the workspace:

```bash
export PATH=/orca/npm-global/bin:/orca/google-cloud-sdk/bin:$PATH
gcloud auth application-default login --no-launch-browser
```

Other coding agent CLIs can be installed and authenticated in the workspace terminal.

### Persistent state

Everything that should survive a workspace restart lives under `/projects/.che-orca`, symlinked into `$HOME`:

| Path | Contents |
| --- | --- |
| `orca-home/` | Orca user data, set by `ORCA_USER_DATA` |
| `opencode-config/`, `opencode-share/`, `opencode-state/` | OpenCode configuration, data, and state |
| `gcloud/` | Google Cloud SDK configuration and credentials |
| `ready.jsonl` | Readiness stream, including the pairing URL |

## Remove a deployment

```bash
./teardown.sh
```

Teardown removes the workspace, editor template, direct Service, and Route in `NAMESPACE`. Storage retention follows your cluster's DevWorkspace policy, so back up anything you need from `/projects` first.

## Cluster-wide registration

`deploy.sh` creates a template in your own namespace. To add Orca to the dashboard editor picker for everyone, set `NAMESPACE` to the Che installation namespace and run:

```bash
make register
```

Remove it with `make unregister`. Manual registration also needs `ORCA_PAIRING_ADDRESS` set to a reachable `wss://` endpoint. The deployment script calculates that address automatically. Restore your user namespace in `config.env` before deploying or tearing down a workspace.

## Versions and limitations

The Containerfile pins Orca to v1.4.219 and OpenCode to 1.18.34. Update those version declarations when testing a newer release. Base images, the Google Cloud SDK download, and the universal developer image tag still follow moving releases, so builds are not fully reproducible.

Orca v1.4.219 needs [`web-client.patch`](web-client.patch) to serve its web client (`webClientRoot`) and to initialize the terminal graph, which a standalone server has no renderer to publish.

The image targets `linux/amd64`. The builder stage runs on the host architecture (`--platform=$BUILDPLATFORM`) and cross-compiles the `orcad` runtime, because esbuild fails under amd64 emulation on ARM machines.

The entrypoint restarts the server after two seconds if it exits. Exit code 78 is treated as a configuration error and is not retried.

## Repository layout

```
Containerfile                   multi-stage build: Orca runtime + web client, OpenCode, gcloud
devfile.yaml                    injector and runtime components, preStart/postStart events
deploy.sh                       build, push, Route, template, workspace, pairing URL
teardown.sh                     remove workspace, template, Service, Route
entrypoint-init-container.sh    copies the runtime onto the /orca volume
entrypoint.sh                   persistent state, model discovery, starts orcad on 6768
web-client.patch                upstream patch applied during the build
shared/                         deploy helpers, devfile renderer, runtime setup, KServe discovery
tests/                          unit tests with mocked cluster and build commands
config.env.example              documented local configuration
Makefile                        build, push, and admin registration targets
```

Changes to the editor components, commands, and events belong in `devfile.yaml`. Deployment and admin registration use the same renderer, which substitutes configuration values and preserves runtime variables such as `$PATH`.

For local changes, check Bash syntax and run ShellCheck before testing a deployment. Keep credentials and rendered devfiles out of commits.

```bash
python3 -m unittest discover -s tests
```

The tests mock cluster and build commands and require Bash and Node.js.

## License

The integration code is licensed under [MIT](LICENSE). [Orca](https://github.com/stablyai/orca) and [OpenCode](https://github.com/anomalyco/opencode) keep their own licenses. This integration applies a small patch to Orca and includes its [upstream license](https://github.com/stablyai/orca/blob/v1.4.219/LICENSE) in the runtime image. Preserve upstream license files and notices when redistributing images.
