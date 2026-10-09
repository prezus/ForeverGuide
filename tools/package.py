#!/usr/bin/env python3
"""
Zip the addon for distribution.

    python tools/package.py            -> dist/ForeverGuide-<version>.zip   (runtime files only)
    python tools/package.py --dev      -> also tools/, guides-src/, data-src/ (for contributors)
    python tools/package.py --test     -> dist/ForeverGuide-<commit>.zip, checked test build (runtime files only)

Files come from the last commit (git HEAD), never from the folder on disk: this folder is
also the live addon the game loads, so it holds local files that must not ship - player
reports, SavedVariables copies, debug dumps, uncommitted edits. Commit what should ship.

The version comes from ## Version in the committed ForeverGuide.toc. The zip unpacks to
Interface\\AddOns\\ForeverGuide\\. Its TOC gains `## X-Build: <commit>`, the commit it was built from,
so the ForeverGuide Companion can tell which build is installed and offer the newer one.
"""

import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NAME = os.path.basename(ROOT)

RUNTIME_EXT = {".lua", ".xml", ".toc", ".tga", ".blp"}
RUNTIME_DIRS = {"", "Data", "Guides", "Textures", "UI"}
RELEASE_DOCS = {"LICENSE", "README.md", "CHANGELOG.md"}
DEV_DIRS = {"tools", "guides-src", "data-src"}


def committed():
    """{path: bytes} of every file in HEAD."""
    try:
        tar = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", "HEAD"],
                             check=True, capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError) as err:
        raise SystemExit("package.py builds from git HEAD; run it inside the addon's git checkout (%s)" % err)
    files = {}
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        for m in t.getmembers():
            if m.isfile():
                files[m.name] = t.extractfile(m).read()
    return files


def ships(path, dev=False):
    """True when a committed path belongs in the release (or, with dev, the contributor) zip."""
    folder, fn = posix_split(path)
    if fn.startswith("."):
        return False
    # Runtime folders ship at any depth: TUGs' guides sit in TUGs' own folders (Guides/TUGs/Alliance/...).
    if folder.split("/")[0] in RUNTIME_DIRS and os.path.splitext(fn)[1].lower() in RUNTIME_EXT:
        return True
    if folder == "" and fn in RELEASE_DOCS:
        return True
    if dev:
        return path.split("/")[0] in DEV_DIRS or (folder == "" and fn.endswith(".md"))
    return False


def posix_split(path):
    folder, _, fn = path.rpartition("/")
    return folder, fn


def version(files=None):
    text = (files or committed()).get(NAME + ".toc", b"").decode("utf-8")
    m = re.search(r"##\s*Version:\s*(\S+)", text)
    return m.group(1) if m else "0.0.0"


def stamp(toc, commit):
    """The TOC with `## X-Build: <commit>` after its ## Version line (or first, without one)."""
    lines = toc.decode("utf-8").splitlines(keepends=True)
    at = next((i + 1 for i, line in enumerate(lines) if re.match(r"##\s*Version:", line)), 0)
    lines.insert(at, "## X-Build: %s\n" % commit)
    return "".join(lines).encode("utf-8")


def unstamp(toc):
    """The TOC without its `## X-Build:` line: what was committed."""
    return re.sub(rb"^##\s*X-Build:[^\n]*\n", b"", toc, flags=re.M)


def head_commit():
    """Short hash of HEAD, the commit the zip is built from."""
    return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=7", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()


def main():
    dev = "--dev" in sys.argv
    test = "--test" in sys.argv
    if dev and test:
        raise SystemExit("--test packages runtime files only; do not combine it with --dev")
    files = committed()
    ver = version(files)
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    commit = head_commit()
    tag = commit if test else ver + ("-dev" if dev else "")
    out = os.path.join(out_dir, "%s-%s.zip" % (NAME, tag))
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(files):
            if ships(path, dev):
                data = stamp(files[path], commit) if path == NAME + ".toc" else files[path]
                z.writestr(NAME + "/" + path, data)
                n += 1
    dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True).stdout.strip()
    if dirty:
        print("note: packaged the last commit; %d uncommitted change(s) are not in the zip" % len(dirty.splitlines()))
    if test:
        subprocess.run([sys.executable, os.path.join(HERE, "check_package.py"), out], check=True)
        with open(out, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        print("SHA-256: %s" % digest)
    print("wrote %s (%d files, %.1f KB)" % (os.path.relpath(out, ROOT), n, os.path.getsize(out) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
