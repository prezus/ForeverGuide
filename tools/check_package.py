#!/usr/bin/env python3
"""Check that the release ZIP loads every file its TOC/XML lists and holds only committed release files."""

import os
import posixpath
import re
import sys
import zipfile

from package import NAME, ROOT, committed, ships, version

archive = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/dist/{NAME}-{version()}.zip"
prefix = NAME + "/"
with zipfile.ZipFile(archive) as package:
    files = set(package.namelist())
    toc = prefix + NAME + ".toc"
    assert toc in files, f"missing {toc}"
    pending = [toc]
    while pending:
        path = pending.pop()
        text = package.read(path).decode("utf-8")
        if path.endswith(".toc"):
            refs = [line.strip() for line in text.splitlines()
                    if line.strip() and not line.lstrip().startswith("#")
                    and line.strip().lower().endswith((".lua", ".xml"))]
        else:
            refs = re.findall(r'<(?:Script|Include)\s+file="([^"]+)"', text, re.I)
        for ref in refs:
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), ref.replace("\\", "/")))
            assert target in files, f"{path} references missing {target}"
            if target.endswith(".xml"):
                pending.append(target)
    # only committed release files, byte for byte: nothing local (reports, SavedVariables
    # copies, dumps, uncommitted edits) and no development sources
    head = committed()
    for path in files:
        assert path.startswith(prefix), f"file outside addon folder: {path}"
        rel = path[len(prefix):]
        assert rel in head and ships(rel), f"not a committed release file: {path}"
        assert package.read(path) == head[rel], f"differs from the committed file: {path}"
    if os.path.isfile(os.path.join(ROOT, "LICENSE")):
        assert prefix + "LICENSE" in files, "LICENSE not included in release ZIP"
print(f"OK: {archive} contains all TOC/XML references and only committed release files")
