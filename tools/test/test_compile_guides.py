#!/usr/bin/env python3
"""A guide compiles to Lua that decodes back to the very steps its JSON holds, and a broken
guide is refused rather than compiled."""

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import compile_guides  # noqa: E402

SOURCE = os.path.join(ROOT, "tools", "test", "fixtures", "guides-src", "HUMAN_NORTHSHIRE_1_6.json")

# the decoded steps, one canonical line each, so Lua and Python can be compared as text
DUMP = r"""
local root, guidePath = arg[1], arg[2]
local ns = {}
assert(loadfile(root .. "/Core.lua"))("ForeverGuide", ns)
local guide
assert(loadfile(guidePath))("ForeverGuide", { RegisterGuide = function(g) guide = g end })
local steps = ns.DecodeRecord(guide.steps)
assert(#steps == guide.stepCount, "stepCount")
local function canon(v)
    if type(v) ~= "table" then
        if type(v) == "number" then return string.format("%.6g", v) end
        return tostring(v)
    end
    if #v > 0 then
        local out = {}
        for i = 1, #v do out[i] = canon(v[i]) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. canon(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
for _, s in ipairs(steps) do print(canon(s)) end
"""


def canon(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return "%.6g" % v
    if isinstance(v, list):
        return "[" + ",".join(canon(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join("%s=%s" % (k, canon(v[k])) for k in sorted(v)) + "}"
    return str(v)


lua = shutil.which("lua5.1") or shutil.which("luajit")
assert lua, "needs lua5.1 or luajit to load the compiled guide"

with open(SOURCE, encoding="utf-8") as fh:
    source = json.load(fh)
guide = compile_guides.validate(copy.deepcopy(source), os.path.basename(SOURCE))

with tempfile.TemporaryDirectory() as tmp:
    compiled = os.path.join(tmp, guide["id"] + ".lua")
    with open(compiled, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(compile_guides.compile_guide(guide))
    dump = os.path.join(tmp, "dump.lua")
    with open(dump, "w", encoding="utf-8") as fh:
        fh.write(DUMP)
    decoded = subprocess.run([lua, dump, ROOT, compiled], check=True, capture_output=True, text=True).stdout.splitlines()

assert len(decoded) == len(source["steps"]), (len(decoded), len(source["steps"]))
for i, (want, got) in enumerate(zip(source["steps"], decoded), 1):
    assert canon(want) == got, "step %d\n  json %s\n  lua  %s" % (i, canon(want), got)

# a guide the schema refuses never compiles
broken = copy.deepcopy(source)
del broken["steps"][0]["quest"]
try:
    compile_guides.validate(broken, "broken.json")
except compile_guides.GuideError as e:
    assert "quest" in str(e), e
else:
    raise AssertionError("an ACCEPT step without a quest was accepted")
print("compile_guides: ok")
