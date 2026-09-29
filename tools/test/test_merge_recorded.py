#!/usr/bin/env python3
"""A contribution merges its facts into the overlay once: merging it again changes nothing,
and fields outside the share format are never picked up."""

import copy
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import merge_recorded  # noqa: E402

SHARE = {
    "format": 2,
    "maps": {"1429": {"name": "Elwynn Forest", "parent": 1415, "bounds": [0, 1.0, 2.0, 3.0, 4.0]}},
    "npcs": {
        "9001": {"name": "Marshal Test", "level": 20, "cells": {"1429": [[48.5, 41.5]]}},
        "321": {"name": "Test Wolf", "level": 3, "cells": {"1429": [[50.0, 60.0]]}},
        "555": {"name": "Passer By", "cells": {"1429": [[51.0, 61.0]]}},
    },
    "quests": {
        "5010": {
            "name": "Fact Quest", "level": 5, "givers": [9001], "enders": [9002], "sharer": "Partymate",
            "objectives": {"1": {"text": "Test Wolf slain: 3/5", "cells": {"1429": [[50.0, 60.0]]},
                                 "targets": {"321": 3, "555": 1}}},
        },
        "5011": {"name": "Collect Quest",
                 "objectives": {"1": {"text": "4/6 Wolf Pelt", "targets": {"321": 2}}}},
    },
    "starts": {"5012": {"map": 1429, "x": 40.0, "y": 30.0, "line": 7}},
    "titles": {"5013": "A Title Only", "5014": "[DNT] placeholder"},
    "reports": [{"text": "not merged here"}],
}


def empty():
    return {"quests": {}, "npcs": {}, "objects": {}, "maps": {}}


def stats():
    return {"npc_points": 0, "starts": 0, "ends": 0, "obj_points": 0, "titles": 0}


db = empty()
merge_recorded.merge_share(copy.deepcopy(SHARE), db, stats())
q = db["quests"]["5010"]
assert q["n"] == "Fact Quest" and q["lvl"] == 5 and q["snpc"] == [9001] and q["enpc"] == [9002], q
assert db["npcs"]["9001"]["starts"] == [5010] and db["npcs"]["9002"]["ends"] == [5010]
assert db["npcs"]["9001"]["spm"] == {"1429": [[48.5, 41.5]]} and db["npcs"]["9001"]["lvl"] == 20
o = q["obj"][0]
assert o["kind"] == "kill" and o["id"] == 321 and o["name"] == "Test Wolf" and o["text"] == "Test Wolf slain", o
assert o["near"] == [555] and o["spm"] == {"1429": [[50.0, 60.0]]}, o
# a target the objective text does not name is only a hint
o2 = db["quests"]["5011"]["obj"][0]
assert o2["kind"] == "item" and "id" not in o2 and o2["near"] == [321], o2
assert db["quests"]["5012"]["start"]["spm"] == {"1429": [[40.0, 30.0]]}
assert db["quests"]["5013"]["n"] == "A Title Only" and "5014" not in db["quests"]
assert db["maps"]["1429"] == {"name": "Elwynn Forest", "parent": 1415}

before = copy.deepcopy(db)
merge_recorded.merge_share(copy.deepcopy(SHARE), db, stats())
assert db == before, "merging the same share twice must change nothing"

# the same facts as SavedVariables write them: Lua integer keys and arrays
SV = """ForeverGuideDB = {
    ["contrib"] = {
        ["quests"] = { [5010] = { ["name"] = "Fact Quest", ["givers"] = { 9001 },
            ["objectives"] = { [1] = { ["text"] = "Test Wolf slain: 1/5", ["cells"] = { [1429] = { { 50, 60 } } },
                ["targets"] = { [321] = 1 } } } } },
        ["npcs"] = { [321] = { ["name"] = "Test Wolf", ["cells"] = { [1429] = { { 50, 60 } } } } },
        ["order"] = { 5010 }, ["maps"] = {}, ["errors"] = {},
    },
    ["harvest"] = { ["lines"] = { [5012] = { ["map"] = 1429, ["x"] = 40, ["y"] = 30, ["line"] = 7 } } },
    ["scan"] = { ["quests"] = { [5013] = "A Title Only" } },
}
"""
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "ForeverGuide.lua")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(SV)
    db = empty()
    merge_recorded.merge_file(path, db, stats())
    o = db["quests"]["5010"]["obj"][0]
    assert db["quests"]["5010"]["snpc"] == [9001] and o["kind"] == "kill" and o["id"] == 321, db["quests"]["5010"]
    assert o["spm"] == {"1429": [[50, 60]]} and db["npcs"]["321"]["spm"] == {"1429": [[50, 60]]}
    assert db["quests"]["5012"]["start"]["spm"] == {"1429": [[40, 30]]} and db["quests"]["5013"]["n"] == "A Title Only"

print("merge_recorded: ok")
