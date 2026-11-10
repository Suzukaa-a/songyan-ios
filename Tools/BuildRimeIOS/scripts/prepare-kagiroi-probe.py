#!/usr/bin/env python3
"""Stage offline kagiroi deployment fixtures from pinned, extracted archives.

Usage: prepare-kagiroi-probe.py --source SOURCE (--prebuilt BUILD | --source-only) --output NEW_DIRECTORY
The prebuilt comparison retains upstream nico entries; it is experimental data.
"""

import argparse
import json
import shutil
from pathlib import Path


def prepare(source: Path, binary: Path | None, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=False)
    modes = ("source",) if binary is None else ("source", "prebuilt")
    for mode in modes:
        destination = output / mode
        destination.mkdir()
        for path in sorted(source.iterdir()):
            if path.name in ("lua", "opencc"):
                if path.name == "lua":
                    target = destination / "lua/kagiroi"
                    target.mkdir(parents=True)
                    for script in sorted((path / "kagiroi").glob("*.lua")):
                        shutil.copy2(script, target / script.name)
                else:
                    shutil.copytree(path, destination / path.name)
            elif path.is_file() and (
                path.name.startswith("kagiroi") and path.suffix in (".yaml", ".txt")
                or path.name in ("default.yaml", "punctuation.yaml", "key_bindings.yaml")
            ):
                if path.name == "kagiroi.nico.dict.yaml":
                    continue
                if mode == "prebuilt" and path.name.endswith(".dict.yaml"):
                    continue
                if path.name == "kagiroi.dict.yaml":
                    text = path.read_text(encoding="utf-8")
                    text = "".join(line for line in text.splitlines(keepends=True) if line.strip() != "- kagiroi.nico")
                    (destination / path.name).write_text(text, encoding="utf-8")
                else:
                    shutil.copy2(path, destination / path.name)
    if binary is not None:
        build = output / "prebuilt/build"
        build.mkdir()
        for path in sorted((binary / "build").glob("*.bin")):
            shutil.copy2(path, build / path.name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prebuilt", type=Path)
    mode.add_argument("--source-only", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (args.source / "kagiroi.schema.yaml").is_file():
        parser.error("source archive is missing kagiroi.schema.yaml")
    if args.prebuilt is not None and not (args.prebuilt / "build/kagiroi.table.bin").is_file():
        parser.error("prebuilt archive is missing build/kagiroi.table.bin")
    prepare(args.source, args.prebuilt, args.output)
    print(json.dumps({
        mode: sum(path.stat().st_size for path in (args.output / mode).rglob("*") if path.is_file())
        for mode in (("source",) if args.source_only else ("source", "prebuilt"))
    }))


if __name__ == "__main__":
    main()
