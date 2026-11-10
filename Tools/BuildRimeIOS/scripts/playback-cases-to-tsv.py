#!/usr/bin/env python3
"""Convert Tests/EngineFixtures/Builtin/playback_cases.json into the headerless
TSV that the native macOS replay harness
(Tools/BuildRimeIOS/harness-mac/builtin-playback-main.cc) reads.

The fixture stays the single source of truth; this step only parses JSON with the
Python standard library and resolves each fixture layout to the deployed schema
id by reading the staged shared tree. There is no hard-coded companion hash and
no expectation is derived or rewritten here.

Fixture contract (script-state replay):
  * "options" is an optional JSON object<string, bool>: every member of an
    exclusive switch group is listed with its requested value, so a case never
    depends on state left behind by the previous case. Old cases omit it and
    keep the schema's own reset state.
  * "expect_first" is an optional JSON string: when present the replay must see
    that text as candidate 0 of the first page (the four-state acceptance
    requires first choice). It is kept separate from expect_text because both
    are real engine evidence and may differ for other cases. Old cases omit it
    and keep find-and-commit.
  * "keys" stays the printable-ASCII sequence the layout sends, "expect_text"
    the text the engine must commit (find/page/commit, as before).

TSV columns (tab separated, no header):
  source_schema  layout  deployed_schema  options  keys  expect_text  expect_first
where options is "-" or a comma separated "name=0|1" list, and expect_first is
"-" or the exact text required at candidate 0 of the first page.

Usage:
  python3 Tools/BuildRimeIOS/scripts/playback-cases-to-tsv.py \
    --fixtures Tests/EngineFixtures/Builtin/playback_cases.json \
    --shared <staged shared data dir> --output <cases.tsv> \
    [--require-first-for-options] [--option-group simplification,zht,zh_tw,zh_hk]

Exit code: 0 converted; 3 fixture/preprocess error (nothing is written).
"""
import argparse
import json
import re
import sys
from pathlib import Path

ADAPTER_ID = re.compile(r"^keyboard_[0-9a-f]+_(9|14|18)$")
LAYOUT_BY_SUFFIX = {"9": "phone9", "14": "merged14", "18": "merged18"}
SCHEMA_ID = re.compile(r"(?m)^\s*schema_id:\s*(\S+)\s*$")
SOURCE_SCHEMA = re.compile(r"(?m)^\s+source_schema:\s*(\S+)\s*$")
OPTION_NAME = re.compile(r"^[A-Za-z0-9_]+$")
KEY_CHARS = re.compile(r"^[\x20-\x7e]+$")


class FixtureError(Exception):
    """A fixture or staged-tree problem that must fail the replay closed."""


def deployed_schemas(shared: Path) -> dict[tuple[str, str], str]:
    """(source schema, layout) -> deployed schema id, read from the real tree."""
    if not shared.is_dir():
        raise FixtureError(f"staged shared directory is missing: {shared}")
    mapping: dict[tuple[str, str], str] = {}
    for path in sorted(shared.glob("*.schema.yaml")):
        text = path.read_text(encoding="utf-8")
        schema_match = SCHEMA_ID.search(text)
        if not schema_match:
            raise FixtureError(f"{path.name}: no schema_id")
        schema_id = schema_match.group(1)
        adapter_match = ADAPTER_ID.match(schema_id)
        if not adapter_match:
            continue
        source_match = SOURCE_SCHEMA.search(text)
        if not source_match:
            raise FixtureError(f"{path.name}: adapter {schema_id} has no keyboard_adapter source_schema")
        layout = LAYOUT_BY_SUFFIX[adapter_match.group(1)]
        mapping[(source_match.group(1), layout)] = schema_id
    if not mapping:
        raise FixtureError(f"{shared}: no keyboard adapter schemas found")
    return mapping


def option_column(case: dict, index: int, group: set[str]) -> str:
    options = case.get("options")
    if options is None:
        return "-"
    if not isinstance(options, dict) or not options:
        raise FixtureError(f"case {index}: options must be a non-empty object<string, bool>")
    names = set(options)
    if group:
        missing = sorted(group - names)
        extra = sorted(names - group)
        if missing or extra:
            raise FixtureError(
                f"case {index}: options must list the whole switch group; "
                f"missing {missing}, unexpected {extra}")
    values = []
    for name in sorted(options):
        value = options[name]
        if not isinstance(value, bool):
            raise FixtureError(f"case {index}: option {name!r} must be a JSON boolean")
        if not OPTION_NAME.fullmatch(name):
            raise FixtureError(f"case {index}: option name {name!r} is not setOption-safe")
        values.append(f"{name}={1 if value else 0}")
    enabled = sum(1 for value in options.values() if value)
    if enabled == 0:
        raise FixtureError(f"case {index}: options select no state")
    return ",".join(values)


def first_candidate_text(case: dict, index: int) -> str | None:
    value = case.get("expect_first")
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise FixtureError(f"case {index}: expect_first must be a non-empty JSON string")
    if "\t" in value or "\n" in value or "\r" in value:
        raise FixtureError(f"case {index}: expect_first contains a tab or newline")
    return value


def build_rows(fixtures: Path, shared: Path, require_first: bool,
               group: set[str]) -> list[list[str]]:
    if not fixtures.is_file():
        raise FixtureError(f"fixture file is missing: {fixtures}")
    try:
        cases = json.loads(fixtures.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise FixtureError(f"{fixtures}: {error}") from error
    if not isinstance(cases, list) or not cases:
        raise FixtureError(f"{fixtures}: expected a non-empty JSON array")
    mapping = deployed_schemas(shared)
    rows: list[list[str]] = []
    with_options = 0
    with_first = 0
    for position, case in enumerate(cases, start=1):
        if not isinstance(case, dict):
            raise FixtureError(f"case {position}: expected a JSON object")
        try:
            source = case["schema"]
            layout = case["layout"]
            keys = case["keys"]
            expect = case["expect_text"]
        except KeyError as error:
            raise FixtureError(f"case {position}: missing field {error}") from error
        for field, value in (("schema", source), ("layout", layout),
                             ("keys", keys), ("expect_text", expect)):
            if not isinstance(value, str) or not value:
                raise FixtureError(f"case {position}: {field} must be a non-empty string")
            if "\t" in value or "\n" in value or "\r" in value:
                raise FixtureError(f"case {position}: {field} contains a tab or newline")
        if not KEY_CHARS.fullmatch(keys):
            raise FixtureError(f"case {position}: keys must be printable ASCII")
        if layout == "qwerty26":
            deployed = source
            if not (shared / f"{source}.schema.yaml").is_file():
                raise FixtureError(f"case {position}: staged tree has no {source}.schema.yaml")
        else:
            deployed = mapping.get((source, layout))
            if deployed is None:
                known = ", ".join(sorted(f"{s}/{t}" for s, t in mapping)) or "none"
                raise FixtureError(
                    f"case {position}: no deployed schema for {source}/{layout} "
                    f"(known adapters: {known})")
        columns = option_column(case, position, group)
        first = first_candidate_text(case, position)
        if columns != "-":
            with_options += 1
            if require_first and first is None:
                raise FixtureError(
                    f"case {position} ({source}/{layout} {keys!r}): options cases must also "
                    f"carry expect_first (the four-state acceptance requires first choice)")
        if first is not None:
            with_first += 1
        rows.append([source, layout, deployed, columns, keys, expect,
                     first if first is not None else "-"])
    print(
        f"converted {len(rows)} playback cases "
        f"({with_options} with options, {with_first} with expect_first)",
        file=sys.stderr)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--shared", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--require-first-for-options", action="store_true")
    parser.add_argument("--option-group", default="simplification,zht,zh_tw,zh_hk",
                        help="comma separated switch group every options object must list "
                             "(empty disables the check)")
    arguments = parser.parse_args()
    group = {name for name in arguments.option_group.split(",") if name}
    try:
        rows = build_rows(arguments.fixtures, arguments.shared,
                          arguments.require_first_for_options, group)
    except FixtureError as error:
        print(f"[cases] error: {error}", file=sys.stderr)
        return 3
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        "".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
    print(f"wrote {arguments.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
