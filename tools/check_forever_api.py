#!/usr/bin/env python3
"""Check literal ns.Call paths and direct C_ namespace references against Forever's pinned API docs.

Usage: python3 tools/check_forever_api.py <wow-ui-source checkout> [Lua files...]
Without file arguments, checks handwritten root and UI/ Lua files only.
This does not validate dynamic paths, globals, arguments, or runtime availability.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.60.1.69977"
DOCS = Path("Interface/AddOns/Blizzard_APIDocumentationGenerated")
FUNCTION = re.compile(r'^\t\t\{\s*\n\t\t\tName = "([^"]+)",\s*\n\t\t\tType = "Function"', re.M)
NAMESPACE = re.compile(r'^\s*Namespace = "([^"]+)"', re.M)
CALL = re.compile(r"\bns\.Call\s*\(\s*(['\"])(C_\w+\.\w+)\1")
DIRECT = re.compile(r"\b(C_\w+)\s*\.\s*(\w+)\b")
STRING = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'")


def check_interface(toc):
    major, minor, patch = map(int, VERSION.split(".")[:3])
    expected = major * 10000 + minor * 100 + patch
    match = re.search(r"^## Interface:\s*(\d+)\s*$", toc.read_text(), re.M)
    if not match or int(match.group(1)) != expected:
        raise SystemExit(f"{toc}: expected ## Interface: {expected} for Forever {VERSION}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    version = source / "version.txt"
    if not version.is_file() or version.read_text().strip() != VERSION:
        raise SystemExit(f"expected Forever UI source {VERSION}: {source}")
    check_interface(ROOT / "ForeverGuide.toc")
    docs = sorted((source / DOCS).glob("*Documentation.lua"))
    if not docs:
        raise SystemExit(f"no generated API documentation in {source / DOCS}")

    available = set()
    for doc in docs:
        text = doc.read_text()
        namespace = NAMESPACE.search(text)
        if namespace:
            available.update(namespace.group(1) + "." + name for name in FUNCTION.findall(text))

    files = [Path(p) for p in sys.argv[2:]] or sorted(ROOT.glob("*.lua")) + sorted((ROOT / "UI").glob("*.lua"))
    missing = []
    literal_count = direct_count = 0
    for path in files:
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            # Ignore Lua line comments; mask quoted strings for direct references.
            code = line.split("--", 1)[0]
            names = [name for _, name in CALL.findall(code)]
            literal_count += len(names)
            direct = [namespace + "." + function for namespace, function in DIRECT.findall(STRING.sub("", code))]
            direct_count += len(direct)
            for name in names + direct:
                if name not in available:
                    missing.append(f"{path}:{line_number}: {name} not documented by Forever {VERSION}")
    if missing:
        raise SystemExit("\n".join(missing))
    print(f"OK: {literal_count} ns.Call paths and {direct_count} direct references documented by Forever {VERSION}")


if __name__ == "__main__":
    main()
