#!/usr/bin/env python3
"""Small registry.toml sanity check for the wave-1 migration branch."""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse


PACK_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$")
REQUIRED_WAVE_1 = {"discord", "gascity", "gastown", "github-intake", "slack"}
FORBIDDEN_WAVE_1 = {"bd", "core", "dolt", "maintenance"}


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    with path.open("rb") as handle:
        data = tomllib.load(handle)

    if data.get("schema", 1) != 1:
        errors.append("schema must be 1")

    packs = data.get("pack", [])
    if not isinstance(packs, list):
        errors.append("[[pack]] entries are required")
        return errors

    seen: set[str] = set()
    for index, pack in enumerate(packs, start=1):
        name = pack.get("name", "")
        label = name or f"entry #{index}"
        if not PACK_NAME_RE.fullmatch(name):
            errors.append(f"{label}: invalid pack name")
        if name in seen:
            errors.append(f'{label}: duplicate pack "{name}"')
        seen.add(name)

        if not pack.get("description"):
            errors.append(f"{label}: description is required")
        if pack.get("source_kind") != "git":
            errors.append(f"{label}: source_kind must be git")

        source = pack.get("source", "")
        parsed = urlparse(source)
        if parsed.scheme != "https" or not parsed.netloc:
            errors.append(f"{label}: source must be an HTTPS git locator")
            continue

        match = re.search(r"\.git//([^#]+)", source)
        if match:
            pack_path = match.group(1)
            pack_toml = path.parent / pack_path / "pack.toml"
            if not pack_toml.exists():
                errors.append(f"{label}: source path {pack_path!r} does not contain pack.toml")
                continue
            try:
                with pack_toml.open("rb") as handle:
                    pack_data = tomllib.load(handle)
            except tomllib.TOMLDecodeError as exc:
                errors.append(f"{label}: source path {pack_path!r} pack.toml is invalid: {exc}")
                continue
            actual_name = pack_data.get("pack", {}).get("name", "")
            if actual_name != name:
                errors.append(f"{label}: registry name does not match {pack_path}/pack.toml name {actual_name!r}")

    missing = REQUIRED_WAVE_1 - seen
    if missing:
        errors.append("missing wave-1 entries: " + ", ".join(sorted(missing)))

    forbidden = FORBIDDEN_WAVE_1 & seen
    if forbidden:
        errors.append("wave-1 registry must not include: " + ", ".join(sorted(forbidden)))

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("registry", nargs="?", default="registry.toml")
    args = parser.parse_args()

    errors = validate(Path(args.registry))
    if errors:
        for error in errors:
            print(f"registry validation failed: {error}", file=sys.stderr)
        return 1

    print(f"{args.registry}: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
