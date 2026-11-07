"""Check the offline deployment comparison without downloading dictionaries."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/BuildRimeIOS/scripts/prepare-kagiroi-probe.py"


class KagiroiDeploymentFixtureTests(unittest.TestCase):
    def test_source_excludes_nico_and_prebuilt_keeps_binary_payload(self):
        spec = importlib.util.spec_from_file_location("kagiroi_fixture", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, binary, output = (root / name for name in ("raw-source", "raw-binary", "fixture"))
            source.mkdir()
            (binary / "build").mkdir(parents=True)
            (source / "kagiroi.dict.yaml").write_text(
                "name: kagiroi\nimport_tables:\n  - kagiroi.mozc\n  - kagiroi.nico\n...\n", encoding="utf-8"
            )
            (source / "kagiroi.nico.dict.yaml").write_text("nico", encoding="utf-8")
            (source / "kagiroi.mozc.dict.yaml").write_text("mozc", encoding="utf-8")
            (source / "kagiroi.schema.yaml").write_text("schema: {}\n", encoding="utf-8")
            (source / "default.yaml").write_text("schema_list:\n  - schema: kagiroi\n", encoding="utf-8")
            (binary / "build/kagiroi.table.bin").write_bytes(b"upstream-binary")
            module.prepare(source, binary, output)
            self.assertFalse((output / "source/kagiroi.nico.dict.yaml").exists())
            self.assertNotIn("kagiroi.nico", (output / "source/kagiroi.dict.yaml").read_text())
            self.assertEqual("mozc", (output / "source/kagiroi.mozc.dict.yaml").read_text())
            self.assertEqual([], list((output / "prebuilt").glob("*.dict.yaml")))
            self.assertEqual(b"upstream-binary", (output / "prebuilt/build/kagiroi.table.bin").read_bytes())
            self.assertEqual(
                (output / "source/kagiroi.schema.yaml").read_bytes(),
                (output / "prebuilt/kagiroi.schema.yaml").read_bytes(),
            )

    def test_source_only_needs_no_upstream_prebuilt_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "upstream"
            source.mkdir()
            original = "name: kagiroi\nimport_tables:\n  - kagiroi.mozc\n  - kagiroi.nico\n...\n"
            (source / "kagiroi.schema.yaml").write_text("schema: {}\n", encoding="utf-8")
            (source / "kagiroi.dict.yaml").write_text(original, encoding="utf-8")
            (source / "kagiroi.mozc.dict.yaml").write_text("mozc", encoding="utf-8")
            (source / "kagiroi.nico.dict.yaml").write_text("nico", encoding="utf-8")
            output = root / "prepared"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--source", str(source), "--source-only", "--output", str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual({"source"}, set(json.loads(result.stdout)))
            self.assertFalse((output / "prebuilt").exists())
            self.assertFalse((output / "source/kagiroi.nico.dict.yaml").exists())
            self.assertNotIn("kagiroi.nico", (output / "source/kagiroi.dict.yaml").read_text())
            self.assertEqual("mozc", (output / "source/kagiroi.mozc.dict.yaml").read_text())
            self.assertEqual(original, (source / "kagiroi.dict.yaml").read_text())


if __name__ == "__main__":
    unittest.main()
