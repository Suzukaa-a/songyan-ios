#!/usr/bin/env python3
"""Generates the Traditional Chinese (zh-Hant) values of every String Catalog.

Every .xcstrings file in the repository uses Simplified Chinese as its source language. Its
zh-Hant values are never authored by hand: this script converts each source value with the
OpenCC 1.1.9 s2twp configuration the app ships, applies the shared Taiwan-wording overrides in
zh-Hant-overrides.json (the same table the Android repository uses), and writes the result back.

Usage:
  Tools/Localization/gen_zh_hant_strings.py            write the zh-Hant values
  Tools/Localization/gen_zh_hant_strings.py --check    compare only, exit 1 on differences

Environment:
  OPENCC_BIN       opencc command to use (default: opencc on PATH, then the pinned macOS engine
                   build at .local/engine/prefix/bin/opencc; it must report Version: 1.1.9)
  OPENCC_DATA_DIR  directory holding s2twp.json (default: Resources/EngineResources/opencc)

Exit codes: 0 finished or every value matches, 1 differences or unconvertible content,
2 missing tool or data.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OVERRIDES = Path(__file__).resolve().parent / "zh-Hant-overrides.json"
DEFAULT_OPENCC_CONFIG = REPO_ROOT / "Resources/EngineResources/opencc/s2twp.json"
SOURCE_LOCALE = "zh-Hans"
TARGET_LOCALE = "zh-Hant"
OPENCC_VERSION = "1.1.9"
EXIT_OK = 0
EXIT_DIFFERENCES = 1
EXIT_ENVIRONMENT = 2
SKIPPED_DIRECTORIES = frozenset({"DerivedData", "Vendored", "node_modules", "build"})


class GenerationError(Exception):
    """The catalog content cannot be converted without losing information."""


class ToolEnvironmentError(Exception):
    """The pinned OpenCC tool or its bundled data is not available."""


class HantDifference(NamedTuple):
    key: str
    expected: str
    actual: str | None
    state: str | None


def ascii_only(text: str) -> str:
    """Everything a conversion must never change: placeholders, digits, escapes and Latin text."""
    return "".join(character for character in text if ord(character) < 0x80)


def load_overrides(path: str | Path | None = None) -> dict:
    """Reads the shared override table; the table is applied longest left side first."""
    overrides_path = Path(path) if path is not None else DEFAULT_OVERRIDES
    try:
        raw = json.loads(overrides_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ToolEnvironmentError(f"cannot read {overrides_path}: {error}") from error
    if not isinstance(raw, dict):
        raise ToolEnvironmentError(f"{overrides_path}: the overrides must be a JSON object")
    rules = _read_rules(raw.get("replacements", []), overrides_path, "replacements")
    rules.sort(key=lambda rule: -len(rule[0]))
    by_key = {}
    raw_by_key = raw.get("byKey", {})
    if not isinstance(raw_by_key, dict):
        raise ToolEnvironmentError(f"{overrides_path}: byKey must be a JSON object")
    for key, pairs in raw_by_key.items():
        by_key[str(key)] = tuple(_read_rules(pairs, overrides_path, f"byKey[{key}]"))
    banned = sorted({left for left, _ in rules}, key=len, reverse=True)
    return {
        "path": overrides_path,
        "replacements": tuple(rules),
        "byKey": by_key,
        "banned": tuple(banned),
        "opencc": raw.get("opencc", {}),
    }


def _read_rules(pairs: object, path: Path, where: str) -> list[tuple[str, str]]:
    if not isinstance(pairs, list):
        raise ToolEnvironmentError(f"{path}: {where} must be a list of [left, right] pairs")
    rules = []
    for pair in pairs:
        if (
            not isinstance(pair, list)
            or len(pair) != 2
            or not all(isinstance(item, str) and item for item in pair)
        ):
            raise ToolEnvironmentError(f"{path}: {where} entries must be two non-empty strings")
        rules.append((pair[0], pair[1]))
    return rules


def apply_rules(text: str, rules) -> str:
    for left, right in rules:
        text = text.replace(left, right)
    return text


def source_value(entry: dict, key: str) -> str:
    """The Simplified Chinese text of one catalog entry; the key itself is the fallback."""
    localizations = entry.get("localizations")
    if isinstance(localizations, dict):
        locale = localizations.get(SOURCE_LOCALE)
        if isinstance(locale, dict):
            if "variations" in locale:
                raise GenerationError(f"{key}: plural variations are not supported")
            unit = locale.get("stringUnit")
            if isinstance(unit, dict):
                value = unit.get("value")
                if isinstance(value, str) and value != "":
                    return value
    return key


def finish_value(source_text: str, key: str, converted: str, overrides: dict) -> str:
    """Applies the overrides to one converted value and verifies nothing else changed."""
    value = apply_rules(converted, overrides["replacements"])
    value = apply_rules(value, overrides["byKey"].get(key, ()))
    if ascii_only(source_text) != ascii_only(value):
        raise GenerationError(
            f"{key}: placeholders or ASCII text changed: {source_text!r} -> {value!r}"
        )
    for term in overrides["banned"]:
        if term in value:
            raise GenerationError(f"{key}: wording {term!r} is still untranslated in {value!r}")
    return value


def convert_values(convert, texts: list[str]) -> list[str]:
    """Runs the converter on the non-blank texts only; blank texts are kept as they are."""
    pending = [index for index, text in enumerate(texts) if text.strip()]
    if not pending:
        return list(texts)
    converted = list(convert([texts[index] for index in pending]))
    if len(converted) != len(pending):
        raise GenerationError(f"the converter returned {len(converted)} values for {len(pending)} texts")
    result = list(texts)
    for index, value in zip(pending, converted):
        result[index] = value
    return result


def expected_hant(catalog: dict, overrides: dict, convert) -> dict[str, str]:
    """The zh-Hant value every key of one catalog must have."""
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise GenerationError("the catalog has no strings object")
    keys = list(strings)
    sources = [source_value(strings[key], key) for key in keys]
    converted = convert_values(convert, sources)
    return {
        key: finish_value(source, key, text, overrides)
        for key, source, text in zip(keys, sources, converted)
    }


def require_source_language(catalog: dict, path: str | Path) -> None:
    source = catalog.get("sourceLanguage")
    if source != SOURCE_LOCALE:
        raise GenerationError(
            f"{path}: sourceLanguage is {source!r}, expected {SOURCE_LOCALE!r}; "
            "Traditional values can only be generated from Simplified Chinese"
        )


def target_value(entry: dict) -> tuple[str | None, str | None]:
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        return None, None
    locale = localizations.get(TARGET_LOCALE)
    if not isinstance(locale, dict) or "variations" in locale:
        return None, None
    unit = locale.get("stringUnit")
    if not isinstance(unit, dict):
        return None, None
    value = unit.get("value")
    state = unit.get("state")
    return (value if isinstance(value, str) else None), (state if isinstance(state, str) else None)


def catalog_differences(catalog: dict, expected: dict[str, str]) -> list[HantDifference]:
    strings = catalog.get("strings") or {}
    differences = []
    for key, wanted in expected.items():
        actual, state = target_value(strings.get(key) or {})
        if actual != wanted or state != "translated":
            differences.append(HantDifference(key, wanted, actual, state))
    return differences


def apply_hant(catalog: dict, expected: dict[str, str]) -> None:
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise GenerationError("the catalog has no strings object")
    for key, value in expected.items():
        entry = strings.get(key)
        if not isinstance(entry, dict):
            raise GenerationError(f"{key}: the catalog entry is not an object")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            localizations = {}
            entry["localizations"] = localizations
        locale = localizations.get(TARGET_LOCALE)
        if not isinstance(locale, dict):
            locale = {}
            localizations[TARGET_LOCALE] = locale
        locale.pop("variations", None)
        unit = locale.get("stringUnit")
        if not isinstance(unit, dict):
            unit = {}
            locale["stringUnit"] = unit
        unit["state"] = "translated"
        unit["value"] = value


def serialize_catalog(catalog: dict) -> str:
    """The String Catalog JSON layout Xcode writes: two-space indent, unescaped, no final newline."""
    return json.dumps(catalog, ensure_ascii=False, indent=2)


def load_catalog(path: str | Path) -> dict:
    catalog_path = Path(path)
    try:
        return json.loads(catalog_path.read_text(encoding="utf-8"))
    except OSError as error:
        raise GenerationError(f"cannot read {catalog_path}: {error}") from error
    except json.JSONDecodeError as error:
        raise GenerationError(f"{catalog_path}: invalid JSON: {error}") from error


def find_catalogs(root: str | Path) -> list[Path]:
    found = []
    for directory, names, files in os.walk(Path(root)):
        names[:] = sorted(
            name
            for name in names
            if name not in SKIPPED_DIRECTORIES and not name.startswith(".")
        )
        for name in sorted(files):
            if name.endswith(".xcstrings"):
                found.append(Path(directory) / name)
    return found


def run_opencc(binary: str, config: Path, texts: list[str]) -> list[str]:
    """Converts a batch line by line; a value containing newlines keeps its own line breaks."""
    pending: list[str] = []
    plan: list[list[tuple[str | None, int | None]]] = []
    for text in texts:
        entries: list[tuple[str | None, int | None]] = []
        for position, part in enumerate(text.split("\n")):
            if position:
                entries.append(("\n", None))
            if part.strip():
                entries.append((None, len(pending)))
                pending.append(part)
            else:
                entries.append((part, None))
        plan.append(entries)
    if not pending:
        return list(texts)
    completed = subprocess.run(
        [binary, "-c", str(config)],
        input="\n".join(pending),
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise GenerationError("opencc failed: " + (completed.stderr or "").strip())
    if completed.stderr.strip():
        raise GenerationError("opencc reported a problem: " + completed.stderr.strip())
    lines = completed.stdout.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != len(pending):
        raise GenerationError(f"opencc returned {len(lines)} lines for {len(pending)} inputs")
    results = []
    for entries in plan:
        pieces = [piece if index is None else lines[index] for piece, index in entries]
        results.append("".join(pieces))
    return results


def make_converter(binary: str, config: Path):
    def convert(texts: list[str]) -> list[str]:
        return run_opencc(binary, config, texts)

    return convert


def _opencc_candidates() -> list[str]:
    candidates = []
    override = os.environ.get("OPENCC_BIN")
    if override:
        candidates.append(override)
    found = shutil.which("opencc")
    if found:
        candidates.append(found)
    # The macOS engine build (Tools/BuildRime) installs the same pinned OpenCC source tree.
    candidates.append(str(REPO_ROOT / ".local/engine/prefix/bin/opencc"))
    return candidates


def find_opencc(overrides: dict) -> tuple[str, Path]:
    binary = ""
    for candidate in _opencc_candidates():
        if Path(candidate).is_file() and os.access(candidate, os.X_OK):
            binary = candidate
            break
    if not binary:
        raise ToolEnvironmentError(
            "OpenCC is missing; install the pinned OpenCC 1.1.9 CLI (brew install opencc), "
            "build the macOS engine prefix (Tools/BuildRime) or point OPENCC_BIN at one"
        )
    try:
        version = subprocess.run([binary, "--version"], text=True, capture_output=True)
    except OSError as error:
        raise ToolEnvironmentError(f"cannot run {binary}: {error}") from error
    version_text = (version.stdout or "") + (version.stderr or "")
    if f"Version: {OPENCC_VERSION}" not in version_text and f"OpenCC {OPENCC_VERSION}" not in version_text:
        raise ToolEnvironmentError(f"{binary} is not OpenCC {OPENCC_VERSION}: {version_text.strip()}")
    data_dir = os.environ.get("OPENCC_DATA_DIR")
    if data_dir:
        config_name = str(overrides["opencc"].get("config", "s2twp"))
        config = Path(data_dir) / f"{config_name}.json"
    else:
        config = DEFAULT_OPENCC_CONFIG
    if not config.is_file():
        raise ToolEnvironmentError(f"missing the bundled OpenCC configuration {config}")
    return binary, config


def _short(text: str | None, limit: int = 120) -> str:
    if text is None:
        return "missing"
    return repr(text if len(text) <= limit else text[:limit] + "...")


def _relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _selected_catalogs(args) -> list[Path]:
    if args.catalog:
        return [Path(item) for item in args.catalog]
    catalogs = find_catalogs(Path(args.root))
    if not catalogs:
        raise ToolEnvironmentError(f"no .xcstrings files under {args.root}")
    return catalogs


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gen_zh_hant_strings.py",
        description="Generate or check the zh-Hant values of every String Catalog.",
    )
    parser.add_argument("--check", action="store_true", help="compare without writing; differences exit 1")
    parser.add_argument("--catalog", action="append", help="only this .xcstrings file (repeatable)")
    parser.add_argument("--root", default=str(REPO_ROOT), help="repository root to search")
    parser.add_argument("--overrides", default=str(DEFAULT_OVERRIDES), help="override table to use")
    parser.add_argument("--max-report", type=int, default=40, help="differences printed per catalog")
    parser.add_argument("--verbose", action="store_true", help="report catalogs that already match")
    return parser


def run(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        overrides = load_overrides(args.overrides)
        binary, config = find_opencc(overrides)
        catalogs = _selected_catalogs(args)
    except ToolEnvironmentError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_ENVIRONMENT
    convert = make_converter(binary, config)
    failures = 0
    checked = 0
    differing = 0
    for path in catalogs:
        try:
            catalog = load_catalog(path)
            require_source_language(catalog, path)
            expected = expected_hant(catalog, overrides, convert)
        except GenerationError as error:
            print(f"error: {error}", file=sys.stderr)
            failures += 1
            continue
        checked += len(expected)
        differences = catalog_differences(catalog, expected)
        if not differences:
            if args.verbose:
                print(f"current {_relative(path)} ({len(expected)} keys)")
            continue
        differing += len(differences)
        if args.check:
            failures += 1
            for difference in differences[: args.max_report]:
                print(f"differs {_relative(path)}: {difference.key}")
                print(f"  expected {_short(difference.expected)}")
                print(f"  actual   {_short(difference.actual)} ({difference.state or 'no state'})")
            if len(differences) > args.max_report:
                print(f"  ... {len(differences) - args.max_report} more in this catalog")
            continue
        apply_hant(catalog, expected)
        Path(path).write_text(serialize_catalog(catalog), encoding="utf-8")
        print(f"wrote {_relative(path)} ({len(differences)} values)")
    if args.check:
        if failures:
            print(f"check failed: {differing} of {checked} values differ", file=sys.stderr)
            return EXIT_DIFFERENCES
        print(f"check passed: {len(catalogs)} catalogs, {checked} values match")
        return EXIT_OK
    if failures:
        return EXIT_DIFFERENCES
    print(f"generated {len(catalogs)} catalogs, {checked} values")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(run())
