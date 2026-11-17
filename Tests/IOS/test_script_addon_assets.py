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

    def test_the_ios_guide_never_mentions_voice_scripts(self):
        # iOS has no voice input; the audio section lives in ai-guide-audio.txt, which only
        # Android appends. Tools/Script/tests/run.sh parses every example of both final guides.
        guide = (ROOT / "Resources/ScriptAddons/ai-guide.txt").read_text(encoding="utf-8")
        for word in ("@input audio", "audio", "语音"):
            self.assertNotIn(word, guide)
        self.assertTrue((ROOT / "Tools/Script/resources/ai-guide-audio.txt").is_file())
        self.assertFalse((ROOT / "Resources/ScriptAddons/ai-guide-audio.txt").exists())


if __name__ == "__main__":
    unittest.main()
