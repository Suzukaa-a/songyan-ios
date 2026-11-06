#!/usr/bin/env python3
"""Finds raw Chinese string literals in Swift sources that bypass localization.

The interface is localized through String Catalogs, so a Chinese literal that the interface shows
must reach a catalog key. SwiftUI Text literals become keys on their own; every other user-visible
literal has to go through String(localized:) or a catalog-backed constant. This scanner reports
the literals that do neither, skipping the documented non-interface categories (logs, tests, key
caps, data tables) listed in hardcoded-chinese-allowlist.json.

Usage:
  Tools/Localization/scan_hardcoded_chinese.py                  scan the repository
  Tools/Localization/scan_hardcoded_chinese.py PATH --limit 80  scan another root, show more

Exit codes: 0 nothing to localize, 1 raw user-visible literals found, 2 unreadable input.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = Path(__file__).resolve().parent / "hardcoded-chinese-allowlist.json"
CJK = re.compile("[\u3400-\u4dbf\u4e00-\u9fff]")
WHITESPACE = " \t\r\n"
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
DECLARATION = re.compile(r"\b(?:func|var|let|init|subscript|case)\s+([A-Za-z_][A-Za-z0-9_]*)")
ARGUMENT_LABEL = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\Z")
CONFIG_LISTS = (
    "swiftuiTextCalls",
    "localizedCalls",
    "localizedStringCalls",
    "localizedArgumentLabels",
    "loggingCalls",
    "keycapCalls",
    "keycapFunctions",
    "dataCalls",
    "skippedPathComponents",
    "skippedFileSuffixes",
)


class ScanError(Exception):
    """The configuration or a source file cannot be read."""


class Frame(NamedTuple):
    kind: str
    name: str
    declaration: str


class Literal(NamedTuple):
    start: int
    value: str
    frames: tuple[Frame, ...]
    label: str
    interpolated: bool


class Finding(NamedTuple):
    path: str
    line: int
    value: str
    category: str


def load_config(path: str | Path | None = None) -> dict:
    config_path = Path(path) if path is not None else DEFAULT_CONFIG
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ScanError(f"cannot read {config_path}: {error}") from error
    if not isinstance(raw, dict):
        raise ScanError(f"{config_path}: the configuration must be a JSON object")
    config = {}
    for name in CONFIG_LISTS:
        values = raw.get(name, [])
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise ScanError(f"{config_path}: {name} must be a list of strings")
        config[name] = frozenset(values)
    entries = raw.get("dataLiterals", [])
    if not isinstance(entries, list) or not all(
        isinstance(entry, dict) and all(isinstance(entry.get(key), str) and entry[key] for key in ("path", "value", "reason"))
        for entry in entries
    ):
        raise ScanError(f"{config_path}: dataLiterals must name a path, value and reason")
    config["dataLiterals"] = entries
    return config


class Lexer:
    """A Swift lexer that is just precise enough to find string literals and their call context."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.length = len(source)
        self.mask = list(source)
        self.frames: list[Frame] = []
        self.literals: list[Literal] = []

    def scan(self) -> list[Literal]:
        self._lex(0, self.length, self.frames, False)
        return self.literals

    def _blank(self, start: int, end: int) -> None:
        for index in range(max(start, 0), min(end, self.length)):
            if self.mask[index] != "\n":
                self.mask[index] = " "

    def _name_before(self, position: int) -> str:
        index = position - 1
        while index >= 0 and self.mask[index] in WHITESPACE:
            index -= 1
        end = index + 1
        while index >= 0 and (self.mask[index].isalnum() or self.mask[index] == "_"):
            index -= 1
        word = "".join(self.mask[index + 1:end])
        return word if IDENTIFIER.match(word) else ""

    def _declaration_before(self, position: int) -> str:
        window = "".join(self.mask[max(0, position - 300):position])
        matches = DECLARATION.findall(window)
        return matches[-1] if matches else ""

    def _argument_label(self, position: int) -> str:
        window = "".join(self.mask[max(0, position - 120):position])
        match = ARGUMENT_LABEL.search(window)
        return match.group(1) if match else ""

    def _block_comment_end(self, start: int, end: int) -> int:
        depth = 1
        index = start + 2
        while index < end:
            if self.source.startswith("/*", index):
                depth += 1
                index += 2
                continue
            if self.source.startswith("*/", index):
                depth -= 1
                index += 2
                if depth == 0:
                    return index
                continue
            index += 1
        return end

    def _raw_prefix(self, position: int, end: int) -> tuple[int, int] | None:
        index = position
        hashes = 0
        while index < end and self.source[index] == "#":
            hashes += 1
            index += 1
        if hashes and index < end and self.source[index] == '"':
            return hashes, index
        return None

    def _string_end(self, position: int, end: int) -> int:
        hashes = 0
        index = position
        if self.source[index] == "#":
            prefix = self._raw_prefix(position, end)
            if prefix is None:
                return -1
            hashes, index = prefix
        multiline = self.source.startswith('"""', index) and index + 3 <= end
        closing = ('"""' if multiline else '"') + "#" * hashes
        index += 3 if multiline else 1
        while index < end:
            if self.source.startswith(closing, index):
                return index + len(closing)
            character = self.source[index]
            if not multiline and character == "\n":
                return -1
            if hashes == 0 and character == "\\" and index + 1 < end:
                if self.source[index + 1] == "(":
                    inner = self._interpolation_end(index + 2, end)
                    index = inner + 1 if inner < end else end
                    continue
                index += 2
                continue
            index += 1
        return -1

    def _interpolation_end(self, start: int, end: int) -> int:
        depth = 0
        index = start
        while index < end:
            character = self.source[index]
            if character == '"' or (character == "#" and self._raw_prefix(index, end) is not None):
                stop = self._string_end(index, end)
                index = stop if stop > 0 else index + 1
                continue
            if self.source.startswith("//", index):
                newline = self.source.find("\n", index)
                index = end if newline < 0 or newline > end else newline
                continue
            if self.source.startswith("/*", index):
                index = self._block_comment_end(index, end)
                continue
            if character == "(":
                depth += 1
                index += 1
                continue
            if character == ")":
                if depth == 0:
                    return index
                depth -= 1
                index += 1
                continue
            index += 1
        return end

    def _collect_string(self, position: int, stop: int, frames: list[Frame]) -> str:
        hashes = 0
        index = position
        if self.source[index] == "#":
            prefix = self._raw_prefix(position, stop)
            if prefix is not None:
                hashes, index = prefix
        multiline = self.source.startswith('"""', index)
        closing_length = (3 if multiline else 1) + hashes
        content_end = stop - closing_length
        index += 3 if multiline else 1
        chunks: list[str] = []
        while index < content_end:
            character = self.source[index]
            if hashes == 0 and character == "\\" and index + 1 < content_end:
                if self.source[index + 1] == "(":
                    inner = self._interpolation_end(index + 2, content_end)
                    self._lex(index + 2, inner, list(frames), True)
                    index = inner + 1
                    continue
                chunks.append(self.source[index + 1])
                index += 2
                continue
            chunks.append(character)
            index += 1
        return "".join(chunks)

    def _read_string(self, position: int, end: int, frames: list[Frame], interpolated: bool) -> int:
        stop = self._string_end(position, end)
        if stop < 0:
            return position + 1
        value = self._collect_string(position, stop, frames)
        self.literals.append(
            Literal(
                start=position,
                value=value,
                frames=tuple(frames),
                label=self._argument_label(position),
                interpolated=interpolated,
            )
        )
        self._blank(position, stop)
        return stop

    def _lex(self, start: int, end: int, frames: list[Frame], interpolated: bool) -> None:
        index = start
        while index < end:
            character = self.source[index]
            if self.source.startswith("//", index):
                newline = self.source.find("\n", index)
                stop = end if newline < 0 or newline > end else newline
                self._blank(index, stop)
                index = stop
                continue
            if self.source.startswith("/*", index):
                stop = self._block_comment_end(index, end)
                self._blank(index, stop)
                index = stop
                continue
            if character == '"' or (character == "#" and self._raw_prefix(index, end) is not None):
                index = self._read_string(index, end, frames, interpolated)
                continue
            if character in "([{":
                name = self._name_before(index) if character == "(" else ""
                declaration = self._declaration_before(index) if character in "({" else ""
                frames.append(Frame(character, name, declaration))
                index += 1
                continue
            if character in ")]}":
                if frames:
                    frames.pop()
                index += 1
                continue
            index += 1


def classify(literal: Literal, config: dict) -> str:
    call_names = [frame.name for frame in literal.frames if frame.kind == "("]
    declarations = [frame.declaration for frame in literal.frames if frame.declaration]
    nearest_call = call_names[-1] if call_names else ""
    if not literal.interpolated:
        if nearest_call in config["swiftuiTextCalls"] and literal.label != "verbatim":
            return "swiftui-text"
    if nearest_call in config["localizedStringCalls"] and literal.label in config["localizedArgumentLabels"]:
        return "localized"
    if any(name in config["localizedCalls"] for name in call_names):
        return "localized"
    if any(name in config["loggingCalls"] for name in call_names):
        return "log"
    if any(name in config["keycapCalls"] for name in call_names):
        return "keycap"
    if declarations and declarations[-1] in config["keycapFunctions"]:
        return "keycap"
    if any(name in config["dataCalls"] for name in call_names):
        return "data"
    return "user-visible"


def _clean(value: str) -> str:
    collapsed = " ".join(value.split())
    return collapsed if len(collapsed) <= 120 else collapsed[:117] + "..."


def _line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def find_violations(source: str, config: dict, path: str = "<source>") -> list[Finding]:
    """The Chinese user-visible literals of one Swift source that need a String Catalog key."""
    findings = []
    for literal in Lexer(source).scan():
        if not CJK.search(literal.value):
            continue
        category = classify(literal, config)
        if category != "user-visible":
            continue
        if any(entry["path"] == path and entry["value"] == literal.value for entry in config.get("dataLiterals", [])):
            continue
        findings.append(
            Finding(
                path=path,
                line=_line_number(source, literal.start),
                value=_clean(literal.value),
                category=category,
            )
        )
    return findings


def _in_scan_scope(relative: Path) -> bool:
    """Only the shipped app and package sources; probes, fixtures and tools are not the interface."""
    parts = relative.parts
    if not parts:
        return False
    if parts[0] == "Apps":
        return True
    return len(parts) >= 3 and parts[0] == "Packages" and parts[2] == "Sources"


def discover_sources(root: str | Path, config: dict) -> list[Path]:
    sources: list[Path] = []
    base = Path(root)
    skipped = config["skippedPathComponents"]
    for directory, names, files in os.walk(base):
        names[:] = sorted(
            name for name in names if name not in skipped and not name.startswith(".")
        )
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            if any(name.endswith(suffix) for suffix in config["skippedFileSuffixes"]):
                continue
            path = Path(directory) / name
            if not _in_scan_scope(path.relative_to(base)):
                continue
            sources.append(path)
    return sources


def _relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def scan_tree(root: str | Path, config: dict) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    sources = discover_sources(root, config)
    for path in sources:
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            raise ScanError(f"cannot read {path}: {error}") from error
        findings.extend(find_violations(source, config, path=_relative(path)))
    return findings, len(sources)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scan_hardcoded_chinese.py",
        description="Report raw Chinese user-visible string literals outside SwiftUI Text.",
    )
    parser.add_argument("root", nargs="?", default=str(REPO_ROOT), help="repository root to scan")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="allowance configuration to use")
    parser.add_argument("--limit", type=int, default=40, help="findings printed")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = load_config(args.config)
        findings, scanned = scan_tree(Path(args.root), config)
    except ScanError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    for finding in findings[: args.limit]:
        print(f"{finding.path}:{finding.line}: {finding.value}")
    if len(findings) > args.limit:
        print(f"... {len(findings) - args.limit} more")
    if findings:
        print(
            f"{len(findings)} raw Chinese user-visible literals in {scanned} Swift files",
            file=sys.stderr,
        )
        return 1
    print(f"no raw Chinese user-visible literals in {scanned} Swift files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
