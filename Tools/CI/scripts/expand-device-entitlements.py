#!/usr/bin/env python3
"""Expand Xcode build settings in device entitlements before ad-hoc signing.

package-ipa.sh signs the built app with codesign, which does not expand build settings. Historically
only $(SONGYAN_APP_GROUP) was resolved with sed, so the Keychain sharing group added for scripts
($(AppIdentifierPrefix)group.app.songyan.shared) would ship as literal text. This helper expands every
build setting the entitlements use and fails closed: a missing/unknown setting, or a Team ID that is
absent or not ten uppercase letters/digits, is an error instead of a literal output.

Team ID comes from --team-id or the TEAMID environment variable (release workflows set it from a
repository variable); it is required because AppIdentifierPrefix is an Xcode signing setting, not an
Identity.xcconfig entry.

Usage:
  expand-device-entitlements.py --output-dir DIR [--team-id TEAM] [--root REPO]
"""
from __future__ import annotations

import argparse
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTING = re.compile(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)")
TEAM_ID = re.compile(r"[A-Z0-9]{10}")
TARGETS = ("HostApp", "KeyboardExtension")
APP_GROUP_KEY = "com.apple.security.application-groups"


def identity_settings(root: Path) -> dict[str, str]:
    """Config/Identity.xcconfig plus the optional git-ignored Local.xcconfig."""
    settings: dict[str, str] = {}
    for name in ("Identity.xcconfig", "Local.xcconfig"):
        path = root / "Config" / name
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*", line)
            if match:
                settings[match.group(1)] = match.group(2)
    return settings


def resolve_team_id(value: str | None) -> str:
    """The signing team prefix for AppIdentifierPrefix; missing or invalid is never guessed."""
    team = (value or "").strip()
    if not team:
        raise ValueError("TEAMID is required to expand $(AppIdentifierPrefix) for ad-hoc signing")
    if not TEAM_ID.fullmatch(team):
        raise ValueError(f"TEAMID '{team}' is not ten uppercase letters/digits")
    return team


def expand_value(value, settings: dict[str, str]):
    if isinstance(value, str):
        return SETTING.sub(lambda match: settings.get(match.group(1), match.group(0)), value)
    if isinstance(value, list):
        return [expand_value(item, settings) for item in value]
    if isinstance(value, dict):
        return {key: expand_value(item, settings) for key, item in value.items()}
    return value


def require_expanded(value, where: str) -> None:
    if isinstance(value, str):
        if "$(" in value:
            raise ValueError(f"unexpanded build setting in {where}: {value}")
    elif isinstance(value, list):
        for item in value:
            require_expanded(item, where)
    elif isinstance(value, dict):
        for item in value.values():
            require_expanded(item, where)


def expanded_entitlements(
    source: Path, settings: dict[str, str], where: str
) -> dict:
    with source.open("rb") as handle:
        data = plistlib.load(handle)
    expanded = expand_value(data, settings)
    require_expanded(expanded, where)
    groups = expanded.get(APP_GROUP_KEY)
    if not groups or not all(isinstance(group, str) and group.startswith("group.") for group in groups):
        raise ValueError(f"{where} has no usable {APP_GROUP_KEY}")
    return expanded


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--team-id", default=os.environ.get("TEAMID"))
    args = parser.parse_args(argv)
    try:
        team = resolve_team_id(args.team_id)
        settings = identity_settings(args.root)
        app_group = settings.get("SONGYAN_APP_GROUP")
        if not app_group:
            raise ValueError("SONGYAN_APP_GROUP missing from Config/Identity.xcconfig")
        settings["AppIdentifierPrefix"] = f"{team}."
        args.output_dir.mkdir(parents=True, exist_ok=True)
        for target in TARGETS:
            source = args.root / "Apps" / target / f"{target}.entitlements"
            expanded = expanded_entitlements(source, settings, target)
            destination = args.output_dir / f"{target}.entitlements"
            with destination.open("wb") as handle:
                plistlib.dump(expanded, handle, sort_keys=True)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"package-ipa: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
