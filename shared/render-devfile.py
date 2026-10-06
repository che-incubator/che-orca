"""Render an editor devfile or wrap its spec in a DevWorkspaceTemplate."""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("Install the devfile renderer dependency with: python3 -m pip install -r requirements.txt")


IMAGE_VARIABLES = {"ORCA_IMAGE"}
DEFAULTS = {
    "GOOGLE_CLOUD_PROJECT": "",
    "CLOUD_ML_REGION": "",
    "ORCA_PAIRING_ADDRESS": "",
    "REDHAT_AI_NAMESPACE": "",
}
PLACEHOLDER = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def substitute(value, environment):
    if isinstance(value, str):
        def replace(match):
            name = match[1]
            if name in IMAGE_VARIABLES:
                if not environment.get(name):
                    raise ValueError(f"Set {name} in config.env")
                return environment[name]
            if name in DEFAULTS:
                return environment.get(name) or DEFAULTS[name]
            return match[0]
        return PLACEHOLDER.sub(replace, value)
    if isinstance(value, list):
        return [substitute(item, environment) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, environment) for key, item in value.items()}
    return value


def render(path, environment, template_name=None):
    document = yaml.safe_load(Path(path).read_text())
    if not isinstance(document, dict) or not isinstance(document.get("components"), list) or not document["components"]:
        raise ValueError("The devfile must contain a nonempty components list")
    document = substitute(document, environment)
    if template_name:
        document = {
            "apiVersion": "workspace.devfile.io/v1alpha2",
            "kind": "DevWorkspaceTemplate",
            "metadata": {"name": template_name},
            "spec": {key: value for key, value in document.items() if key not in ("schemaVersion", "metadata")},
        }
    return document


def write_output(path, text):
    path = Path(path)
    temporary = None
    try:
        # The rendered file can contain private configuration. Replace it only after success.
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=f".{path.name}.", delete=False) as output:
            temporary = Path(output.name)
            output.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devfile", type=Path)
    parser.add_argument("--template", help="DevWorkspaceTemplate resource name")
    parser.add_argument("--output", type=Path, help="Write a private rendered file instead of stdout")
    parser.add_argument("--check", action="store_true", help="Validate the devfile and variables without writing output")
    args = parser.parse_args()
    try:
        document = render(args.devfile, os.environ, args.template)
        if args.check:
            return
        text = yaml.safe_dump(document, sort_keys=False, allow_unicode=True)
        if args.output:
            write_output(args.output, text)
        else:
            sys.stdout.write(text)
    except (OSError, ValueError, yaml.YAMLError) as error:
        sys.exit(f"render-devfile: {error}")


if __name__ == "__main__":
    main()
