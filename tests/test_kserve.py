"""Local discovery checks. Run with python3 -m unittest discover -s tests."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class KServeDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kserve-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.output = self.root / "opencode.json"
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            REDHAT_AI_NAMESPACE="test-models",
            TEST_MODELS="isvc-code-model isvc-offline",
            TEST_OC_LOG=str(self.root / "oc.log"),
            TEST_CURL_LOG=str(self.root / "curl.log"),
        )
        self.stub(
            "oc",
            'printf "%s\\n" "$*" >> "$TEST_OC_LOG"\n'
            'if [ "$1" = get ]; then printf "%s" "$TEST_MODELS"; fi',
        )
        self.stub(
            "cat",
            'if [ "$1" = /run/secrets/kubernetes.io/serviceaccount/token ]; then\n'
            '  printf "%s\\n" test-service-token\n'
            'else\n'
            '  exec /bin/cat "$@"\n'
            'fi',
        )
        self.stub(
            "curl",
            'printf "%s\\n" "${*: -1}" >> "$TEST_CURL_LOG"\n'
            'case "${*: -1}" in\n'
            '  *isvc-code-model-predictor*) '
            "printf '%s\\n' "
            "'{\"data\":[{\"id\":\"served-model\",\"max_model_len\":32768}]}' ;;\n"
            '  *) exit 22 ;;\n'
            'esac',
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/bash\n{body}\n")
        path.chmod(0o755)

    def discover(self):
        return subprocess.run(
            ["bash", str(REPO / "shared/discover-models.sh"), str(self.output)],
            env=self.env, capture_output=True, text=True,
        )


    def test_discovers_models_without_overriding_tools_or_permissions(self):
        result = self.discover()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.output.read_text())
        self.assertNotIn("tools", config)
        self.assertNotIn("permission", config)
        self.assertEqual(config["model"], "redhat/code-model")
        provider = config["provider"]["redhat"]
        self.assertEqual(set(provider["models"]), {"code-model"})
        model = provider["models"]["code-model"]
        self.assertEqual(model["id"], "served-model")
        self.assertEqual(model["limit"]["context"], 32768)
        self.assertEqual(
            model["provider"]["api"],
            "https://isvc-code-model-predictor.test-models.svc.cluster.local:8443/v1",
        )
        self.assertEqual(
            provider["options"]["apiKey"],
            "{file:/run/secrets/kubernetes.io/serviceaccount/token}",
        )
        self.assertNotIn("test-service-token", self.output.read_text())
        self.assertNotIn("test-service-token", result.stdout + result.stderr)
        self.assertIn("-n test-models", (self.root / "oc.log").read_text())

    def test_discovery_replaces_legacy_tool_restrictions(self):
        self.output.write_text('{"tools":{"bash":false,"edit":false}}')
        self.assertEqual(self.discover().returncode, 0)
        self.assertNotIn("tools", json.loads(self.output.read_text()))

    def test_missing_namespace_skips_cluster_access_and_preserves_config(self):
        original = '{"provider":{"manual":{"name":"My provider"}}}\n'
        self.output.write_text(original)
        for namespace in (None, ""):
            with self.subTest(namespace=namespace):
                if namespace is None:
                    self.env.pop("REDHAT_AI_NAMESPACE", None)
                else:
                    self.env["REDHAT_AI_NAMESPACE"] = namespace
                result = self.discover()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("REDHAT_AI_NAMESPACE not set, skipping", result.stdout)
                self.assertEqual(self.output.read_text(), original)
                self.assertFalse((self.root / "oc.log").exists())
                self.assertFalse((self.root / "curl.log").exists())

    def test_no_services_preserves_existing_config(self):
        original = '{"provider":{"manual":{"name":"My provider"}}}\n'
        self.output.write_text(original)
        self.env["TEST_MODELS"] = ""
        result = self.discover()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), original)

    def test_cluster_error_preserves_config_and_reports_access_failure(self):
        original = '{"provider":{"manual":{"name":"My provider"}}}\n'
        self.output.write_text(original)
        self.stub("oc", 'echo "server unavailable" >&2; exit 1')
        result = self.discover()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), original)
        self.assertIn("cannot list InferenceServices in test-models", result.stderr)
        self.assertNotIn("no InferenceServices", result.stdout + result.stderr)

    def test_unreachable_services_do_not_create_config(self):
        self.env["TEST_MODELS"] = "isvc-offline"
        result = self.discover()
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
