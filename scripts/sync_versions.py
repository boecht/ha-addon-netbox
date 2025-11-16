#!/usr/bin/env python3
"""Sync pinned NetBox/plugin versions from versions.yaml into build artifacts."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Dict, List

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSIONS_FILE = REPO_ROOT / "versions.yaml"
DOCKERFILE = REPO_ROOT / "netbox" / "Dockerfile"
BUILD_YAML = REPO_ROOT / "netbox" / "build.yaml"
CHANGELOG = REPO_ROOT / "netbox" / "CHANGELOG.md"

PLUGIN_PIP_NAMES = {
    "netbox_topology_views": "netbox-topology-views",
    "netbox_ping": "netbox-ping",
    "netbox_napalm_plugin": "netbox-napalm-plugin",
}


def load_versions() -> Dict:
    if not VERSIONS_FILE.exists():
        raise SystemExit(f"missing {VERSIONS_FILE}")
    return yaml.safe_load(VERSIONS_FILE.read_text())


def rewrite_file(
    path: Path, new_content: str, check: bool, changed: List[Path]
) -> None:
    current = path.read_text()
    if current == new_content:
        return
    if check:
        changed.append(path)
        return
    path.write_text(new_content)


def update_dockerfile(data: Dict) -> str:
    text = DOCKERFILE.read_text()
    netbox_version = data["netbox"]["version"]
    digest_index = data["netbox"]["digest_index"]
    text = re.sub(
        r"ARG BUILD_FROM=.*",
        f"ARG BUILD_FROM=ghcr.io/netbox-community/netbox:{netbox_version}@{digest_index}",
        text,
        count=1,
    )
    for plugin, pip_name in PLUGIN_PIP_NAMES.items():
        version = data["plugins"][plugin]["version"]
        pattern = rf"({re.escape(pip_name)}==)[^\\s\\\\]+"
        text = re.sub(pattern, rf"\\g<1>{version}", text, count=1)
    return text


def update_build_yaml(data: Dict) -> str:
    text = BUILD_YAML.read_text()
    version = data["netbox"]["version"]
    text = re.sub(
        r"(amd64:\s+ghcr\.io/netbox-community/netbox:)\S+",
        rf"\\1{version}",
        text,
        count=1,
    )
    text = re.sub(
        r"(aarch64:\s+ghcr\.io/netbox-community/netbox:)\S+",
        rf"\\1{version}",
        text,
        count=1,
    )
    return text


def update_changelog(data: Dict) -> str:
    netbox_version = data["netbox"]["version"]
    netbox_release = netbox_version.split("-")[0]
    lines = ["# Changelog", "", "## [1.0.0] - Upcoming", ""]
    lines.append(f"- Ships NetBox {netbox_release} (container tag `{netbox_version}`).")
    lines.append("- Bundled plugins:")
    for key in sorted(PLUGIN_PIP_NAMES):
        version = data["plugins"][key]["version"]
        pypi_url = data["plugins"][key]["pypi"]
        display_name = PLUGIN_PIP_NAMES[key]
        lines.append(f"  - [`{display_name}`]({pypi_url}) v{version}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="only verify files are in sync"
    )
    args = parser.parse_args()

    data = load_versions()
    changed: List[Path] = []

    rewrite_file(DOCKERFILE, update_dockerfile(data), args.check, changed)
    rewrite_file(BUILD_YAML, update_build_yaml(data), args.check, changed)
    rewrite_file(CHANGELOG, update_changelog(data), args.check, changed)

    if args.check and changed:
        rel = "\n".join(str(path.relative_to(REPO_ROOT)) for path in changed)
        raise SystemExit("Versions out of sync in:\n" + rel)


if __name__ == "__main__":
    main()
