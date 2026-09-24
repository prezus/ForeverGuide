"""Regression: the Forever API check must reject a misspelled ns.Call path."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = os.environ.get("FOREVER_UI_SOURCE")
sys.path.insert(0, str(ROOT / "tools"))
import check_forever_api


class InterfaceTest(unittest.TestCase):
    def test_interface_matches_client_version(self):
        with tempfile.TemporaryDirectory() as directory:
            toc = Path(directory) / "ForeverGuide.toc"
            toc.write_text("## Interface: 16001\n")
            check_forever_api.check_interface(toc)
            toc.write_text("## Interface: 16000\n")
            with self.assertRaises(SystemExit):
                check_forever_api.check_interface(toc)


@unittest.skipUnless(SOURCE, "set FOREVER_UI_SOURCE to a pinned Forever UI source checkout")
class ForeverAPITest(unittest.TestCase):
    def test_known_path_passes_and_typo_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            lua = Path(directory) / "probe.lua"
            command = [sys.executable, str(ROOT / "tools/check_forever_api.py"), SOURCE, str(lua)]
            lua.write_text('ns.Call("C_Map.GetBestMapForUnit", "player")\n')
            good = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
            lua.write_text('ns.Call("C_Map.GetBestMapForUnitt", "player")\n')
            bad = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("C_Map.GetBestMapForUnitt", bad.stdout + bad.stderr)
            lua.write_text("ns.Call('C_Map.GetBestMapForUnitt', 'player')\n")
            bad = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("C_Map.GetBestMapForUnitt", bad.stdout + bad.stderr)

    def test_direct_call_and_guarded_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            lua = Path(directory) / "probe.lua"
            command = [sys.executable, str(ROOT / "tools/check_forever_api.py"), SOURCE, str(lua)]
            lua.write_text('C_Timer.After(1, function() end)\nif C_Map.GetMapPosFromWorldPos then end\n')
            good = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
            lua.write_text('C_Timer.Aftr(1, function() end)\nif C_Map.GetMapPosFromWorldPos then end\n')
            bad = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn('C_Timer.Aftr', bad.stdout + bad.stderr)
            lua.write_text('if C_Map.GetMapPosFromWorldPox then end\n')
            bad = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn('C_Map.GetMapPosFromWorldPox', bad.stdout + bad.stderr)
            lua.write_text('-- C_Timer.Aftr(1)\nlocal text = "C_Timer.Aftr(1)"\n')
            good = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(good.returncode, 0, good.stdout + good.stderr)


if __name__ == "__main__":
    unittest.main()
