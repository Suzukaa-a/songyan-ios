#!/usr/bin/env python3
"""Writes every retired version of a bundled layout from git history.

A saved layout catalog stores each bundled layout in full, and a stored copy wins over the bundled
definition. A fix to a bundled layout would therefore never reach a device that already saved a
catalog. LayoutRegistry replaces a stored built-in that equals one of these retired versions with
the current definition, and keeps one that matches nothing, since that is a user edit.

The bundled ids are the stems of Resources/Layouts/*.json. For each, every version already in
Resources/Layouts/retired/builtin-layouts.json and every version in the history of HEAD that
differs from the working-tree file is written, deduplicated by normalized JSON and sorted, as
{"<id>": [<layout>, ...]}. Versions are only ever added: some shipped from history that a clone
does not have, and a device may still store them.
A copy goes into the LayoutKit package so the library can load it from its own bundle.

Usage:
  python3 Tools/Layouts/gen_retired_layouts.py          # rewrite both files
  python3 Tools/Layouts/gen_retired_layouts.py --check  # exit 1 when either file is stale
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYOUTS = ROOT / "Resources/Layouts"
OUTPUTS = [
    LAYOUTS / "retired/builtin-layouts.json",
    ROOT / "Packages/LayoutKit/Sources/LayoutKit/Resources/RetiredBuiltinLayouts.json",
]

RETIRED = json.loads(OUTPUTS[0].read_text(encoding="utf-8")) if OUTPUTS[0].exists() else {}


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True
    ).stdout


def normalized(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def retired_versions(layout_id: str) -> list[object]:
    path = f"Resources/Layouts/{layout_id}.json"
    current = normalized(json.loads((ROOT / path).read_text(encoding="utf-8")))
    found = {normalized(v) for v in RETIRED.get(layout_id, [])}
    for commit in git("log", "HEAD", "--format=%H", "--", path).split():
        try:
            text = git("show", f"{commit}:{path}")
        except subprocess.CalledProcessError:
            continue  # the commit deleted the file
        try:
            version = normalized(json.loads(text))
        except json.JSONDecodeError:
            continue
        found.add(version)
    found.discard(current)
    return [json.loads(version) for version in sorted(found)]


def render() -> str:
    ids = sorted(p.stem for p in LAYOUTS.glob("*.json"))
    lines = []
    for layout_id in ids:
        versions = retired_versions(layout_id)
        if not versions:
            continue
        body = ",\n".join(
            "    " + json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            for v in versions
        )
        lines.append(f"  {json.dumps(layout_id)}: [\n{body}\n  ]")
    return "{\n" + ",\n".join(lines) + "\n}\n"


def main() -> int:
    text = render()
    if "--check" in sys.argv[1:]:
        stale = [p for p in OUTPUTS if not p.exists() or p.read_text(encoding="utf-8") != text]
        for p in stale:
            print(f"stale: {p.relative_to(ROOT)}; run Tools/Layouts/gen_retired_layouts.py", file=sys.stderr)
        return 1 if stale else 0
    for p in OUTPUTS:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
