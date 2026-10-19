"""Render an editor devfile or wrap its spec in a DevWorkspaceTemplate."""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


IMAGE_VARIABLES = {"ORCA_IMAGE"}
PLACEHOLDER = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
TOP_LEVEL_KEY = re.compile(r"^([A-Za-z][\w-]*):")
# Devfile keys that are not part of a DevWorkspaceTemplate spec.
NON_SPEC_KEYS = {"schemaVersion", "metadata"}


def substitute(text, environment):
    def replace(match):
        name = match[1]
        if name in IMAGE_VARIABLES:
            if not environment.get(name):
                raise ValueError(f"Set {name} in config.env")
            return environment[name]
        return match[0]
    return PLACEHOLDER.sub(replace, text)


def wrap_template(text, template_name):
    # Indent every top-level block except schemaVersion and metadata under spec.
    spec = []
    keep = True
    for line in text.splitlines():
        key = TOP_LEVEL_KEY.match(line)
        if key:
            keep = key[1] not in NON_SPEC_KEYS
        if keep:
            spec.append(f"  {line}" if line.strip() else "")
    header = [
        "apiVersion: workspace.devfile.io/v1alpha2",
        "kind: DevWorkspaceTemplate",
        "metadata:",
        f"  name: {template_name}",
        "spec:",
    ]
    return "\n".join(header + spec).rstrip() + "\n"


def render(path, environment, template_name=None):
    text = Path(path).read_text()
    if not re.search(r"^components:\s*\n\s+- ", text, re.MULTILINE):
        raise ValueError("The devfile must contain a nonempty components list")
    text = substitute(text, environment)
    if template_name:
        text = wrap_template(text, template_name)
    return text


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
        text = render(args.devfile, os.environ, args.template)
        if args.check:
            return
        if args.output:
            write_output(args.output, text)
        else:
            sys.stdout.write(text)
    except (OSError, ValueError) as error:
        sys.exit(f"render-devfile: {error}")


if __name__ == "__main__":
    main()
