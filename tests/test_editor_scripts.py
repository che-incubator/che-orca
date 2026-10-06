"""Exercise editor scripts with local command stubs and temporary configuration."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


REPO = Path(__file__).resolve().parents[1]
EDITORS = {
    "orca": ("orca-direct", 6768, "180s"),
}


def workspace_pod(name="workspace-pod", *, ready=True, created="2026-10-03T12:00:00Z", phase="Running", deleting=False):
    metadata = {"name": name, "creationTimestamp": created}
    if deleting:
        metadata["deletionTimestamp"] = "2026-10-03T12:01:00Z"
    return {"metadata": metadata, "status": {
        "phase": phase,
        "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
    }}


class EditorScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="editor scripts ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "shared").mkdir()
        shutil.copyfile(REPO / "shared/deploy.sh", self.root / "shared/deploy.sh")
        shutil.copyfile(REPO / "shared/render-devfile.py", self.root / "shared/render-devfile.py")
        shutil.copyfile(REPO / "Makefile", self.root / "Makefile")
        for editor in EDITORS:
            for name in ("deploy.sh", "teardown.sh", "devfile.yaml"):
                shutil.copyfile(REPO / name, self.root / name)
        (self.root / "config.env").write_text(
            "NAMESPACE=test-workspaces\n"
            "ORCA_IMAGE=localhost/test-orca\n"
            "GOOGLE_CLOUD_PROJECT=test-project\n"
            "CLOUD_ML_REGION=test-region\n"
            "REDHAT_AI_NAMESPACE=test-models\n"
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{Path(sys.executable).parent}{os.pathsep}{os.environ['PATH']}",
            TEST_COMMAND_LOG=str(self.log),
        )
        self.pods = self.root / "pods.json"
        self.env["TEST_PODS"] = str(self.pods)
        self.set_workspace_pods(
            workspace_pod("cleanup-job", created="2026-10-03T12:02:00Z"),
            workspace_pod("old-pod", created="2026-10-03T12:02:00Z", deleting=True),
            workspace_pod("completed-pod", created="2026-10-03T12:02:00Z", phase="Succeeded"),
            workspace_pod("failed-pod", created="2026-10-03T12:02:00Z", phase="Failed"),
            workspace_pod(),
            workspace_pod("another-pod", ready=False, created="2026-10-03T11:00:00Z"),
        )
        stub = f"#!{sys.executable}\n" + '''
import json, os, sys, time
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
entry = {"tool": tool, "args": args}
if tool == "oc" and args[0] == "apply":
    entry["manifest"] = sys.stdin.read()
with open(os.environ["TEST_COMMAND_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
if tool == "oc":
    if args[:2] == ["get", "pods"]:
        if os.environ.get("TEST_PODS_FAILURE"):
            print("Error from server (Forbidden): pods is forbidden", file=sys.stderr)
            sys.exit(1)
        pods = json.loads(Path(os.environ["TEST_PODS"]).read_text())
        if "--sort-by=.metadata.creationTimestamp" in args:
            pods.sort(key=lambda pod: pod["metadata"]["creationTimestamp"])
        for pod in pods:
            if "--field-selector=status.phase=Running" in args and pod["status"]["phase"] != "Running":
                continue
            ready = next((condition["status"] for condition in pod["status"]["conditions"]
                          if condition["type"] == "Ready"), "")
            print(pod["metadata"]["name"], ready, pod["metadata"].get("deletionTimestamp", ""), sep="\\t")
    elif args[0] == "wait":
        time.sleep(float(os.environ.get("TEST_CREATE_DELAY", "0")))
        if os.environ.get("TEST_CREATE_FAILURE"):
            print(os.environ["TEST_CREATE_FAILURE"], file=sys.stderr)
            sys.exit(1)
        print("deployment.apps/workspace-id")
    elif args[:2] == ["rollout", "status"]:
        time.sleep(float(os.environ.get("TEST_ROLLOUT_DELAY", "0")))
        if os.environ.get("TEST_ROLLOUT_FAILURE"):
            print(os.environ["TEST_ROLLOUT_FAILURE"], file=sys.stderr)
            sys.exit(1)
        print('deployment "workspace-id" successfully rolled out')
    elif args[:2] == ["get", "pod"]:
        print("workspace-id")
    elif args[:2] == ["get", "route"]:
        print("editor.test.example")
    elif args[0] == "exec":
        print("https://editor.test.example/paired" if "node" in args else "test-token")
elif tool == "podman" and os.environ.get("TEST_BUILD_FAILURE"):
    sys.exit(1)
'''
        for tool in ("oc", "podman"):
            path = self.bin / tool
            path.write_text(stub)
            path.chmod(0o755)
        sleep = self.bin / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)

    def set_workspace_pods(self, *pods):
        self.pods.write_text(json.dumps(pods))

    def command_log(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def run_script(self, editor, name):
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(self.root / name)],
            cwd=self.bin,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return result, self.command_log()

    def wait_for_workspace(self, timeout="1s"):
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", "-ec", 'source "$1"; NAMESPACE=test-workspaces; wait_for_workspace orca-workspace "$2"; echo "Ready pod: $POD"',
             "test", str(self.root / "shared/deploy.sh"), timeout],
            env=self.env, capture_output=True, text=True, timeout=5,
        )
        return result, self.command_log()

    def test_deployment_keep_resource_names_ports_and_order(self):
        for editor, (route, port, timeout) in EDITORS.items():
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(commands[0]["args"][0], "build")
                self.assertEqual(commands[1]["args"][0], "push")
                manifests = [entry["manifest"] for entry in commands if "manifest" in entry]
                self.assertEqual(len(manifests), 3)
                template = next(value for value in manifests if "kind: DevWorkspaceTemplate\n" in value)
                workspace = next(value for value in manifests if "kind: DevWorkspace\n" in value)
                direct_route = next(value for value in manifests if "kind: Route\n" in value)
                self.assertIn(f"name: {editor}-editor\n", template)
                self.assertIn(f"name: {editor}-workspace\n", workspace)
                self.assertIn(f"name: {route}\n", direct_route)
                self.assertIn(f"targetPort: {port}\n", direct_route)
                self.assertIn("insecureEdgeTerminationPolicy: Redirect", direct_route)
                components = yaml.safe_load(template)["spec"]["components"]
                runtime = next(component for component in components
                               if component["name"] == f"{editor}-runtime")
                self.assertIn({"name": "REDHAT_AI_NAMESPACE", "value": "test-models"}, runtime["container"]["env"])
                self.assertIs(manifests[0], direct_route)
                self.assertIn("wss://editor.test.example/", template)
                self.assertIn("controller.devfile.io/devworkspace_name: orca-workspace", direct_route)
                polls = [entry["args"] for entry in commands if entry["tool"] == "oc" and entry["args"][:2] == ["get", "pods"]]
                self.assertEqual(len(polls), 1)
                self.assertIn(f"controller.devfile.io/devworkspace_name={editor}-workspace", polls[0])
                self.assertIn("--field-selector=status.phase=Running", polls[0])
                request_timeout = next(arg for arg in polls[0] if arg.startswith("--request-timeout="))
                self.assertGreater(int(request_timeout.split("=")[1][:-1]), 0)
                self.assertLessEqual(int(request_timeout.split("=")[1][:-1]), int(timeout[:-1]))
                self.assertIn("Pod ready: workspace-pod", result.stdout)
                waits = [entry["args"] for entry in commands if entry["args"][0] == "wait"]
                self.assertEqual(len(waits), 1)
                self.assertIn("--for=create", waits[0])
                self.assertIn("deployment", waits[0])
                self.assertIn(f"--timeout={timeout}", waits[0])
                rollouts = [entry["args"] for entry in commands if entry["args"][:2] == ["rollout", "status"]]
                self.assertEqual(len(rollouts), 1)
                self.assertIn("deployment.apps/workspace-id", rollouts[0])
                steps = [entry["args"][:2] for entry in commands]
                self.assertLess(steps.index(["rollout", "status"]), steps.index(["get", "pods"]))
                for entry in commands:
                    if entry["tool"] == "oc":
                        self.assertEqual(entry["args"][entry["args"].index("-n") + 1], "test-workspaces")

    def test_deployment_leave_model_namespace_empty_when_unconfigured(self):
        config = self.root / "config.env"
        original = config.read_text()
        self.env.pop("REDHAT_AI_NAMESPACE", None)
        for setting in ("", "REDHAT_AI_NAMESPACE=\n"):
            config.write_text(original.replace("REDHAT_AI_NAMESPACE=test-models\n", setting))
            for editor in EDITORS:
                with self.subTest(editor=editor, setting=setting):
                    result, commands = self.run_script(editor, "deploy.sh")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    template = next(entry["manifest"] for entry in commands
                                    if "kind: DevWorkspaceTemplate\n" in entry.get("manifest", ""))
                    components = yaml.safe_load(template)["spec"]["components"]
                    runtime = next(component for component in components
                                   if component["name"] == f"{editor}-runtime")
                    self.assertIn({"name": "REDHAT_AI_NAMESPACE", "value": ""}, runtime["container"]["env"])

    def register_devfile(self, editor):
        result = subprocess.run(
            ["make", "devfile"], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "devfile-rendered.yaml"
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        return yaml.safe_load(output.read_text())

    def test_deployment_and_registration_share_devfile_spec_and_defaults(self):
        config = self.root / "config.env"
        config.write_text(config.read_text().replace("REDHAT_AI_NAMESPACE=test-models\n", ""))
        self.env.pop("REDHAT_AI_NAMESPACE", None)
        self.env["ORCA_PAIRING_ADDRESS"] = "wss://editor.test.example/"
        for editor in EDITORS:
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                template = next(yaml.safe_load(entry["manifest"]) for entry in commands if "manifest" in entry and "kind: DevWorkspaceTemplate\n" in entry["manifest"])
                registered = self.register_devfile(editor)
                self.assertIn("schemaVersion", registered)
                self.assertIn("displayName", registered["metadata"])
                spec = {key: value for key, value in registered.items() if key not in ("schemaVersion", "metadata")}
                self.assertEqual(template["spec"], spec)
                runtime = next(component["container"] for component in spec["components"] if "endpoints" in component.get("container", {}))
                self.assertEqual(runtime["endpoints"][0]["attributes"]["type"], "main")
                self.assertIn({"name": "REDHAT_AI_NAMESPACE", "value": ""}, runtime["env"])

    def test_devfile_edits_reach_both_deployment_and_registration(self):
        for editor in EDITORS:
            with self.subTest(editor=editor):
                path = self.root / "devfile.yaml"
                source = yaml.safe_load(path.read_text())
                runtime = next(component for component in source["components"] if "endpoints" in component.get("container", {}))
                runtime["container"]["memoryLimit"] = "8192Mi"
                command = {"id": "test-start", "exec": {"component": runtime["name"], "commandLine": 'echo "$PATH ${RUNTIME_ONLY}"'}}
                source.setdefault("commands", []).append(command)
                source.setdefault("events", {}).setdefault("postStart", []).append("test-start")
                path.write_text(yaml.safe_dump(source, sort_keys=False))
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                template = next(yaml.safe_load(entry["manifest"]) for entry in commands if "manifest" in entry and "kind: DevWorkspaceTemplate\n" in entry["manifest"])
                registered = self.register_devfile(editor)
                for spec in (template["spec"], registered):
                    rendered_runtime = next(component for component in spec["components"] if component["name"] == runtime["name"])
                    self.assertEqual(rendered_runtime["container"]["memoryLimit"], "8192Mi")
                    self.assertIn(command, spec["commands"])
                    self.assertIn("test-start", spec["events"]["postStart"])

    def test_invalid_devfile_stops_before_build_or_cluster_commands(self):
        for editor in EDITORS:
            with self.subTest(editor=editor):
                (self.root / "devfile.yaml").write_text("components: invalid\n")
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, [])

    def test_failed_render_preserves_existing_registration_file(self):
        output = self.root / "devfile-rendered.yaml"
        output.write_text("previous config\n")
        (self.root / "devfile.yaml").write_text("components: [\n")
        result = subprocess.run(["make", "devfile"], cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), "previous config\n")

    def test_teardown_only_removes_orca_resources(self):
        for editor, (route, _, _) in EDITORS.items():
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "teardown.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([entry["args"] for entry in commands], [
                    ["delete", kind, name, "-n", "test-workspaces", "--ignore-not-found"]
                    for kind, name in (
                        ("devworkspace", f"{editor}-workspace"),
                        ("devworkspacetemplate", f"{editor}-editor"),
                        ("service", route),
                        ("route", route),
                    )
                ])

    def test_missing_namespace_stops_before_external_commands(self):
        (self.root / "config.env").write_text("NAMESPACE=\n")
        for editor in EDITORS:
            for name in ("deploy.sh", "teardown.sh"):
                with self.subTest(editor=editor, script=name):
                    result, commands = self.run_script(editor, name)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(commands, [])

    def test_failed_build_does_not_push_or_create_resources(self):
        self.env["TEST_BUILD_FAILURE"] = "1"
        for editor in EDITORS:
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(commands), 1)
                self.assertEqual(commands[0]["args"][0], "build")

    def test_pod_query_failure_stops_before_pairing(self):
        self.env["TEST_PODS_FAILURE"] = "1"
        for editor in EDITORS:
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands[-1]["args"][:2], ["get", "pods"])
                self.assertIn("Forbidden", result.stderr)

    def test_replaced_pod_is_used_for_orca_pairing(self):
        self.set_workspace_pods(
            workspace_pod("old-pod", deleting=True),
            workspace_pod("replacement-pod"),
        )
        result, commands = self.run_script("orca", "deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Pod ready: replacement-pod", result.stdout)
        polls = [index for index, entry in enumerate(commands) if entry["args"][:2] == ["get", "pods"]]
        rollout = next(index for index, entry in enumerate(commands) if entry["args"][:2] == ["rollout", "status"])
        self.assertEqual(len(polls), 1)
        self.assertGreater(polls[0], rollout)
        execs = [entry["args"] for entry in commands if entry["args"][0] == "exec"]
        self.assertTrue(execs)
        self.assertTrue(all("replacement-pod" in args for args in execs))

    def test_failed_rollout_stops_before_pod_lookup_and_pairing(self):
        self.env["TEST_ROLLOUT_FAILURE"] = "error: timed out waiting for the condition"
        for editor in EDITORS:
            with self.subTest(editor=editor):
                result, commands = self.run_script(editor, "deploy.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands[-1]["args"][:2], ["rollout", "status"])
                self.assertIn("timed out", result.stderr)

    def test_newest_ready_pod_is_selected_after_rollout(self):
        self.set_workspace_pods(
            workspace_pod("replacement-pod"),
            workspace_pod("old-pod", created="2026-10-03T11:00:00Z"),
        )
        result, _ = self.wait_for_workspace("5s")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ready pod: replacement-pod", result.stdout)

    def test_deployment_creation_errors_stop_before_rollout(self):
        for error in ("Error from server (Forbidden): deployments is forbidden",
                      "error: timed out waiting for the condition"):
            with self.subTest(error=error):
                self.env["TEST_CREATE_FAILURE"] = error
                result, commands = self.wait_for_workspace()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(commands), 1)
                self.assertEqual(commands[0]["args"][0], "wait")
                self.assertIn(error, result.stderr)

    def test_missing_ready_pod_after_rollout_fails(self):
        for pods in ((), (workspace_pod(ready=False),), (workspace_pod(deleting=True),)):
            with self.subTest(pods=pods):
                self.set_workspace_pods(*pods)
                result, commands = self.wait_for_workspace("5s")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No active ready pod", result.stderr)
                self.assertEqual(commands[-1]["args"][:2], ["get", "pods"])
                self.assertNotIn("Ready pod:", result.stdout)

    def test_creation_and_rollout_share_one_timeout(self):
        self.env["TEST_CREATE_DELAY"] = "1.1"
        self.env["TEST_ROLLOUT_FAILURE"] = "error: timed out waiting for the condition"
        result, commands = self.wait_for_workspace("3s")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--timeout=3s", commands[0]["args"])
        rollout = commands[-1]["args"]
        self.assertEqual(rollout[:2], ["rollout", "status"])
        timeout = next(arg.split("=")[1] for arg in rollout if arg.startswith("--timeout="))
        self.assertGreater(int(timeout[:-1]), 0)
        self.assertLess(int(timeout[:-1]), 3)
        self.assertIn(f"--request-timeout={timeout}", rollout)

    def test_exhausted_timeout_does_not_start_another_wait(self):
        for delay, last_command in (("TEST_CREATE_DELAY", "wait"), ("TEST_ROLLOUT_DELAY", "rollout")):
            with self.subTest(delay=delay):
                self.env.pop("TEST_CREATE_DELAY", None)
                self.env.pop("TEST_ROLLOUT_DELAY", None)
                self.env[delay] = "1.1"
                result, commands = self.wait_for_workspace()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("was not ready within 1s", result.stderr)
                self.assertEqual(commands[-1]["args"][0], last_command)

    def test_runtime_registers_bashrc_once_with_private_permissions(self):
        home = self.root / "home"
        home.mkdir()
        bashrc = self.root / "shared bashrc.sh"
        bashrc.write_text("export TEST_BASHRC_LOADED=yes\n")
        helper = self.root / "runtime.sh"
        helper.write_text((REPO / "shared/runtime.sh").read_text().replace("$HOME", "$TEST_USER_HOME"))
        env = dict(self.env, TEST_USER_HOME=str(home))
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; setup_runtime "$2"; setup_runtime "$2"; source "$TEST_USER_HOME/.bashrc"; echo "$TEST_BASHRC_LOADED"', "test", str(helper), str(bashrc)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "yes")
        self.assertEqual(len((home / ".bashrc").read_text().splitlines()), 1)
        self.assertEqual((home / ".bashrc").stat().st_mode & 0o777, 0o600)
