"""Regression: the release ZIP holds committed addon files only.

The addon folder is also the live one the game loads, so it collects local files (player
reports, SavedVariables copies, debug dumps, uncommitted edits). None of them may ship.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

TOOLS = Path(__file__).resolve().parents[1]
NAME = "ForeverGuide"


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / NAME
        r = self.repo
        # committed: a minimal loadable addon, contributor material and a dev tool
        write(r / (NAME + ".toc"), "## Version: 9.9.9\nCore.lua\nUI\\Frame.lua\nData\\DB.lua\n")
        write(r / "Core.lua", "-- committed\n")
        write(r / "UI" / "Frame.lua", "-- frame\n")
        write(r / "Data" / "DB.lua", "-- data\n")
        write(r / "LICENSE", "license\n")
        write(r / "README.md", "readme\n")
        write(r / "CHANGELOG.md", "changes\n")
        write(r / "AGENTS.md", "agent notes\n")
        write(r / "CONTRIBUTING.md", "contributing\n")
        write(r / "data-src" / "forever.json", "{}\n")
        write(r / ".gitignore", (TOOLS.parent / ".gitignore").read_text())
        (r / "tools").mkdir()
        for script in ("package.py", "check_package.py"):
            shutil.copy(TOOLS / script, r / "tools" / script)
        git(r, "init", "-q")
        git(r, "add", "-A")
        git(r, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "addon")
        # local, never committed: what a played-in addon folder picks up
        write(r / "notes.txt", "my character Bob-Realm\n")
        write(r / "UI" / "debug_dump.lua", "-- local dump\n")
        write(r / "Data" / "ForeverGuide.lua", "ForeverGuideDB = { char = 'Bob' }\n")
        write(r / "data-src" / "reports.json", '[{"text": "player report"}]\n')
        write(r / "data-src" / "sv" / "ForeverGuide.lua", "ForeverGuideDB = {}\n")
        write(r / "WTF" / "Account" / "ACCT" / "SavedVariables" / "ForeverGuide.lua", "x\n")
        write(r / ".DS_Store", "x")
        write(r / "Core.lua", "-- uncommitted local edit\n")

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, *flags):
        subprocess.run([sys.executable, "tools/package.py", *flags], cwd=self.repo, check=True, capture_output=True)
        suffix = "-dev" if "--dev" in flags else ""
        with zipfile.ZipFile(self.repo / "dist" / ("%s-9.9.9%s.zip" % (NAME, suffix))) as z:
            return {n: z.read(n).decode() for n in z.namelist()}

    def test_release_zip_holds_committed_runtime_files_only(self):
        files = self.build()
        p = NAME + "/"
        self.assertEqual(set(files), {p + n for n in (NAME + ".toc", "Core.lua", "UI/Frame.lua", "Data/DB.lua",
                                                      "LICENSE", "README.md", "CHANGELOG.md")})
        self.assertEqual(files[p + "Core.lua"], "-- committed\n", "an uncommitted edit must not ship")

    def test_dev_zip_adds_committed_sources_but_no_local_data(self):
        files = set(self.build("--dev"))
        p = NAME + "/"
        self.assertIn(p + "data-src/forever.json", files)
        self.assertIn(p + "tools/package.py", files)
        for leaked in ("data-src/reports.json", "data-src/sv/ForeverGuide.lua", "notes.txt", "UI/debug_dump.lua",
                       "Data/ForeverGuide.lua", ".DS_Store"):
            self.assertNotIn(p + leaked, files)
        self.assertFalse([f for f in files if "/WTF/" in f])

    def test_test_zip_is_named_after_the_commit_only(self):
        head = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "--short=7", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        subprocess.run([sys.executable, "tools/package.py", "--test"], cwd=self.repo, check=True, capture_output=True)
        self.assertEqual(sorted(p.name for p in (self.repo / "dist").iterdir()), ["%s-%s.zip" % (NAME, head)])

    def test_check_rejects_a_zip_with_an_uncommitted_file(self):
        self.build()
        archive = self.repo / "dist" / (NAME + "-9.9.9.zip")
        check = [sys.executable, "tools/check_package.py", str(archive)]
        self.assertEqual(subprocess.run(check, cwd=self.repo, capture_output=True).returncode, 0, "a clean build passes")
        with zipfile.ZipFile(archive, "a") as z:
            z.writestr(NAME + "/notes.txt", "my character Bob-Realm\n")
        result = subprocess.run(check, cwd=self.repo, capture_output=True)
        self.assertNotEqual(result.returncode, 0, "the check must fail on a file that is not a committed runtime file")


if __name__ == "__main__":
    unittest.main()
