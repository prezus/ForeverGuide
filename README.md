# ForeverGuide

Free, data-driven leveling guide engine for **WoW Forever** (beta 1.60.x, Retail 12.x engine, TOC `16001`).
It reads game state and shows you the next step. It does not automate casting, movement, or combat.
Auto-accept and auto-turn-in are enabled by default; other player-facing actions and existing exceptions
are described in the [client and player-control policy](COMPATIBILITY_POLICY.md).

```
ForeverGuide DB (JSON)  ->  tools/compile_guides.py  ->  Guides/*.lua  ->  addon engine  ->  WoW Forever
```

## License

The [MIT license](LICENSE) covers only original ForeverGuide code and assets owned by its copyright holders (see [Credits](#credits)). It does **not** grant rights to redistribute the bundled Questie-derived database or other third-party-sourced material. **Redistributors:** bundled data has unresolved third-party licensing questions; see [Data/README.md](Data/README.md#redistribution-status-unresolved) before publishing a package.

## Credits

ForeverGuide was created by RevoltLive85 and is now
maintained by [prezus](https://github.com/prezus/ForeverGuide). The original development log is kept in
[docs/history/PHASE1_NOTES.md](docs/history/PHASE1_NOTES.md). Data sources are credited in
[Data/README.md](Data/README.md).

## Install

1. Download `ForeverGuide-<version>.zip` from the [releases page](https://github.com/prezus/ForeverGuide/releases)
   (or clone this repo) and unzip it so that you get `World of Warcraft\_classic_beta_\Interface\AddOns\ForeverGuide\ForeverGuide.toc`.
2. Log in, enable **ForeverGuide** on the AddOns screen. If the beta has moved to a newer build than the addon's
   TOC number, tick **Load out of date AddOns** on that screen - the addon reads game state defensively and keeps
   working across builds.
3. First login: the Quest Guide window picks the leveling route for your race and level on its own and the gold
   diamond in the world points at the first step. **Guides** (button or `/fg guides`) lists every route of your
   faction, the chapters of the one you follow, and standalone zone guides - the race route is only a
   recommendation. **Guide** opens the step details with Back / Skip / Auto / Resync.
4. Alt-click the minimap button (or `/fg hideall`) hides everything while the guide keeps running.

**Beta caveat:** this client build never reads SavedVariables back, so the addon mirrors your progress and settings
into CVars every 30 s and restores them at login ("beta workaround" line in chat). Step edits and reports live in the
SavedVariables file and can be lost - `tools/apply_edits.py` folds them into the guide source.

Developers: the addon folder doubles as the repo (`tools/`, `guides-src/`, `data-src/` are not loaded by the game);
`python tools/package.py` builds the release zip. For a private Mac-to-Windows test build, run
`python3 tools/package.py --test`: it validates a runtime-only ZIP in ignored `dist/`, names it
after the commit (`ForeverGuide-<commit>.zip`), and prints its SHA-256. Send that same ZIP to the Windows tester; it extracts
into `_classic_beta_\Interface\AddOns\ForeverGuide\`. No Python is needed on Windows to install it.
The ZIP holds only files from the last commit (any branch), never the folder on disk: this folder is
also the live addon, so it collects player reports, SavedVariables copies and local edits that must
not ship. Commit what you want in a build first; the ZIP itself does not go into Git.
For local checks, install Lua 5.1 or LuaJIT,
[Luacheck](https://github.com/lunarmodules/luacheck), and optionally Lua Language Server, then run:

```sh
luajit tools/test/run_tests.lua            # or lua5.1 tools/test/run_tests.lua
python3 tools/compile_guides.py --check  # Windows: py -3 tools/compile_guides.py --check
luacheck Core.lua Database.lua Events.lua Persist.lua Player.lua Navigation.lua Guide.lua DB.lua
lua-language-server --check . --checklevel=Warning
```

Luacheck covers eight clean engine files, not the whole addon; its config suppresses WoW-provided
global warnings, not local-variable or control-flow warnings. Headless mocks cannot catch every
client API, secret-value, or combat-lockdown issue: verify behavior in-game too.

### LuaLS (local editor diagnostics, not a type-check gate)

Open this folder as the workspace in an editor with Lua Language Server. `.luarc.json` uses Lua 5.1 and
checks the handwritten addon Lua files at the root and in `UI/` (40 files); `Guides/`, `Data/`,
`guides-src/`, `data-src/`, and `tools/` are excluded from workspace diagnostics. These exclusions
are not a guarantee that an individually opened file will have no diagnostics.

LuaCATS hints describe the `Plain*` helpers' nullable results, the string path to `ns.Call`, and
selected fields of a registered guide step. `Player.lua` also casts the shared namespace to its
small core-helper contract so LuaLS can complete and check those calls across files. LuaLS can flag
incompatible annotated step fields (e.g. a string quest ID), or misuse of typed helpers where their types are known; generated
steps are **not** checked by LuaLS. There is no WoW Forever API definition here: undefined-game-global
warnings remain, and static types cannot validate API availability, secret values in combat, or
whether a game result is safe to use without `Plain*`/`Safe`. Treat warnings as leads to inspect,
not proof of a passing type check. With the playable UI stack, the CLI reports 177 warnings in 29 files
(LuaLS 3.19.1: 156 undefined globals and 21 possible nil accesses) and exits nonzero.

### WoW client smoke test and error capture

In the beta client, enter `/console scriptErrors 1`, then `/reload`. Open `/fg` and `/fg guides`,
select a guide, try Guide/Auto mode and a waypoint, and repeat while in combat (game API results
may become secret). Capture the **full first Lua error** from the client's error popup, including
stack trace, and note the client build (`/fg`), what you clicked, and whether you were in combat.
ForeverGuide also catches some callback errors with `pcall` and prints `ForeverGuide: error in
<key>: <message>` in chat **once per key per reload**; capture those lines too. The popup will
not show errors caught by the addon; while Contribute data is on, ForeverGuide keeps those errors
with the guide step and map, and `/fg share` includes them in the string for the feedback form.
`/reload` resets the once-per-key reporting. Redact character, realm, account, and local path
details before sharing anything you copy by hand.

In game:

| command | what |
|---|---|
| `/fg` | status: level, zone, map id + coords, quest log with objective progress, current guide step, target info |
| `/fg help` | every command |
| `/fg guides` / `/fg guide <name>` | list / start a guide |
| `/fg skip` `/fg back` `/fg step <n>` `/fg reset` | move through the guide |
| `/fg later` `/fg now <n>` `/fg skipped` `/fg order reset` | put the current step off, do step n now, bring back skipped steps, undo your moves (or right-click a step) |
| `/fg pos` | your uiMapID + coordinates, printed as a ready-to-paste TRAVEL step |
| `/fg target` | npc id, level, reaction of your target |
| `/fg way 42.3 71.8` | point the arrow at a coordinate on your current map |
| `/fg share on` / `/fg share` | opt in to contributing quest data (off by default) / copy it, with your reports, as one string for the feedback form (**Readable** shows what it holds in words, **JSON** as data) |
| `/fg mode auto` | navigate your quest log directly (nearest objective / turn-in), no guide needed; `/fg mode guide` to follow the guide |
| `/fg quest 783` / `/fg quest kobold` | everything the database knows: giver, objectives with coordinates, turn-in, prerequisites |
| `/fg avail` | quests you could pick up in the current zone, with their givers and distances |
| `/fg auto accept on\|off\|guide`, `/fg auto turnin on\|off` | auto-accept / auto-turn-in at NPCs (on by default; hold SHIFT to do it by hand; multi-choice rewards are left to you) |
| `/fg minimap on\|off` | minimap button: left click window, right click guide picker, shift-click arrow, **alt-click hide everything**, drag to move |
| `/fg waypoint on\|off`, `/fg route on\|off` | the in-world gold waypoint and the dotted path towards it (`/fg wpdbg` prints what places it; `/fg waypoint engine on` rides the client's own pin instead of our projection - off by default, the Forever client cannot project it) |
| `/fg skull on\|off`, `/fg skull others\|plates on\|off` | skull over the nearest untagged mob of the current kill/collect step, small skulls over the other quest mobs around, none on mobs tagged by others; the skull button in the window (or its key binding) targets the nearest mob of the step; enemy nameplates are switched on during kill steps (the skulls ride on them) |
| `/fg path` / `/fg path dwarf` / `/fg path race` | leveling routes are a **choice**: list every route of your faction, follow another race's one, or go back to your race's own (the recommended default) |
| `/fg qg scale\|opacity\|width\|rows\|wpsize <n>` | Quest Guide look; `/fg qg completed\|distances\|subtitles on\|off` |
| `/fg hideall [on\|off]` | hide the window *and* the arrow at once (same as alt-clicking the minimap button); the guide keeps running in the background |
| `/fg scan` | ask the server about every quest id 1-100000; log out, then `python tools/scan_diff.py` lists Forever's new quests vs Questie |
| `/fg wrong <text>` / `/fg reports` | report the current step as wrong (saved with your position + target); `python tools/collect_reports.py` turns the reports into a review list |
| `/fg options` | options panel (also Esc -> Options -> AddOns -> ForeverGuide); key bindings under Key Bindings -> AddOns |
| `/fg persist [save]` | state of the SavedVariables workaround (see *Beta caveats*) |
| `/fg resync` | levelled elsewhere? skips the quests that would give 20% xp or less and continues from the first open step |
| `/fg edit here` / `npc` / `note <text>` / `radius <yd>` / `clear`, `/fg edits` | fix the current step in place (position = where you stand, npc = your target); saved per guide, `python tools/apply_edits.py` folds the edits into the guide source |

The window and the floating arrow are draggable while unlocked (`/fg unlock` / `/fg lock`); `/fg arrow off` hides the arrow, `/fg bliz off` disables the Blizzard map-pin arrow. The **Guides** button opens a picker (auto mode, a route or a chapter); **Auto**/**Guide** switches modes. Below them, **Unknown Quests** opens a panel under the window with the quests in your log that no guide covers (left click opens one in the quest log, right click reports it), and **Dungeon Quests** opens a panel listing your dungeons - pick one to see its quests and where each stands, with a Waypoint to the entrance, without moving the guide off its step.

Want to help? See [CONTRIBUTING.md](CONTRIBUTING.md) for bug reports, guide edits, and testing.

## Layout

```
ForeverGuide/
  ForeverGuide.toc
  Core.lua          namespace, secret-value-safe helpers, module registry, lifecycle
  Database.lua      SavedVariables (ForeverGuideDB account, ForeverGuideCharDB per char)
  Events.lua        one event frame + internal FG_* message bus + debounce
  Persist.lua       beta workaround: mirrors guide/progress/settings into CVars (SavedVariables are not read back)
  Player.lua        level, faction, class, race, map, zone, coords, facing, target/npc info
  Quest.lua         quest log snapshot, states, objective diffing, titles, Blizzard waypoints
  Navigation.lua    map coords -> distance/direction, arrival detection, Blizzard user waypoint
  Guide.lua         guide registry + the step interpreter (advance / recovery / skip)
  DB.lua            access to the bundled quest database (where does a quest start / end / its objectives)
  Tracker.lua       auto mode: navigates the quest log using the database
  Recorder.lua      Contribute data: quest givers / enders, NPC and objective spots, target votes (opt-in, no names or times)
  Share.lua         /fg share: the allowlisted export string for the feedback form (docs/SHARE-FORMAT.md)
  Scanner.lua       quest id scanner (/fg scan) -> which quest ids exist on Forever's server
  UI.lua            coordinator of the interface + the guide picker
  UI/Theme.lua      textures, colours, fonts, backdrops, buttons, pulse ticker (Textures/*.tga from tools/make_textures.py)
  UI/QuestGuideFrame.lua   the Quest Guide window (parchment + gold), header, list, Guide / Guides buttons
  UI/QuestGuideHeader.lua, QuestList.lua, QuestRow.lua   the rows: number ring, kind icon, title, objective line, distance
  UI/QuestWaypoint.lua     the in-world gold waypoint: rides on the engine's super-tracked pin when the client can
                           project it, otherwise placed by a chase-camera perspective model; the camera's direction is
                           recovered from where the engine parks its (invalid) pin (+ QuestRoute.lua dotted path)
  UI/MobMarker.lua         skulls over quest mobs, anchored to enemy nameplates (raid icons are blocked for addons here)
  UI/QuestGuideConfig.lua  settings (/fg qg ..., options panel)
  Arrow.lua         compact gold chevron - fallback when the world pin cannot show (Textures/chevron.tga)
  AutoQuest.lua     auto-accept / auto-turn-in through the normal quest windows
  Minimap.lua       minimap button
  Options.lua       options panel (Settings canvas category)
  Editor.lua        in-game step corrections (/fg edit) applied over the guide data
  Keybinds.lua      key binding names + functions for Bindings.xml
  Commands.lua      /fg
  Init.lua          boots the lifecycle (last in the TOC)
  Data/             bundled quest database built from Questie's Classic data (see Data/README.md)
                    + ForeverDB.lua: WoW Forever additions (recorded in-game / client tables), merged at load
  data-src/         forever.json (collected Forever data), corrections.json (hand fixes, win over everything),
                    db2/ (the wago.tools CSV exports of the client's quest tables)
  Guides/           compiled guides (generated - do not edit)
  guides-src/       guide sources in JSON (SCHEMA.md documents the format), published by the route planner
  tools/
    compile_guides.py   JSON -> Lua  (python tools/compile_guides.py)
    import_rxp.py       factual quest positions from RestedXP's free Forever guides -> overlay
    questie_lookup.py   quest/NPC/object/item facts + step JSON from the Questie DB (--questie or QUESTIE=<Questie checkout>)
    scan_diff.py        /fg scan results vs Questie: new / removed / renamed quests
    decode_share.py     decode + validate a /fg share string with only Python's standard library (docs/SHARE-FORMAT.md)
    share_schema.lua    writes docs/share-format.schema.json (the share allowlist as JSON Schema) from Share.lua
    merge_recorded.py   SavedVariables (contributed facts/harvest/scan, incl. .bak, every account) -> data-src/forever.json -> Data/ForeverDB.lua
    collect_reports.py  "/fg wrong" reports -> local-only data-src/reports.json + review list
    apply_edits.py      "/fg edit" corrections -> guides-src/*.json (then compile_guides.py)
    package.py          dist/ForeverGuide-<version>.zip (--dev includes tools and sources)
    test/               headless engine test: lua5.1 tools/test/run_tests.lua
    screenshots/        addon windows as PNGs without the game: dump_ui.lua opens them headless and writes
                        their frame trees, render.py paints them (luajit tools/screenshots/dump_ui.lua build/screenshots
                        && uv run tools/screenshots/render.py build/screenshots)
```

## WoW Forever data (the ~1000 new quests)

Vanilla quests come from Questie. Everything Forever adds is collected into `data-src/forever.json`
and shipped as `Data/ForeverDB.lua`, which `DB.lua` merges over the vanilla tables at load (vanilla
records only gain what they lack; unknown ids become new records flagged `forever`). Two sources:

* **Players contributing data** (opt in under Options → Data collection or `/fg share on`): the
  creatures that give and end each quest, where NPCs stand and objectives progress (rounded to half
  a map unit), which mobs were targeted when an objective moved, the player level a quest was
  offered at, and zone maps. Only creatures are kept: a quest shared by another player is flagged
  `shared`, never with who shared it, and nothing records the time. `/fg share` turns it into one
  string for the feedback form ([format](docs/SHARE-FORMAT.md)). On your own machine,
  `python tools/merge_recorded.py` reads the same facts from every
  `WTF\Account\*\SavedVariables\ForeverGuide.lua` and `.bak`.
* **The client's own tables**: `QuestV2`, `QuestV2CliTask`, `QuestObjective`, `QuestPOIBlob` and
  `QuestPOIPoint`, exported as CSV from `https://wago.tools/db2/<Table>?build=1.60.1.69913` into
  `data-src/db2/`, are imported by the maintainer's data build (see [Routes](#routes)). Objective
  positions are world coordinates (`spw`) and are converted to map coordinates in-game.

Hand fixes go into `data-src/corrections.json` (applied last). Player reports (`/fg wrong`) are
collected with `tools/collect_reports.py`. `data-src/reports.json` and SavedVariables snapshots
are private local files, ignored by Git. Before posting a report or committing a derived
correction, scrub account, character, and realm names (including free text and file paths),
and omit timestamps or player locations unless needed to reproduce the bug. Share the
smallest correction, not a raw SavedVariables file. Gitignore and deleting a tracked file
do not remove copies from past commits.

What the client's tables actually contain on build 69913: `QuestV2` is only the **list of quest ids**
(6600 - no titles, levels or zones; those are server-side), and the POI tables hold ~50 static
points. The id list is still gold: it is shipped as `Data/ForeverQuestIDs.lua` and tells the addon
which vanilla quests are gone from Forever (711 - later-phase content, battlegrounds, mount
exchanges; they are excluded from routes and `/fg avail`) and which ids are Forever's own (3054).
Opt in to Scanner under Options → Data collection (or `/fg scan on`) first.
**`/fg scan new`** asks the server for exactly those ids and records title, level and objective texts
as they arrive (the server throttles; run it in the background over a few sessions, `/fg scan status`
shows progress), then `python tools/merge_recorded.py` folds them in. Positions of
the new quests come from contributed data while you play them.

## Routes

The routes - one continuous 1-60 route per starting race, as a chain of zone chapters
(`guides-src/GEN_<FACTION>_<RACE>_<nn>_<ZONE>.json`), plus the zone and dungeon guides - and the quest
database tables in `data-src/tables/` are generated by the maintainer's route planner and data build,
which live outside this repository. It publishes them here as pull requests; this repository compiles,
packs and checks what it receives.

Do not edit or regenerate `guides-src/`, `Guides/`, `data-src/tables/` or `Data/` by hand: the next
publish replaces them. To report a wrong or slow step, open an issue or use `/fg wrong` in game;
`/fg edit` fixes a step for you right away.

## Guide format

Steps only need a type and a quest id when the bundled database knows the quest:
`{ "type": "ACCEPT", "quest": 783 }`, `{ "type": "KILL", "quest": 7 }`, `{ "type": "TURNIN", "quest": 7 }`.
Names and coordinates come from the database at runtime (explicit `x`/`y` override them).
[guides-src/SCHEMA.md](guides-src/SCHEMA.md) documents every field; `python tools/compile_guides.py`
validates the sources and writes `Guides/<ID>.lua` + `Guides/Guides.xml`.

Coordinates use `map` (uiMapID) plus a `zone` name as fallback: if Forever does not know the Classic
Era uiMapID, the engine matches the zone by name against the player's current map. Run `/fg pos` in
each zone to learn Forever's real IDs; while contributing data, the addon also keeps every map it sees.

## Beta caveats (1.60.1)

* **SavedVariables are written at logout but never read back at login** (confirmed on build 69913 -
  every session started from scratch). `Persist.lua` works around it: the active guide, step, progress,
  mode, settings and step edits are mirrored into addon-registered CVars (which the client does persist)
  and restored when the SavedVariables come back empty. `/fg persist` shows the state. Big data
  (contributed facts, scan/harvest data, `/fg wrong` reports) still only lives in the SavedVariables *files*, which are
  overwritten at every reload: `/fg share` copies facts and reports out before you log out, and on your
  own machine `python tools/merge_recorded.py` and `python tools/collect_reports.py` harvest the files
  (set `WOW_WTF_ACCOUNT` if your `WTF\Account` folder is not in the default Windows install).
* Everything from the game can be a secret value in combat. All reads go through `ns.Plain*` helpers.
* The classic quest IDs / NPC IDs in the sample guide come from Questie's Classic Era data and must be
  verified on Forever (`/fg quest <id>`, contributed data).
