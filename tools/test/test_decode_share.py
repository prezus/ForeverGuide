#!/usr/bin/env python3
"""A share the addon writes can be decoded and validated with nothing but Python's standard
library and the published schema; a damaged share, or one holding a field outside the
allowlist, is refused."""

import base64
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import decode_share  # noqa: E402

with open(os.path.join(ROOT, "docs", "share-format.schema.json"), encoding="utf-8") as fh:
    SCHEMA = json.load(fh)

# the JSON the real Share.lua writes (Lua 5.1 or LuaJIT, as the game runs)
lua = next((shutil.which(x) for x in ("lua5.1", "luajit") if shutil.which(x)), None)
assert lua, "needs lua5.1 or luajit to run the addon's share writer"
written = subprocess.run([lua, os.path.join(ROOT, "tools", "test", "share_fixture.lua")],
                         check=True, capture_output=True, text=True).stdout
doc = json.loads(written)
assert decode_share.validate(doc, SCHEMA) == [], decode_share.validate(doc, SCHEMA)
assert '"sharer"' not in written and '"guid"' not in written and "lineName" not in written and '"t"' not in written
assert doc["quests"]["7"]["name"].startswith("Café ") and doc["titles"]["5013"] == 'Quote " and back\\slash and\nnewline'


def fg2(json_text, parts=1):
    payload = base64.b64encode(zlib.compress(json_text.encode("utf-8"))).decode("ascii")
    size = -(-len(payload) // parts)
    return ["FG2:%d/%d:%s" % (i + 1, parts, payload[i * size:(i + 1) * size]) for i in range(parts)]


def run(text):
    """(exit code, stdout, stderr) of the command-line tool on text."""
    path = os.path.join(HERE, "_share_test.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = decode_share.main([path])
    finally:
        os.remove(path)
    return code, out.getvalue(), err.getvalue()


# a one-part share, pasted with the player's own words around it
code, out, err = run("my notes from Elwynn\n" + fg2(written)[0] + "\nthanks!\n")
assert code == 0 and json.loads(out) == doc and "valid" in err, err
# three parts, pasted out of order, decode to the same JSON
p = fg2(written, 3)
code, out, _ = run("\n".join([p[2], p[0], p[1]]))
assert code == 0 and json.loads(out) == doc
# the plain-JSON form
code, out, _ = run("FG2J:1/1:" + written)
assert code == 0 and json.loads(out) == doc
# a missing part, a cut copy, and a field outside the allowlist are refused
code, _, err = run("\n".join(p[:2]))
assert code == 1 and "parts missing: 3" in err, err
code, _, err = run(fg2(written)[0][:-40])
assert code == 1 and "not a valid share" in err, err
tampered = json.loads(written)
tampered["profile"]["name"] = "Tester"
tampered["npcs"]["197"]["guid"] = "Player-1-1"
code, _, err = run(fg2(json.dumps(tampered))[0])
assert code == 1 and "'name' is not allowed" in err and "'guid' is not allowed" in err, err
tampered = json.loads(written)
tampered["quests"]["783"]["level"] = "one"
tampered["format"] = 3
code, _, err = run(fg2(json.dumps(tampered))[0])
assert code == 1 and "$.quests.783.level: must be integer" in err and "$.format: must be 2" in err, err

print("decode_share: ok")
