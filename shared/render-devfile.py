"""Render che-operator's Orca editor definition with a test image, optionally as a DevWorkspaceTemplate."""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


# che-operator's definition pulls the published image; its release flow pins the tag.
PUBLISHED_IMAGE = re.compile(r"quay\.io/che-incubator/che-orca:[\w.-]+")
TOP_LEVEL_KEY = re.compile(r"^([A-Za-z][\w-]*):")
# Devfile keys that are not part of a DevWorkspaceTemplate spec.
NON_SPEC_KEYS = {"schemaVersion", "metadata"}
METADATA_VERSION = re.compile(r"^(    version: ).*$", re.MULTILINE)


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


def render(path, image, template_name=None):
    text = Path(path).read_text()
    if not re.search(r"^components:\s*\n\s+- ", text, re.MULTILINE):
        raise ValueError(f"{path} must contain a nonempty components list")
    if not PUBLISHED_IMAGE.search(text):
        raise ValueError(f"{path} does not reference quay.io/che-incubator/che-orca")
    if not image:
        raise ValueError("Set ORCA_IMAGE in config.env")
    text = PUBLISHED_IMAGE.sub(lambda _: image, text)
    if template_name:
        return wrap_template(text, template_name)
    # The dashboard identifies editors by publisher/name/version; don't shadow che-operator's.
    return METADATA_VERSION.sub(r"\g<1>dev", text, count=1)


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
    parser.add_argument("definition", type=Path, help="che-operator's editors-definitions/che-orca-next.yaml")
    parser.add_argument("--template", help="DevWorkspaceTemplate resource name")
    parser.add_argument("--output", type=Path, help="Write a private rendered file instead of stdout")
    parser.add_argument("--check", action="store_true", help="Validate the definition and variables without writing output")
    args = parser.parse_args()
    try:
        text = render(args.definition, os.environ.get("ORCA_IMAGE"), args.template)
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
