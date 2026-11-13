#!/usr/bin/env python3
"""Static gate for background-task registrations.

The app's launch handlers are main-actor code. Registered with a nil queue, the system calls them on
a background queue and Swift's isolation check traps (a TestFlight crash on the configuration
backup task). BGTaskScheduler does not run in the Simulator, so this is checked in the source.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTER = re.compile(r"\.register\(\s*forTaskWithIdentifier:[^)]*?using:\s*([^)\s]+)\s*\)", re.S)


class BackgroundTaskTests(unittest.TestCase):
    def test_launch_handlers_run_on_the_main_queue(self):
        found = []
        for path in (ROOT / "Apps").rglob("*.swift"):
            for queue in REGISTER.findall(path.read_text(encoding="utf-8")):
                found.append(path.relative_to(ROOT))
                self.assertIn(queue, (".main", "DispatchQueue.main"), f"{path.relative_to(ROOT)} uses {queue}")
        self.assertTrue(found, "no background-task registration found; update this gate")


if __name__ == "__main__":
    unittest.main()
