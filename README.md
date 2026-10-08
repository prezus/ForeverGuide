# ForeverGuide

A free leveling guide for **WoW Forever** (beta 1.60.x, TOC `16001`). It reads the game and shows
you the next step: a quest window, an arrow, a waypoint and skulls over the mobs you need. It never
casts, moves or fights for you. Auto-accept and auto-turn-in are on by default. Everything it does
for you is listed in the [client and player-control policy](COMPATIBILITY_POLICY.md).

## Install

1. Download `ForeverGuide-<version>.zip` from the [releases page](https://github.com/prezus/ForeverGuide/releases)
   and unzip it so that you get `_classic_beta_\Interface\AddOns\ForeverGuide\ForeverGuide.toc`.
2. Enable **ForeverGuide** on the AddOns screen. If the beta has a newer build than the addon, tick
   **Load out of date AddOns**.
3. Log in. The guide window picks the route for your race and level. **Guides** switches to another
   route of your faction or another chapter; `/fg guides` lists every guide, zone guides included.
   **Dungeon Quests** shows your dungeons and their quests. **Details** shows the current step, with
   Back, Skip, Auto and Resync.

The beta client does not read SavedVariables back at login. ForeverGuide keeps your guide, progress,
settings and step edits in CVars instead and restores them. Reports,
collected data and runs live only in the SavedVariables file, so send them (below) before you log out.

## Commands

`/fg help` lists them all in game. Options: `/fg options`, or Esc → Options → AddOns → ForeverGuide.

| Command | What it does |
|---|---|
| `/fg` | Status: level, zone, coordinates, quest log, current step, target |
| `/fg show` `hide` `toggle`, `/fg hideall` | The guide window; hideall hides the window and the arrow (alt-click the minimap button) |
| `/fg guides`, `/fg guide <name>`, `/fg path [name\|race]` | List or start a guide; follow another race's route |
| `/fg dungeons`, `/fg resume` | Dungeon guides; back to your chapter |
| `/fg skip` `back` `next` `step <n>` `reset`, `/fg resync` | Move through the guide; resync skips quests you out-levelled |
| `/fg later` `now <n>` `skipped` `order reset` | Put a step off, do one now, bring back skipped steps (or right-click a step) |
| `/fg mode auto\|guide`, `/fg track` | Auto mode follows your quest log without a guide |
| `/fg quests`, `/fg quest <id\|name>`, `/fg avail` | Your quest log; what the database knows about a quest; quests to pick up here |
| `/fg nav`, `/fg way <x> <y>`, `/fg pos`, `/fg target` | Distance to the step; point the arrow at a spot; your position; your target |
| `/fg fp`, `/fg remind`, `/fg xp`, `/fg ding` | Untaken flight points; flight and trainer nudges, and the XP food and sleeping bag icons (`/fg remind food|bag on|off`, `/fg remind buffs reset`); levelling pace; level-up announcement |
| `/fg auto accept\|turnin\|share\|shared\|announce` | Auto-accept, auto-turn-in, and quest sharing with your group (hold SHIFT to do it by hand) |
| `/fg arrow`, `/fg waypoint`, `/fg route`, `/fg skull`, `/fg bliz` | The arrow, the in-world waypoint and its path, skulls over quest mobs, Blizzard's map pin |
| `/fg lock` `unlock` `scale <n>` `resetpos`, `/fg qg <setting> <value>`, `/fg minimap` | Window look and position |
| `/fg dungeon on\|off` | Put the guide away inside instances |
| `/fg edit`, `/fg edits` | Fix the current step where you stand (position, npc, note, radius) |
| `/fg wrong [text]` (or `report`), `/fg reports` | Report a wrong step; list your reports |
| `/fg share`, `/fg run`, `/fg scan`, `/fg live` | Data collection (below) |
| `/fg options` | Options panel |

For debugging: `/fg debug`, `perf`, `eval`, `tracker`, `npdbg`, `wpdbg`, `harvest`.

## Data collection and privacy

All three are off until you turn them on under Options → Data collection. None of them records
other players, your name, realm or account, or the time of day.

- **Contribute data** (`/fg share on`) collects who gives and takes each quest and where objectives
  progress. `/fg share` copies it, with your reports, as one string.
- **Scanner** (`/fg scan on`, then `/fg scan new`) asks the server about quest ids the addon does not
  know yet.
- **Record runs** adds Start, Pause, Stop and Send to the guide window: a timed log of your play for
  tuning the routes. Send copies one segment.

Paste what you copy into the feedback form, "Send feedback" at
[codex.ironpipe.dev](https://codex.ironpipe.dev/). In the share window, **Readable** shows exactly
what the string holds. [docs/SHARE-FORMAT.md](docs/SHARE-FORMAT.md) documents every field and how to decode it yourself.

## Reporting a problem

Stand where the step should be and use the window's **!** button (or `/fg wrong <text>`), then
`/fg share` and paste the string into the feedback form. For a Lua error, turn on
`/console scriptErrors 1`, `/reload`, and paste the first error with its stack trace. ForeverGuide
prints the errors it catches itself once per reload as `ForeverGuide: error in …`.

## How this repository is managed

- **Guides and data** (`Guides/`, `Data/`) are planned and built in
  [forever-codex](https://github.com/prezus/forever-codex) and arrive here as pull requests of
  finished Lua. Don't edit them by hand: CI checks that they are data only, and refuses a fork's PR
  that changes them. [Data/README.md](Data/README.md) lists the sources.
- **The engine** (everything else) changes by pull request. CI runs the checks in
  [CONTRIBUTING.md](CONTRIBUTING.md).
- **Releases** are cut by the maintainer ([CONTRIBUTING.md](CONTRIBUTING.md#releases)).
- **Problems** go through the feedback form, or as issues on
  [forever-codex](https://github.com/prezus/forever-codex/issues). This repository has issues turned off.

Developers start with [CONTRIBUTING.md](CONTRIBUTING.md). Coding agents start with [AGENTS.md](AGENTS.md).

## License and credits

The [MIT license](LICENSE) covers original ForeverGuide code and assets only. It does not cover the
bundled Questie-derived database: see [Data/README.md](Data/README.md#redistribution-status-unresolved)
before redistributing a package.

ForeverGuide was created by RevoltLive85 and is maintained by [prezus](https://github.com/prezus).
The original development log is [docs/history/PHASE1_NOTES.md](docs/history/PHASE1_NOTES.md).
