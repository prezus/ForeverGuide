#!/usr/bin/env python3
"""
Fold what the addon recorded in-game into the Forever data overlay.

    python tools/merge_recorded.py                 # every ForeverGuide.lua(.bak) under WTF\\Account
    python tools/merge_recorded.py <file> [...]    # specific SavedVariables files

Reads ForeverGuideDB.contrib (the facts Contribute data keeps: quest givers and
enders, NPC spots, objective spots and target votes, maps), .harvest.lines and
.scan.quests / .scan.info, merges them into data-src/forever.json and rewrites
Data/ForeverDB.lua. merge_share() takes the same facts in the /fg share JSON shape
(docs/SHARE-FORMAT.md). Vanilla quests only gain what the database lacks (Forever
moved or renamed some NPCs); unknown quests become full new entries. Merging the
same facts twice changes nothing.

Because the beta sometimes fails to load SavedVariables on login and then
overwrites them, the .bak files and every account/character are read too,
and evidence is only ever added, never removed.
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import foreverdb  # noqa: E402

# the beta client's WTF\Account folder: the default Windows install, or the WOW_WTF_ACCOUNT env var
DEFAULT_WTF = os.environ.get("WOW_WTF_ACCOUNT") or r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"
PLACEHOLDER = re.compile(r"^\s*(None|<[^>]*>.*|REUSE|reuse|.*\(\d+\)aa|\[(DEPRECATED|DNT|Never used|PH|NYI|TEMP)\b[^\]]*\].*|UNUSED.*|z*test.*|DEPRECATED.*)\s*$", re.I)


def clean_objective(txt):
    """Objective text without its progress counter ("Wolves slain: 3/10" -> "Wolves slain",
    "4/4 Chunk of Boar Meat" -> "Chunk of Boar Meat"). Returns "" when nothing is left."""
    if not isinstance(txt, str):
        return ""
    clean = re.sub(r"[:\s]*\d+\s*/\s*\d+\s*$", "", txt)
    clean = re.sub(r"^\s*\d+\s*/\s*\d+\s*", "", clean)
    return clean.strip(" :\t")


def vanilla_ids():
    """Quest / npc ids the vanilla database already knows (from Data/*.lua)."""
    ids = {"quests": set(), "npcs": set()}
    for fn, key in (("QuestDB.lua", "quests"), ("NpcDB.lua", "npcs")):
        path = os.path.join(foreverdb.TABLES, fn)
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = re.match(r"^\[(\d+)\]=", line)
                    if m:
                        ids[key].add(int(m.group(1)))
    return ids


def ids(v):
    """Integer ids from a Lua/JSON map key or list entry; None when it is not one."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return int(f) if f == int(f) else None


def items(v):
    """(id, value) pairs of a map keyed by id: JSON string keys or Lua integer keys."""
    if not isinstance(v, dict):
        return []
    return [(ids(k), x) for k, x in v.items() if ids(k) is not None]


def cells(v):
    """[x, y] pairs from a list of cells."""
    out = []
    for c in foreverdb.as_list(v):
        c = foreverdb.as_list(c)
        if len(c) == 2 and all(isinstance(n, (int, float)) for n in c):
            out.append([c[0], c[1]])
    return out


def merge_share(share, db, stats):
    """Fold one contribution into the overlay. `share` has the /fg share JSON shape
    (docs/SHARE-FORMAT.md); SavedVariables' ForeverGuideDB.contrib is read the same way."""
    for mid, info in items(share.get("maps")):
        if isinstance(info, dict) and info.get("name"):
            m = db["maps"].setdefault(str(mid), {})
            m["name"] = info["name"]
            if ids(info.get("parent")):
                m["parent"] = ids(info["parent"])
            b = foreverdb.as_list(info.get("bounds"))
            if len(b) == 5 and all(isinstance(v, (int, float)) for v in b):
                stats.setdefault("bounds", {})[str(mid)] = {"inst": int(b[0]), "x0": b[1], "y0": b[2], "x1": b[3], "y1": b[4]}
    names = {}
    for nid, info in items(share.get("npcs")):
        if not isinstance(info, dict):
            continue
        n = db["npcs"].setdefault(str(nid), {})
        if info.get("name"):
            n["n"] = names[nid] = info["name"]
        if ids(info.get("level")):
            n["lvl"] = ids(info["level"])
        spots = [(mid, c) for mid, cl in items(info.get("cells")) for c in cells(cl)]
        if spots and "rec" not in (n.get("src") or []):
            # first position seen in this game: it replaces anything a guide source said
            n.pop("spw", None)
            n["spm"] = {}
        for mid, c in spots:
            if foreverdb.add_point(n.setdefault("spm", {}), mid, c):
                stats["npc_points"] += 1
        foreverdb.note_source(n, "rec")
    for qid, info in items(share.get("quests")):
        if not isinstance(info, dict):
            continue
        q = db["quests"].setdefault(str(qid), {})
        title = info.get("name")
        if isinstance(title, str) and title and not PLACEHOLDER.match(title):
            q["n"] = title
        if ids(info.get("level")):
            q["lvl"] = ids(info["level"])
        foreverdb.note_source(q, "rec")
        for field, qkey, nkey in (("givers", "snpc", "starts"), ("enders", "enpc", "ends")):
            for nid in (ids(v) for v in foreverdb.as_list(info.get(field))):
                if nid is None:
                    continue
                foreverdb.add_unique(q.setdefault(qkey, []), nid)
                foreverdb.add_unique(db["npcs"].setdefault(str(nid), {}).setdefault(nkey, []), qid)
                stats["starts" if field == "givers" else "ends"] += 1
        for idx, o_in in sorted(items(info.get("objectives"))):
            if not isinstance(o_in, dict) or idx < 1:
                continue
            objs = q.setdefault("obj", [])
            while len(objs) < idx:
                objs.append({})
            o = objs[idx - 1]
            txt = o_in.get("text")
            clean = clean_objective(txt)
            if clean:
                o["text"] = clean
            # the most-voted target is the kill target only when the objective text names it;
            # otherwise the targets are just hints
            votes = sorted(((v, nid) for nid, v in items(o_in.get("targets")) if isinstance(v, (int, float))), reverse=True)
            top = votes[0][1] if votes else None
            top_name = names.get(top) or (db["npcs"].get(str(top)) or {}).get("n") if top else None
            if top and top_name and isinstance(txt, str) and top_name.lower() in txt.lower():
                o["kind"], o["id"], o["name"] = "kill", top, top_name
            elif not o.get("kind"):
                o["kind"] = "item" if isinstance(txt, str) and re.search(r"^\s*\d+\s*/\s*\d+", txt) else "event"
            for _, nid in votes:
                if nid != o.get("id"):
                    foreverdb.add_unique(o.setdefault("near", []), nid)
            for mid, cl in items(o_in.get("cells")):
                for c in cells(cl):
                    if foreverdb.add_point(o.setdefault("spm", {}), mid, c):
                        stats["obj_points"] += 1
    for qid, info in items(share.get("starts")):
        if isinstance(info, dict) and ids(info.get("map")) and info.get("x") is not None:
            q = db["quests"].setdefault(str(qid), {})
            q.setdefault("start", {})
            foreverdb.add_point(q["start"].setdefault("spm", {}), ids(info["map"]), [info["x"], info["y"]])
            foreverdb.note_source(q, "harvest")
    for qid, title in items(share.get("titles")):
        if isinstance(title, str) and title and not PLACEHOLDER.match(title):
            q = db["quests"].setdefault(str(qid), {})
            q.setdefault("n", title)
            foreverdb.note_source(q, "scan")
            stats["titles"] += 1


def merge_file(path, db, stats):
    sv, _ = foreverdb.load_saved_variables(path)
    if not sv:
        return
    harvest, scan = sv.get("harvest") or {}, sv.get("scan") or {}
    share = dict(sv.get("contrib") or {})
    share["starts"] = harvest.get("lines") or {}
    share["titles"] = scan.get("quests") or {}
    merge_share(share, db, stats)
    # scanner: level and objective texts of quests it loaded
    for qid, info in items(scan.get("info")):
        if isinstance(info, dict):
            q = db["quests"].setdefault(str(qid), {})
            if info.get("lvl"):
                q["lvl"] = int(info["lvl"])
            texts = [clean_objective(t) for t in foreverdb.as_list(info.get("obj"))]
            if any(texts):
                objs = q.setdefault("obj", [])
                for i, t in enumerate(texts):
                    while len(objs) <= i:
                        objs.append({})
                    objs[i].setdefault("kind", "event")
                    if t:
                        objs[i]["text"] = t      # a bare counter ("0/5") carries no wording: keep the slot, no text
                if not any(o.get("text") for o in objs):
                    del q["obj"]
            foreverdb.note_source(q, "scan")


def main():
    files = sys.argv[1:]
    if not files:
        files = glob.glob(os.path.join(DEFAULT_WTF, "*", "SavedVariables", "ForeverGuide.lua*"))
    if not files:
        print("no SavedVariables files found; pass them as arguments")
        return 1
    db = foreverdb.load()
    known = vanilla_ids()
    stats = {"npc_points": 0, "starts": 0, "ends": 0, "obj_points": 0, "titles": 0}
    for f in files:
        print("reading", os.path.basename(f))  # the full path names the account folder
        merge_file(f, db, stats)
    # drop entries that carry nothing useful
    for qid in list(db["quests"].keys()):
        q = db["quests"][qid]
        if not any(k in q for k in ("n", "snpc", "enpc", "obj", "start")):
            del db["quests"][qid]
    foreverdb.save(db)
    counts = foreverdb.emit_lua(db)
    # map bounds / sizes for the offline tools (world -> map conversion, yards per map unit)
    if stats.get("bounds"):
        bpath = os.path.join(foreverdb.ROOT, "data-src", "mapbounds.json")
        bounds = {}
        if os.path.isfile(bpath):
            with open(bpath, "r", encoding="utf-8") as fh:
                bounds = json.load(fh)
        bounds.update(stats["bounds"])
        with open(bpath, "w", encoding="utf-8") as fh:
            json.dump(bounds, fh, indent=1, sort_keys=True)
        sizes = {mid: [abs(b["y0"] - b["y1"]), abs(b["x0"] - b["x1"])] for mid, b in bounds.items()}
        with open(os.path.join(foreverdb.ROOT, "data-src", "mapsizes.json"), "w", encoding="utf-8") as fh:
            json.dump(sizes, fh, indent=1, sort_keys=True)
        print("map bounds known for %d maps -> data-src/mapbounds.json / mapsizes.json" % len(bounds))
    new_q = sum(1 for k in db["quests"] if int(k) not in known["quests"])
    new_n = sum(1 for k in db["npcs"] if int(k) not in known["npcs"])
    print("merged: %(starts)d giver links, %(ends)d turn-in links, %(npc_points)d npc points, %(obj_points)d objective points, %(titles)d titles" % stats)
    print("overlay now: %d quests (%d not in vanilla), %d npcs (%d new), %d objects, %d maps -> Data/ForeverDB.lua" % (
        counts["quests"], new_q, counts["npcs"], new_n, counts["objects"], counts["maps"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
