#!/usr/bin/env python3
"""String Catalog gates: coverage, placeholders, Japanese wording, generation and source scan.

The interface strings live in String Catalogs whose source language is Simplified Chinese. This
test is the static gate for that contract:

  * every catalog, every key: zh-Hant and ja exist and are marked translated;
  * every catalog, every key: printf placeholders match the Simplified source in every locale;
  * Japanese is never the Simplified string by accident (explicit, value-pinned allowlist);
  * the zh-Hant values are exactly what Tools/Localization/gen_zh_hant_strings.py generates from
    the Simplified values with the pinned OpenCC 1.1.9 s2twp configuration and the shared override
    table;
  * no Swift production source shows a raw Chinese literal outside a SwiftUI Text literal, apart
    from the documented log, test, key-cap and data allowances.

Run: python3 Tests/ProjectStructure/test_string_catalogs.py
Exit code 0 on success, 1 on any failure. No Xcode or simulator is required. The generation check
needs an OpenCC 1.1.9 command: the pinned macOS engine build under .local/engine/prefix, an
opencc on PATH, or OPENCC_BIN (see the generator's header).
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@contextmanager
def fixture_directory():
    # Retain fixtures under one task-owned directory for the caller to move to Trash.
    root = ROOT / ".scratch/l2-test-fixtures"
    root.mkdir(parents=True, exist_ok=True)
    yield tempfile.mkdtemp(dir=root)


LOCALIZATION = ROOT / "Tools/Localization"
OVERRIDES = LOCALIZATION / "zh-Hant-overrides.json"
SCAN_CONFIG = LOCALIZATION / "hardcoded-chinese-allowlist.json"
CATALOG_ALLOWLIST = LOCALIZATION / "catalog-gate-allowlist.json"
GENERATOR = LOCALIZATION / "gen_zh_hant_strings.py"
SOURCE_LOCALE = "zh-Hans"
TARGET_LOCALES = ("zh-Hant", "ja")
PRINTF = re.compile(
    r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSp]"
)
SKIPPED_DIRECTORIES = frozenset({"build", "DerivedData", "Vendored", "node_modules"})
# The shared Taiwan-wording table. It is the same table the Android repository applies, so the
# two platforms keep one list; a wording change has to happen in both places.
SHARED_REPLACEMENTS = frozenset(
    {
        ("學習數據", "學習資料"),
        ("自定義", "自訂"),
        ("錯鍵糾正", "錯字修正"),
        ("鍵盤佈局", "鍵盤配置"),
        ("鍵盤布局", "鍵盤配置"),
        ("学习数据", "學習資料"),
        ("错键纠正", "錯字修正"),
        ("键盘布局", "鍵盤配置"),
        ("候選欄", "候選列"),
        ("候选栏", "候選列"),
        ("松菸", "松煙"),
        ("松烟", "松煙"),
        ("點按", "輕觸"),
        ("点按", "輕觸"),
        ("全角", "全形"),
        ("半角", "半形"),
        ("數據", "資料"),
        ("数据", "資料"),
        ("替換", "取代"),
        ("替换", "取代"),
        ("准備", "準備"),
        ("輕點", "點一下"),
        ("完全訪問", "完整取用"),
    }
)


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


generator = _load_module("gen_zh_hant_strings", GENERATOR)
scanner = _load_module("scan_hardcoded_chinese", LOCALIZATION / "scan_hardcoded_chinese.py")


def _catalog_paths() -> list[Path]:
    paths = []
    for directory, names, files in os.walk(ROOT):
        names[:] = sorted(
            name for name in names if name not in SKIPPED_DIRECTORIES and not name.startswith(".")
        )
        for name in sorted(files):
            if name.endswith(".xcstrings"):
                paths.append(Path(directory) / name)
    return paths


def _catalog_pairs():
    for path in _catalog_paths():
        yield path, json.loads(path.read_text(encoding="utf-8"))


def _source_text(entry: dict, key: str) -> str:
    locale = (entry.get("localizations") or {}).get(SOURCE_LOCALE) or {}
    value = (locale.get("stringUnit") or {}).get("value")
    return value if isinstance(value, str) and value else key


def _localized_value(entry: dict, locale: str) -> tuple[str | None, str | None]:
    unit = ((entry.get("localizations") or {}).get(locale) or {}).get("stringUnit") or {}
    value = unit.get("value")
    state = unit.get("state")
    return (value if isinstance(value, str) else None), (state if isinstance(state, str) else None)


def _specifiers(text: str) -> list[str]:
    return sorted(PRINTF.findall(text))


def _write_overrides(directory: str, payload: dict) -> Path:
    path = Path(directory) / "overrides.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _identity(texts):
    return list(texts)


class StringCatalogCoverageTests(unittest.TestCase):
    def test_catalogs_exist_and_declare_simplified_source_language(self):
        catalogs = list(_catalog_pairs())
        self.assertGreater(len(catalogs), 0, "no String Catalog was found")
        for path, catalog in catalogs:
            with self.subTest(catalog=str(path.relative_to(ROOT))):
                self.assertEqual(catalog.get("sourceLanguage"), SOURCE_LOCALE)
                self.assertIsInstance(catalog.get("strings"), dict)

    def test_every_key_is_translated_in_traditional_and_japanese(self):
        for path, catalog in _catalog_pairs():
            relative = str(path.relative_to(ROOT))
            for key, entry in catalog["strings"].items():
                for locale in TARGET_LOCALES:
                    with self.subTest(catalog=relative, key=key, locale=locale):
                        value, state = _localized_value(entry, locale)
                        self.assertEqual(state, "translated")
                        self.assertIsInstance(value, str)
                        self.assertTrue(value.strip(), "the translation is empty")


class StringCatalogPlaceholderTests(unittest.TestCase):
    def test_placeholders_match_the_simplified_source(self):
        for path, catalog in _catalog_pairs():
            relative = str(path.relative_to(ROOT))
            for key, entry in catalog["strings"].items():
                source = _source_text(entry, key)
                expected = _specifiers(source)
                for locale, localization in (entry.get("localizations") or {}).items():
                    if locale == SOURCE_LOCALE:
                        continue
                    unit = (localization or {}).get("stringUnit") or {}
                    value = unit.get("value") or ""
                    with self.subTest(catalog=relative, key=key, locale=locale):
                        self.assertEqual(_specifiers(value), expected)


class JapaneseWordingTests(unittest.TestCase):
    def _allowlist(self) -> dict[tuple[str, str], str]:
        payload = json.loads(CATALOG_ALLOWLIST.read_text(encoding="utf-8"))
        return {
            (entry["catalog"], entry["key"]): entry["value"]
            for entry in payload["japaneseMatchesSource"]
        }

    def test_japanese_differs_from_simplified_chinese(self):
        allowed = self._allowlist()
        used: set[tuple[str, str]] = set()
        matches = []
        for path, catalog in _catalog_pairs():
            relative = str(path.relative_to(ROOT))
            for key, entry in catalog["strings"].items():
                source = _source_text(entry, key)
                value, _ = _localized_value(entry, "ja")
                if value != source:
                    continue
                pinned = allowed.get((relative, key))
                if pinned is not None:
                    used.add((relative, key))
                    self.assertEqual(pinned, value, "the pinned exemption no longer matches")
                    continue
                matches.append(f"{relative}: {key} = {source!r}")
        self.assertEqual(matches, [], "Japanese repeats the Simplified string")

    def test_allowlist_entries_are_still_needed(self):
        allowed = self._allowlist()
        unused = []
        for catalog, key in sorted(allowed):
            matches = [
                entry
                for path, catalog_data in _catalog_pairs()
                if str(path.relative_to(ROOT)) == catalog
                for entry_key, entry in catalog_data["strings"].items()
                if entry_key == key
            ]
            if not matches:
                unused.append(f"{catalog}: {key} does not exist")
                continue
            value, _ = _localized_value(matches[0], "ja")
            if value != _source_text(matches[0], key):
                unused.append(f"{catalog}: {key} is translated now")
        self.assertEqual(unused, [], "stale Japanese exemptions")


class GenerationTests(unittest.TestCase):
    def test_generator_discovers_every_catalog(self):
        self.assertEqual(
            sorted(generator.find_catalogs(ROOT)),
            sorted(_catalog_paths()),
        )

    def test_traditional_values_are_current(self):
        completed = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            cwd=str(ROOT),
            text=True,
            capture_output=True,
        )
        self.assertEqual(
            completed.returncode,
            0,
            "Tools/Localization/gen_zh_hant_strings.py --check failed:\n"
            + completed.stdout
            + completed.stderr,
        )

    def test_shared_override_table_is_pinned(self):
        overrides = generator.load_overrides(OVERRIDES)
        self.assertEqual({tuple(pair) for pair in overrides["replacements"]}, SHARED_REPLACEMENTS)
        payload = json.loads(OVERRIDES.read_text(encoding="utf-8"))
        self.assertEqual(payload["opencc"], {"version": "1.1.9", "config": "s2twp"})


class GeneratorUnitTests(unittest.TestCase):
    def _catalog(self, *keys: str) -> dict:
        return {
            "sourceLanguage": SOURCE_LOCALE,
            "strings": {
                key: {
                    "localizations": {
                        SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": key}},
                    }
                }
                for key in keys
            },
            "version": "1.0",
        }

    def test_generated_value_uses_overrides_and_keeps_other_locales(self):
        catalog = {
            "sourceLanguage": SOURCE_LOCALE,
            "strings": {
                "k1": {
                    "localizations": {
                        SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "简体数据"}},
                        "en": {"stringUnit": {"state": "translated", "value": "data"}},
                    }
                }
            },
            "version": "1.0",
        }
        overrides = generator.load_overrides(OVERRIDES)

        def convert(texts):
            return [text.replace("简体", "繁體") for text in texts]

        expected = generator.expected_hant(catalog, overrides, convert)
        self.assertEqual(expected, {"k1": "繁體資料"})
        generator.apply_hant(catalog, expected)
        self.assertEqual(_localized_value(catalog["strings"]["k1"], "zh-Hant"), ("繁體資料", "translated"))
        self.assertEqual(_localized_value(catalog["strings"]["k1"], "en"), ("data", "translated"))

    def test_key_is_the_source_when_no_simplified_value_exists(self):
        catalog = {"sourceLanguage": SOURCE_LOCALE, "strings": {"plainKey": {}}, "version": "1.0"}
        overrides = generator.load_overrides(OVERRIDES)
        self.assertEqual(generator.expected_hant(catalog, overrides, _identity), {"plainKey": "plainKey"})

    def test_source_language_must_be_simplified_chinese(self):
        generator.require_source_language({"sourceLanguage": SOURCE_LOCALE}, "ok.xcstrings")
        with self.assertRaises(generator.GenerationError):
            generator.require_source_language({"sourceLanguage": "en"}, "bad.xcstrings")
        with self.assertRaises(generator.GenerationError):
            generator.require_source_language({}, "missing.xcstrings")

    def test_placeholders_and_ascii_text_must_survive(self):
        overrides = generator.load_overrides(OVERRIDES)

        def convert(texts):
            return [text + "!" for text in texts]

        with self.assertRaises(generator.GenerationError):
            generator.finish_value("下载 %@", "k1", "下載", overrides)
        with self.assertRaises(generator.GenerationError):
            generator.expected_hant(self._catalog("k1"), overrides, convert)

    def test_banned_wording_is_rejected(self):
        overrides = {"replacements": (), "byKey": {}, "banned": ("數據",)}
        with self.assertRaises(generator.GenerationError):
            generator.finish_value("数据", "k1", "數據", overrides)
        self.assertEqual(generator.finish_value("数据", "k1", "資料", overrides), "資料")

    def test_longer_override_left_sides_win(self):
        with fixture_directory() as directory:
            path = _write_overrides(
                directory,
                {
                    "replacements": [["數據", "資料"], ["大數據", "大資料集"]],
                    "byKey": {},
                },
            )
            overrides = generator.load_overrides(path)
            self.assertEqual(generator.apply_rules("大數據", overrides["replacements"]), "大資料集")

    def test_by_key_overrides_apply_to_their_key_only(self):
        with fixture_directory() as directory:
            path = _write_overrides(
                directory,
                {"replacements": [], "byKey": {"k1": [["保存", "儲存"]]}},
            )
            overrides = generator.load_overrides(path)

            def convert(texts):
                return ["保存" for _ in texts]

            catalog = {
                "sourceLanguage": SOURCE_LOCALE,
                "strings": {
                    key: {
                        "localizations": {
                            SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "保存"}},
                        }
                    }
                    for key in ("k1", "k2")
                },
                "version": "1.0",
            }
            expected = generator.expected_hant(catalog, overrides, convert)
            self.assertEqual(expected, {"k1": "儲存", "k2": "保存"})

    def test_differences_report_missing_wrong_and_current_values(self):
        with fixture_directory() as directory:
            path = _write_overrides(directory, {"replacements": [], "byKey": {}})
            overrides = generator.load_overrides(path)
            catalog = {
                "sourceLanguage": SOURCE_LOCALE,
                "strings": {
                    "current": {
                        "localizations": {
                            SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "甲"}},
                            "zh-Hant": {"stringUnit": {"state": "translated", "value": "甲"}},
                        }
                    },
                    "missing": {
                        "localizations": {
                            SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "乙"}},
                        }
                    },
                    "wrong": {
                        "localizations": {
                            SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "丙"}},
                            "zh-Hant": {"stringUnit": {"state": "translated", "value": "丁"}},
                        }
                    },
                },
                "version": "1.0",
            }
            expected = generator.expected_hant(catalog, overrides, _identity)
            differences = generator.catalog_differences(catalog, expected)
            self.assertEqual([difference.key for difference in differences], ["missing", "wrong"])
            self.assertIsNone(differences[0].actual)
            self.assertEqual(differences[1].actual, "丁")
            generator.apply_hant(catalog, expected)
            self.assertEqual(generator.catalog_differences(catalog, expected), [])

    def test_serialized_catalog_uses_the_xcode_layout(self):
        catalog = {
            "sourceLanguage": SOURCE_LOCALE,
            "strings": {
                "键": {
                    "localizations": {
                        SOURCE_LOCALE: {"stringUnit": {"state": "translated", "value": "简体"}},
                    }
                }
            },
            "version": "1.0",
        }
        text = generator.serialize_catalog(catalog)
        self.assertEqual(json.loads(text), catalog)
        self.assertTrue(text.startswith('{\n  "sourceLanguage": "zh-Hans",\n'))
        self.assertIn('\n  "strings": {\n    "键": {', text)
        self.assertIn('"简体"', text)
        self.assertNotIn("\\u", text)
        self.assertFalse(text.endswith("\n"))


class ScannerUnitTests(unittest.TestCase):
    def setUp(self):
        self.config = scanner.load_config(SCAN_CONFIG)

    def _findings(self, source: str) -> list[scanner.Finding]:
        return scanner.find_violations(source, self.config)

    def _values(self, source: str) -> list[str]:
        return [finding.value for finding in self._findings(source)]

    def test_swiftui_text_literals_are_allowed(self):
        self.assertEqual(self._findings('Text("保存")'), [])

    def test_other_swiftui_literals_are_reported(self):
        self.assertEqual(self._values('Button("保存") {}'), ["保存"])
        self.assertEqual(self._values('.accessibilityLabel("删除")'), ["删除"])
        self.assertEqual(self._values('Section("布局") {}'), ["布局"])

    def test_verbatim_text_is_reported(self):
        self.assertEqual(self._values('Text(verbatim: "中文")'), ["中文"])

    def test_logging_literals_are_allowed(self):
        self.assertEqual(self._findings('logger.error("引擎启动失败")'), [])
        self.assertEqual(self._findings('print("启动完成")'), [])

    def test_localized_keys_are_allowed(self):
        self.assertEqual(self._findings('String(localized: "保存")'), [])
        self.assertEqual(self._findings('NSLocalizedString("保存", comment: "")'), [])

    def test_key_cap_data_is_allowed(self):
        source = 'KeyCap(id: "x", title: "分词", action: .literal("，"))'
        self.assertEqual(self._findings(source), [])
        provider = 'func spaceTitle() -> String { switch script { case .japanese: return "空白" } }'
        self.assertEqual(self._findings(provider), [])

    def test_exact_data_exemption_is_scoped_to_path_and_value(self):
        config = dict(self.config)
        config["dataLiterals"] = [{"path": "Packages/Example/Sources/Folder.swift", "value": "Rime 配置", "reason": "Persistent directory identifier"}]
        source = 'let name = "Rime 配置"'
        self.assertEqual(scanner.find_violations(source, config, path="Packages/Example/Sources/Folder.swift"), [])
        self.assertEqual(len(scanner.find_violations(source, config, path="Apps/Other.swift")), 1)
        self.assertEqual(len(scanner.find_violations('let name = "新增配置"', config, path="Packages/Example/Sources/Folder.swift")), 1)

    def test_ui_choice_arrays_are_not_implicitly_data(self):
        self.assertEqual(self._values('let choices = ["显示", "隐藏"]'), ["显示", "隐藏"])

    def test_data_tables_are_allowed(self):
        self.assertEqual(self._findings('let symbols = ["，", "。"]'), [])
        self.assertEqual(self._findings('DemoWord(text: "你好", syllables: ["ni"])'), [])

    def test_comments_are_ignored(self):
        self.assertEqual(self._findings('// Text 中文注释\nlet value = 1'), [])

    def test_multiline_and_raw_literals_are_reported(self):
        multiline = 'let message = """\n中文\n"""'
        findings = self._findings(multiline)
        self.assertEqual([finding.value for finding in findings], ["中文"])
        self.assertEqual(self._values('let value = #"中文"#'), ["中文"])

    def test_escaped_quotes_do_not_hide_a_literal(self):
        self.assertEqual(self._values('let text = "他说\\"你好\\""'), ['他说"你好"'])

    def test_interpolated_text_keeps_nested_literals_visible(self):
        source = 'Text("\\(isOn ? "已开启" : "已关闭")")'
        self.assertEqual(self._values(source), ["已开启", "已关闭"])

    def test_tests_are_skipped(self):
        config = scanner.load_config(SCAN_CONFIG)
        with fixture_directory() as directory:
            root = Path(directory)
            (root / "Apps").mkdir()
            (root / "Apps" / "Sample.swift").write_text('Text("中文")', encoding="utf-8")
            (root / "Tests").mkdir()
            (root / "Tests" / "SampleTests.swift").write_text('Text("中文")', encoding="utf-8")
            discovered = scanner.discover_sources(root, config)
            self.assertEqual([path.name for path in discovered], ["Sample.swift"])

    def test_scan_scope_is_not_allowlisted_away(self):
        config = scanner.load_config(SCAN_CONFIG)
        for broad in ("Apps", "Packages", "Sources", "SharedKeyboard", "HostApp", "KeyboardCore"):
            self.assertNotIn(broad, config["skippedPathComponents"])
        discovered = scanner.discover_sources(ROOT, config)
        self.assertGreater(len(discovered), 200, "the scan must cover the production Swift sources")
        self.assertTrue(any("Apps/HostApp" in str(path) for path in discovered))
        self.assertTrue(any("/Sources/" in str(path) for path in discovered))


class RimeTextFormatTests(unittest.TestCase):
    """`%@` templates take objects; an Int passed to one crashes at runtime."""

    def test_object_placeholders_never_receive_raw_integers(self):
        sources = (ROOT / "Packages/RimeBridge/Sources/RimeBridge").rglob("*.swift")
        text = "\n".join(path.read_text(encoding="utf-8") for path in sources)
        call = re.search(r'engine\.diagnostic\.candidateRequestInvalid",(.{0,160})', text, re.S)
        self.assertIsNotNone(call, "the candidate request message call must exist")
        self.assertNotRegex(call.group(1), r"\bfromIndex,\s*count\b")
        self.assertIn("String(describing: fromIndex)", call.group(1))


class HardcodedChineseTests(unittest.TestCase):
    def test_sources_have_no_raw_chinese_user_visible_literals(self):
        config = scanner.load_config(SCAN_CONFIG)
        findings, scanned = scanner.scan_tree(ROOT, config)
        self.assertGreater(scanned, 200, "the scan must cover the production Swift sources")
        if not findings:
            return
        report = "\n".join(
            f"{finding.path}:{finding.line}: {finding.value}" for finding in findings[:40]
        )
        self.fail(
            f"{len(findings)} raw Chinese user-visible literals in {scanned} Swift files:\n{report}"
        )


if __name__ == "__main__":
    unittest.main()
