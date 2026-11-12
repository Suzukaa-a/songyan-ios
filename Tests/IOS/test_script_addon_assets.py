"""The empty script page's AI guide and minimal example are the shared sync set from
Tools/Script, not private copies: this guards against the copies drifting.
"""
import unittest

from swift_probe import ROOT

COPIES = {
    ROOT / "Tools/Script/resources/ai-guide.txt": ROOT / "Resources/ScriptAddons/ai-guide.txt",
    ROOT / "Tools/Script/examples/minimal.js": ROOT / "Resources/ScriptAddons/minimal.js",
}


class ScriptAddonAssetTests(unittest.TestCase):
    def test_bundled_copies_match_the_shared_sync_set(self):
        for source, copy in COPIES.items():
            self.assertTrue(source.is_file(), source)
            self.assertTrue(copy.is_file(), copy)
            self.assertEqual(
                source.read_bytes(), copy.read_bytes(),
                f"{copy.name} drifted from {source}")


if __name__ == "__main__":
    unittest.main()
