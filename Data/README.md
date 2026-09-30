# ForeverGuide bundled quest database

The files in `Data/` are published, packed, by [forever-codex](https://github.com/prezus/forever-codex)'s
data build, by pull request ([README](../README.md#how-this-repository-is-managed)); they are not edited by hand. The records come from
**Questie**'s Classic Era database (https://github.com/Questie/Questie, `Database/Classic/*.lua` +
`Database/Corrections/classic*Fixes.lua`) and from the WoW Forever sources below. Questie's own
corrections are applied the same way Questie applies them at load time, and quests on Questie's
blacklist are marked `hidden`. The WoW Forever overlay is merged in before packing.

The addon reads only `Data/`. CI checks every file is data only (`lua5.1 tools/test/check_data_only.lua`).

## Storage

Each quest, NPC, object and item record is one Lua table constructor in a long-bracket string,
keyed by id:

    ns.QuestDB = {
    [2]=[[{enpc={12696},lvl=30,n="Sharptalon's Claw",pre={6383},races=178,req=20}]],
    }

`DB.lua` decodes a record the first time it is read (`ns.DecodeRecord`: `loadstring` in an empty
environment, so the text can only build a value) and keeps it while it is in use. As strings the
records take about a quarter of the memory they take as live tables. The rules for writing them:

* **The record is the final record.** The Forever overlay (`forever = true` for new ids,
  `removed = true` for quests the client lacks, `spm`/`spw`/`fobj` evidence) is merged before
  packing; the addon never changes a record at runtime.
* **Canonical text.** The array part first (1..n without holes), then the other keys sorted, numbers
  in the shortest form that reads back to the same value, strings as `%q`. Ids ascending, one record
  per line, so a data change shows as the records that changed.
* **The same fields as the table below.** A decoded record has exactly the shape documented here;
  readers do not know how it was stored.
* **Indexes for what would decode everything.** `ns.QuestIndex.byZone[top-level areaID]` and
  `ns.QuestIndex.byItem[itemID]` list quest ids (ascending), so "quests in this zone" and "quests
  this item is for" do not decode every quest.
* `ZoneDB`, `ForeverQuestIDs` (`ns.ForeverNewQuestIDRanges`, `ns.ForeverQuestCounts`) and
  `VanillaQuestIDs` are small and stay plain tables.

A new build of the data must give the addon the same records as the old one wherever the inputs did
not change: `lua5.1 tools/test/dump_data.lua <addon folder> <out>` writes everything the addon reads
from its data (records, zone tables, scanner lists, guide steps) as canonical text, so two builds can
be compared with `diff`.

Attribution: the data is the work of the Questie contributors (and, through them, of the cmangos /
vmangos database projects). **Redistribution rights are not established by this attribution.**

## Redistribution status (unresolved)

| Shipped material | Source | What remains to check |
|---|---|---|
| `Data/{Quest,Npc,Object,Item,Zone}DB.lua`, `Data/VanillaQuestIDs.lua` | Questie Classic tables and corrections, via the maintainer's data build | Confirm the license and obligations for the *specific Questie source version used*, including upstream database contributions. [Questie's license question](https://github.com/Questie/Questie/issues/4447) and [licensing proposal](https://github.com/Questie/Questie/pull/4660) have not resolved this for this bundle. |
| WoW Forever overlay records with `src: "rxp"` (merged into the packed `Data/` records), and guides built using the overlay | [RestedXP/RXPGuides](https://github.com/RestedXP/RXPGuides) Forever guides, via the maintainer's data build | Its [license](https://github.com/RestedXP/RXPGuides/blob/main/LICENSE) is CC BY-NC-SA 4.0. Confirm whether the imported material may be redistributed in this form and what attribution/share-alike terms apply; otherwise replace it with independently collected in-game data and regenerate affected outputs. |
| `Data/ForeverQuestIDs.lua`, and other `src: "db2"` records | WoW Forever client tables exported via wago.tools | Check the applicable game-data/export terms before redistribution; attribution to an export service alone does not grant rights. |

`Guides/` is produced by the maintainer's route planner from the bundled database; they are not automatically free of upstream obligations just because the route is computed. Before publishing a release, the project owner should record the source revision and permission/terms for each input, meet those terms, or remove and regenerate from cleared inputs. Do not treat the MIT license for original code as a license for this data. This is a provenance checklist, **not** a claim that any rights have been granted or denied.

Fields of a decoded record:

| file | global | contents |
|---|---|---|
| `QuestDB.lua`  | `ns.QuestDB[questID]`  | `n` name, `lvl`, `req` required level, `maxlvl`, `races`/`classes` bitmasks, `zone` (areaID, negative = QuestSort category), `text` objectives text, `snpc`/`sobj`/`sitem` starters, `enpc`/`eobj` enders, `kill`/`obj`/`item`/`credit`/`spell` objectives (`{{id, text?}, ...}`), `trig` exploration trigger `{text, {[areaID] = {{x,y}}}}`, `srcitem`, `reqitems`, `pre` (one of), `pregroup` (all of), `next`, `excl`, `parent`, `children`, `group`, `skill`, `spellreq`, `flags`, `special` (1 = repeatable), `breadcrumb`, `breadcrumbs`, `hidden` |
| `NpcDB.lua`    | `ns.NpcDB[npcID]`      | `n` name, `min`/`max` level, `rank`, `zone`, `sp` spawns `{[areaID] = {{x,y}, ..., n = total}}` (max 12 points per zone, evenly sampled), `f` friendly to "A"/"H"/"AH", `sub` title, `starts`, `ends` |
| `ObjectDB.lua` | `ns.ObjectDB[objectID]`| `n`, `zone`, `sp`, `starts`, `ends` |
| `ItemDB.lua`   | `ns.ItemDB[itemID]`    | `n`, `npc` drop sources, `obj` object sources, `startq` quest started by the item, `vendors`, `quests` |
| `ZoneDB.lua`   | `ns.ZoneDB`            | `areaToMap[areaID] = uiMapID` (Classic Era ids, identical on WoW Forever), `names[areaID]`, `parent[areaID]` (sub-zone to zone), `mapNames[uiMapID]` / `mapParent[uiMapID]` (Forever maps) |

Only NPCs, objects and items that matter for quests are included. Coordinates are 0-100 on the
zone's uiMapID. Race bits: Human 1, Orc 2, Dwarf 4, Night Elf 8, Undead 16, Tauren 32, Gnome 64,
Troll 128 (77 = all Alliance, 178 = all Horde), and WoW Forever's Skyborne, one bit per faction:
Alliance Skyborne 65536, Horde Skyborne 131072. A Skyborne also takes any quest open to every
Classic race of its faction (77 or 178). Class bits: Warrior 1, Paladin 2, Hunter 4, Rogue 8,
Priest 16, Shaman 64, Mage 128, Warlock 256, Druid 1024.

## The WoW Forever overlay

The maintainer's data build merges WoW Forever's own facts over the tables above before packing:
vanilla records only gain what they lack, quest ids only the client knows become new records
flagged `forever = true`, and vanilla quests the client does not have are flagged `removed = true`.
The overlay itself is not shipped. Its records are

* `quests[id] = { n, lvl, req, zone, xp, snpc, enpc, obj = { { kind, id, name, text, spm, spw, near } }, start = { spm/spw }, seen, src }`
* `npcs[id] = { n, lvl, spm, spw, starts, ends }`, `objects[id] = { n, spm, spw }`, `maps[uiMapID] = { name, parent }`
* `spm = { [uiMapID] = { {x, y}, ... } }` map coordinates (0-100); `spw = { [uiMapID] = { {instanceID, worldX, worldY}, ... } }`
  world coordinates converted in-game with `C_Map.GetMapPosFromWorldPos`.
* `src` lists where a record came from: `rec` = recorded in-game by this addon, `harvest`, `scan` =
  `/fg scan new` (titles, levels, objective texts from the client), `db2` = the client's own tables
  (wago.tools export), `fix` = a hand correction, `rxp` = material from the free WoW Forever guides
  shipped with **RestedXP Guides** (https://github.com/RestedXP/RXPGuides, CC BY-NC-SA 4.0): positions,
  and possibly quest titles, objective text, NPC/mob names and prerequisites. Their route ordering and
  step prose are not copied; ForeverGuide's routes are computed by the maintainer's route planner. See
  the unresolved redistribution status above.
