#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# traditional-playback-harness.sh — real macOS replay of the traditional-Chinese
# playback fixtures (Tests/EngineFixtures/Traditional/playback_cases.json)
# against the pinned librime 1.17.0 generations already deployed by the
# pinned catalogue build.
#
# The fixture is the single source of truth. This wrapper parses it with the
# Python standard library and resolves every case's schema to the deployed
# generation whose shipping metadata names it as its main schema
# (store-*/active.json: schemaID + generation). It also checks that schema
# against that generation's compiled default.yaml schema list, so a case can
# only replay a schema the catalogue build actually publishes. There is no
# command-line schema override and no bypass switch: the only staging inputs
# are the deployed generations and the fixture.
#
# Deployment is reused read-only. Nothing is installed, downloaded or written
# inside the deployed store: the engine reads resources/ and user/build/, and
# learns into a fresh user directory under the run directory.
#
# One case replays the way a keyboard front end does it:
#   select schema -> clear composition -> feed each ASCII key (space included)
#   -> assert preedit / candidate rank / committed text; when the case names a
#   candidate, find it (paging while missing), select it, compare the commit.
# See harness-mac/traditional-playback-main.cc for the column contract.
#
# --derive-keys is read-only evidence, not replay: for every case it reads the
# deployed generation's compiled schema algebra and the real dictionary row for
# the case's title text, applies the algebra per syllable, and prints the
# spellings the deployed data actually accepts, so a key sequence can be
# corrected from the data instead of guessed. It never rewrites the fixture.
#
# Usage:
#   Tools/BuildRimeIOS/scripts/traditional-playback-harness.sh
#   Tools/BuildRimeIOS/scripts/traditional-playback-harness.sh --derive-keys
#
# Environment:
#   TRADITIONAL_PLAYBACK_CASES      default Tests/EngineFixtures/Traditional/playback_cases.json
#   TRADITIONAL_PLAYBACK_DEPLOYED   directory holding store-*/active.json; default
#                                   <repo>/.local/t2b-native when exactly one
#                                   traditional-catalog.* run there has all four stores
#   TRADITIONAL_PLAYBACK_RECORD     1 prints per-case preedit/candidates/commit
#   TRADITIONAL_PLAYBACK_MAX_PAGES  default 40
#   NATIVE_ENGINE_ROOT              pinned macOS engine root (read-only). Default
#                                   <repo>/.local/engine, else the sibling
#                                   songyan-ios checkout's .local/engine.
#   HARNESS_OUTPUT_ROOT             run directories (default <repo>/.scratch/t3-playback)
#
# Exit: 0 every case met its expectation; 2 replay/engine failure (a real
# expectation mismatch is exit 2, never a skip); 3 fixture/preprocess failure;
# 64 usage.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ -z "${NATIVE_ENGINE_ROOT:-}" ]]; then
  for candidate in "${REPO_ROOT}/.local/engine" "${REPO_ROOT}/../songyan-ios/.local/engine"; do
    if [[ -f "${candidate}/prefix/lib/librime.a" ]]; then
      NATIVE_ENGINE_ROOT="${candidate}"
      break
    fi
  done
fi
[[ -n "${NATIVE_ENGINE_ROOT:-}" ]] || {
  printf '[Harness:error] no pinned macOS engine root found; set NATIVE_ENGINE_ROOT\n' >&2
  exit 2
}
export NATIVE_ENGINE_ROOT

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/harness.sh"

usage() {
  printf 'usage: %s [--derive-keys]\n' "$(basename "$0")" >&2
  exit 64
}

MODE=replay
case "${1:-}" in
  "") ;;
  --derive-keys) MODE=derive ;;
  -h | --help) usage ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

CASES="${TRADITIONAL_PLAYBACK_CASES:-${PROJECT_ROOT}/Tests/EngineFixtures/Traditional/playback_cases.json}"
RECORD="${TRADITIONAL_PLAYBACK_RECORD:-0}"
MAX_PAGES="${TRADITIONAL_PLAYBACK_MAX_PAGES:-40}"
DEPLOYED="${TRADITIONAL_PLAYBACK_DEPLOYED:-}"
export HARNESS_OUTPUT_ROOT="${HARNESS_OUTPUT_ROOT:-${PROJECT_ROOT}/.scratch/t3-playback}"

[[ "${RECORD}" == "0" || "${RECORD}" == "1" ]] || die \
  "TRADITIONAL_PLAYBACK_RECORD must be 0 or 1"
[[ "${MAX_PAGES}" =~ ^[0-9]+$ && "${MAX_PAGES}" -ge 1 ]] || die \
  "TRADITIONAL_PLAYBACK_MAX_PAGES must be a positive integer"
[[ -f "${CASES}" ]] || die "fixture file is missing: ${CASES}"
[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/librime.a; set NATIVE_ENGINE_ROOT to the pinned macOS engine root"
[[ -d "${MAC_PREFIX}/include" ]] || die "missing ${MAC_PREFIX}/include (pinned dependency headers)"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# The deployed generation root is a staging input, never a schema override.
if [[ -z "${DEPLOYED}" ]]; then
  shopt -s nullglob
  candidates=("${PROJECT_ROOT}/.local/t2b-native"/traditional-catalog.*)
  shopt -u nullglob
  ready=()
  for candidate in "${candidates[@]}"; do
    [[ -d "${candidate}" ]] || continue
    count=$(find "${candidate}" -maxdepth 2 -name active.json -path '*/store-*/*' 2>/dev/null | wc -l | tr -d ' ')
    [[ "${count}" -ge 4 ]] && ready+=("${candidate}")
  done
  if [[ "${#ready[@]}" -eq 1 ]]; then
    DEPLOYED="${ready[0]}"
  else
    die "cannot pick one deployed generation root under ${PROJECT_ROOT}/.local/t2b-native; set TRADITIONAL_PLAYBACK_DEPLOYED (candidates: ${ready[*]:-none})"
  fi
fi
[[ -d "${DEPLOYED}" ]] || die "deployed generation root is missing: ${DEPLOYED}"

RUN_DIR="$(new_harness_dir traditional-playback)"
say "fixture: ${CASES}"
say "deployed generations: ${DEPLOYED}"
say "run dir: ${RUN_DIR}"
say "engine root: ${NATIVE_ENGINE_ROOT}"

# MARK: - Fixture preprocessing (stdlib JSON, deployed shipping metadata)

PLAN="${RUN_DIR}/plan.tsv"
PREP_STATUS=0
python3 - "${CASES}" "${DEPLOYED}" "${RUN_DIR}" "${PLAN}" "${MODE}" <<'PY' || PREP_STATUS=$?
"""Parse the fixture and resolve each case to one deployed generation.

Replay writes one headerless TSV per generation plus a plan.tsv; derive prints
the real dictionary row and deployed algebra spellings for every case.
"""
import json
import os
import re
import sys

cases_path, deployed_root, run_dir, plan_path, mode = sys.argv[1:6]

OPTIONAL_STRINGS = (
    "expect_text",
    "expect_first",
    "expect_top3",
    "expect_top5",
    "expect_preedit",
    "commit_action",
)
TSV_COLUMNS = ("schema", "layout", "keys") + OPTIONAL_STRINGS


class FixtureError(Exception):
    pass


def read_json(path):
    try:
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, ValueError) as error:
        raise FixtureError(f"{path}: {error}") from error


def clean_text(value, where):
    if not isinstance(value, str) or not value:
        raise FixtureError(f"{where}: expected a non-empty JSON string")
    if "\t" in value or "\n" in value or "\r" in value:
        raise FixtureError(f"{where}: contains a tab or newline")
    return value


def schema_list(build_dir):
    """schema ids published by the compiled default.yaml (shipped list)."""
    path = os.path.join(build_dir, "default.yaml")
    fields = []
    in_list = False
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            stripped = line.rstrip("\n")
            if not in_list:
                if re.match(r"^schema_list:\s*$", stripped):
                    in_list = True
                continue
            if re.match(r"^\S", stripped):
                break
            matched = re.match(r"^\s*-\s*schema:\s*(\S+)\s*$", stripped)
            if matched:
                fields.append(matched.group(1))
    if not fields:
        raise FixtureError(f"{path}: compiled default.yaml has no schema_list")
    return fields


def generations(root):
    """main schema id -> deployed generation facts, from active.json only."""
    table = {}
    for name in sorted(os.listdir(root)):
        store = os.path.join(root, name)
        active = os.path.join(store, "active.json")
        if not name.startswith("store-") or not os.path.isfile(active):
            continue
        with open(active, encoding="utf-8") as stream:
            meta = json.load(stream)
        schema = meta.get("schemaID")
        generation = meta.get("generation")
        if not schema or not generation:
            raise FixtureError(f"{active}: missing schemaID/generation")
        version = os.path.join(store, "versions", generation)
        if not os.path.isdir(version):
            raise FixtureError(f"{active}: generation directory is missing: {version}")
        facts = {
            "store": name,
            "schema": schema,
            "generation": generation,
            "resources": os.path.join(version, "resources"),
            "build": os.path.join(version, "user", "build"),
        }
        for key in ("resources", "build"):
            if not os.path.isdir(facts[key]):
                raise FixtureError(f"{active}: {key} directory is missing: {facts[key]}")
        facts["schemas"] = schema_list(facts["build"])
        if schema not in facts["schemas"]:
            raise FixtureError(
                f"{active}: main schema {schema} is not in the compiled schema list {facts['schemas']}"
            )
        if schema in table:
            raise FixtureError(
                f"schema {schema} is the main schema of two stores: "
                f"{table[schema]['store']} and {name}"
            )
        table[schema] = facts
    if not table:
        raise FixtureError(f"{root}: no deployed store-*/active.json found")
    return table


def load_cases(path):
    document = read_json(path)
    if not isinstance(document, list) or not document:
        raise FixtureError(f"{path}: expected a non-empty JSON array")
    cases = []
    for position, case in enumerate(document, start=1):
        where = f"case {position}"
        if not isinstance(case, dict):
            raise FixtureError(f"{where}: expected a JSON object")
        entry = {}
        for key in TSV_COLUMNS:
            if key in OPTIONAL_STRINGS:
                entry[key] = clean_text(case[key], f"{where} {key}") if key in case else ""
            else:
                if key not in case:
                    raise FixtureError(f"{where}: missing field {key}")
                entry[key] = clean_text(case[key], f"{where} {key}")
        if not re.fullmatch(r"[\x20-\x7e]+", entry["keys"]):
            raise FixtureError(f"{where}: keys must be printable ASCII")
        action = entry["commit_action"]
        if action and action not in ("select", "confirm"):
            raise FixtureError(f"{where}: commit_action must be select or confirm")
        if action and not entry["expect_text"]:
            raise FixtureError(f"{where}: commit_action needs expect_text")
        if not entry["expect_text"] and not any(
            entry[key] for key in ("expect_first", "expect_top3", "expect_top5", "expect_preedit")
        ):
            raise FixtureError(f"{where}: no expectation at all")
        entry["text"] = case.get("text", "")
        cases.append(entry)
    return cases


def yaml_scalar(raw):
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        return json.loads(raw)
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1].replace("''", "'")
    return raw


def block_list(text, top):
    """Items of a top-level block list in a dict YAML header."""
    lines = text.split("\n")
    items = []
    for index, line in enumerate(lines):
        if line.rstrip() == f"{top}:":
            for entry in lines[index + 1 :]:
                if entry.strip() and not entry.startswith(" "):
                    break
                matched = re.match(r"^\s*-\s*(.+?)\s*$", entry)
                if matched:
                    items.append(yaml_scalar(matched.group(1)))
                elif entry.strip() and not entry.lstrip().startswith("-"):
                    break
            break
    return items


def mapping_block(text, top):
    """Lines of a top-level mapping block (until the next top-level key)."""
    lines = text.split("\n")
    output = []
    inside = False
    for line in lines:
        if line.rstrip() == f"{top}:":
            inside = True
            continue
        if inside:
            if line.strip() and not line.startswith(" "):
                break
            output.append(line)
    return "\n".join(output)


def dictionary_header(path):
    with open(path, encoding="utf-8", errors="replace") as stream:
        lines = []
        for line in stream:
            if line.startswith("..."):
                break
            lines.append(line)
    return "".join(lines)


def dictionary_rows(path):
    with open(path, encoding="utf-8", errors="replace") as stream:
        started = False
        for line in stream:
            if not started:
                if line.startswith("..."):
                    started = True
                continue
            if not line or line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2:
                yield fields


def dictionary_files(resources, name, seen=None):
    """The dictionary file plus its recursive import_tables, in order."""
    seen = seen or set()
    if name in seen:
        return []
    seen.add(name)
    path = os.path.join(resources, name + ".dict.yaml")
    if not os.path.isfile(path):
        return []
    header = dictionary_header(path)
    imports = block_list(header, "import_tables")
    files = []
    for imported in imports:
        files.extend(dictionary_files(resources, imported, seen))
    files.append(path)
    return files


def dictionary_row(resources, dictionary, word):
    for path in dictionary_files(resources, dictionary):
        for fields in dictionary_rows(path):
            if fields[0] == word:
                return path, fields[0], fields[1]
    return None, None, None


def parse_algebra(schema_path):
    with open(schema_path, encoding="utf-8") as stream:
        text = stream.read()
    speller = mapping_block(text, "speller")
    if not speller:
        return []
    rules = []
    for line in speller.split("\n"):
        matched = re.match(r'^\s*-\s+(".*"|\'.*\')\s*$', line)
        if matched:
            rules.append(yaml_scalar(matched.group(1)))
    return rules


def split_formula(formula, separator):
    pieces = []
    current = ""
    escaped = False
    for character in formula:
        if escaped:
            current += character
            escaped = False
        elif character == "\\":
            escaped = True
            current += character
        elif character == separator:
            pieces.append(current)
            current = ""
        else:
            current += character
    pieces.append(current)
    return pieces


def python_replacement(template):
    return re.sub(r"\$(\d+)", lambda match: "\\" + match.group(1), template)


def transform(rule, syllable):
    if rule.startswith("xform/") or rule.startswith("derive/") or rule.startswith("abbrev/"):
        _, rest = rule.split("/", 1)
        pieces = split_formula(rest, "/")
        if len(pieces) < 2:
            return None
        pattern, template = pieces[0], pieces[1]
        try:
            expression = re.compile(pattern)
        except re.error:
            return None
        if not expression.search(syllable):
            return None
        return expression.sub(python_replacement(template), syllable)
    if rule.startswith("xlit|"):
        pieces = rule.split("|")
        if len(pieces) < 4:
            return None
        source, target = pieces[1], pieces[2]
        table = {}
        for index, character in enumerate(source):
            if index < len(target):
                table[character] = target[index]
        if not any(character in table for character in syllable):
            return None
        return "".join(table.get(character, character) for character in syllable)
    return None


def spellings(syllable, rules):
    """All spellings the deployed algebra accepts for one syllable."""
    products = [syllable]
    for rule in rules:
        if rule.startswith("xform/") or rule.startswith("xlit|"):
            updated = []
            for spelling in products:
                result = transform(rule, spelling)
                candidate = spelling if result is None else result
                if candidate and candidate not in updated:
                    updated.append(candidate)
            products = updated
        elif rule.startswith("derive/") or rule.startswith("abbrev/"):
            additions = []
            for spelling in products:
                result = transform(rule, spelling)
                if result and result not in products and result not in additions:
                    additions.append(result)
            products = products + additions
    return products


def typed_codes(code, rules):
    syllables = code.split()
    forms = [spellings(syllable, rules) for syllable in syllables]
    codes = [""]
    for options in forms:
        codes = [prefix + option for prefix in codes for option in options]
        if len(codes) > 256:
            codes = codes[:256]
    return codes


def derive(case, facts):
    schema = case["schema"]
    compiled = os.path.join(facts["build"], schema + ".schema.yaml")
    with open(compiled, encoding="utf-8") as stream:
        text = stream.read()
    rules = parse_algebra(compiled)
    translator = mapping_block(text, "translator")
    matched = re.search(r"^\s*dictionary:\s*(\S+)\s*$", translator, re.M)
    dictionary = matched.group(1) if matched else schema
    word = case["text"] or case["expect_text"]
    path, row_word, code = dictionary_row(facts["resources"], dictionary, word)
    if path is None:
        print(
            f"DERIVE\t{schema}\t{word}\tMISSING_ROW\tdictionary={dictionary}\tkeys={case['keys']}",
            file=sys.stderr,
        )
        return
    codes = typed_codes(code, rules)
    accepted = [item.replace(" ", "") for item in codes]
    # A space in the fixture either separates syllables of a spaced code or is
    # the keyboard's own commit key; the spelling itself is the letters and
    # tones, so compare without spaces.
    typed = case["keys"].replace(" ", "")
    mark = "MATCH" if typed in accepted else "MISMATCH"
    print(
        f"DERIVE\t{schema}\t{word}\tdict={os.path.basename(path)}\trow={row_word}={code}"
        f"\tspellings={'|'.join(accepted[:16])}\tkeys={case['keys']}\t{mark}",
        file=sys.stderr,
    )


def main():
    table = generations(deployed_root)
    cases = load_cases(cases_path)
    missing = sorted({case["schema"] for case in cases if case["schema"] not in table})
    if missing:
        known = ", ".join(sorted(table))
        raise FixtureError(
            f"fixture schemas are not the main schema of any deployed generation: "
            f"{missing} (deployed: {known})"
        )
    if mode == "derive":
        for index, case in enumerate(cases, start=1):
            print(
                f"case {index}: {case['schema']}/{case['layout']} {case['keys']}"
                f" -> {case['text'] or case['expect_text']}",
                file=sys.stderr,
            )
            derive(case, table[case["schema"]])
        return

    groups = {}
    for case in cases:
        groups.setdefault(case["schema"], []).append(case)
    plan = []
    for schema, items in groups.items():
        facts = table[schema]
        tsv = os.path.join(run_dir, f"{facts['store']}.tsv")
        with open(tsv, "w", encoding="utf-8") as stream:
            for case in items:
                columns = [case[column] if case[column] else "-" for column in TSV_COLUMNS]
                stream.write("\t".join(columns) + "\n")
        plan.append(
            "\t".join(
                [facts["store"], schema, facts["resources"], facts["build"], tsv, str(len(items))]
            )
        )
        print(
            f"[cases] {schema}: {len(items)} cases -> {facts['store']} "
            f"(generation {facts['generation'][:24]}...)",
            file=sys.stderr,
        )
    with open(plan_path, "w", encoding="utf-8") as stream:
        stream.write("\n".join(plan) + "\n")
    print(f"[cases] {len(cases)} cases in {len(plan)} deployed generations", file=sys.stderr)


try:
    main()
except FixtureError as error:
    print(f"[cases] error: {error}", file=sys.stderr)
    sys.exit(3)
PY
if [[ "${PREP_STATUS}" != "0" ]]; then
  exit "${PREP_STATUS}"
fi
if [[ "${MODE}" == "derive" ]]; then
  say "derived spellings printed above (read-only evidence; the fixture was not rewritten)"
  exit 0
fi

# MARK: - Native bridge + driver

GEN_INCLUDE="$(rime_generated_include)"
prepare_native_bridge
compile_bridge_c
compile_bridge_cpp rime_spelling
MAIN_FLAGS=()
for flag in "${MAC_CXX_FLAGS[@]}"; do
  [[ "${flag}" == "-c" ]] || MAIN_FLAGS+=("${flag}")
done
BIN="${RUN_DIR}/traditional-playback"
say "compile traditional playback harness (-O2) against ${MAC_PREFIX}"
"${MAC_CXX}" "${MAIN_FLAGS[@]}" -Wall -Wextra -Werror \
  "${IOS_TOOLS_DIR}/harness-mac/traditional-playback-main.cc" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -o "${BIN}"

# MARK: - Replay, one process (and one engine) per deployed generation

FAILED=0
SUMMARY="${RUN_DIR}/summary.tsv"
: >"${SUMMARY}"
while IFS='	' read -r store schema resources build tsv count; do
  [[ -n "${store}" ]] || continue
  say "replay ${count} case(s) for ${schema} from ${store}"
  USER_DIR="$(new_isolated_dir "${RUN_DIR}/user-${store}")"
  ARGS=(
    --shared "${resources}"
    --compiled "${build}"
    --user "${USER_DIR}"
    --cases "${tsv}"
    --label "${schema}"
    --max-pages "${MAX_PAGES}"
  )
  [[ "${RECORD}" == "1" ]] && ARGS+=(--record)
  STATUS=0
  "${BIN}" "${ARGS[@]}" || STATUS=$?
  if [[ "${STATUS}" != "0" ]]; then
    FAILED=1
  fi
  printf '%s\t%s\t%s\n' "${store}" "${schema}" "${STATUS}" >>"${SUMMARY}"
done <"${PLAN}"

say "summary (store, schema, exit)"
cat "${SUMMARY}" >&2
if [[ "${FAILED}" != "0" ]]; then
  die "traditional playback did not meet its expectations; run dir: ${RUN_DIR}"
fi
say "all traditional playback cases met their expectations"
say "harness dir: ${RUN_DIR}"
