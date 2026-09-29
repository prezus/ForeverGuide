# ForeverGuide agent guidance

ForeverGuide runs on WoW Forever's beta client. The `.toc` file determines Lua load order;
`Init.lua` boots last. Use Lua 5.1 syntax. Game API values may be secret in combat: inspect
`Core.lua`'s `ns.Plain*`/`ns.Safe` helpers before comparing, converting, or displaying them.
Verify client-dependent behavior in-game; the headless mock is not the client.

This repository (prezus/ForeverGuide) is the project's only home: issues, PRs, commits, and docs
link here alone. The original author's credit lives in `LICENSE`, the `.toc`, and the README credits.

## Change the source of truth

- Routes and quest data are published: `Guides/` and `Data/` arrive as finished Lua by pull
  request from the maintainer's route planner and data build, which live outside this repository
  ([README](README.md#routes)). Route or data changes belong there; here, a wrong step becomes an
  issue. CI refuses anything in them but data (`tools/test/check_data_only.lua`) and a fork's PR
  that changes them. [Data/README.md](Data/README.md) holds the sources and their redistribution
  constraints.
- Engine test guides: the engine test plays the frozen, compiled guides in
  `tools/test/fixtures/Guides/` ([schema](docs/GUIDE-SCHEMA.md)). Change them only to test new
  engine behaviour, and keep them data only.
- Engine: follow the existing `ns` module convention and `.toc` load order. Add a new
  file to the `.toc` only if the feature actually needs it.

## Look up Forever's API

Forever is its own flavor ("Camelot"): Classic and Retail docs and memory are wrong about its API.
Before using or debugging any game function, event, or template, look it up in the pinned
[Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) `forever` branch, at the commit
CI fetches in `.github/workflows/check.yml`:

```text
git clone --branch forever https://github.com/Gethe/wow-ui-source.git <dir>
git -C <dir> checkout <commit from check.yml>
```

- Namespaced calls (`C_*`): `Interface/AddOns/Blizzard_APIDocumentationGenerated/`.
- Globals, return shapes, and how a feature is really read: grep Blizzard's own code, preferring
  `*/Camelot/` files (e.g. skills come from `C_SkillInfo`, one table per line, in
  `Blizzard_UIPanels_Game/Camelot/SkillsFrame.lua`).
- After adding calls: `python3 tools/check_forever_api.py <dir>`.

When Forever ships a new build, move the pin (the commit in `check.yml`, `VERSION` in the checker) together.

## Test the contract, not your code

1. For a bug, reproduce it with a check that fails **before** changing production code.
   For a feature, state an observable expected result independently of the implementation.
2. Use the existing `tools/test/run_tests.lua` mock for behavior it can actually simulate.
   Put the checks in their own `section(...)`, use `need()` for a precondition the section
   cannot do without, and register synthetic guides or `ns.QuestDB[id]` records rather than
   asserting what a shipped guide or the database happens to contain today.
   Assert the meaningful outcome and at least one failure/boundary case when relevant.
   A check that only mirrors a new constant or mock implementation does not prove behavior.
3. Keep existing assertions intact unless the intended behavior changed; explain that
   change and its evidence in the PR. Never relax an expectation merely to get green.
4. Run the relevant checks below. Report their results and what they cannot cover.
   Test `/reload`, login persistence, and combat in-game where relevant.

Prefer one focused regression check over tests for trivial edits. A passing mock does
not establish that an API exists on this client or that an action is allowed in combat.

## Validate locally (Windows, Linux, macOS)

Install [Lua 5.1](https://www.lua.org/download.html) or [LuaJIT](https://luajit.org/install.html),
[Python 3](https://www.python.org/downloads/), [Luacheck](https://github.com/lunarmodules/luacheck),
and optionally [LuaLS](https://luals.github.io/#install). Run from the addon root; use the
executable names provided by your installation (`lua -v` must report 5.1; plain `lua` may
be newer). On Windows, `py -3` often replaces `python3`. No Unix shell script is required.

Use `luajit` in place of `lua5.1` if necessary, and `py -3` in place of
`python3` on Windows:

```text
lua5.1 tools/test/run_tests.lua
lua5.1 tools/test/test_check_data_only.lua
lua5.1 tools/test/check_data_only.lua
luacheck --std lua51 --no-global --no-unused-args --no-max-line-length Core.lua Database.lua Events.lua Persist.lua Player.lua Navigation.lua Guide.lua DB.lua
lua-language-server --check . --checklevel=Warning
```

The Luacheck command covers **eight** engine files and suppresses game-provided global
warnings; it is not whole-addon lint. LuaLS is optional/editor-assisted: inspect its
reported diagnostics on the files you changed. Until WoW API stubs and a scoped LuaLS
config exist, its workspace report can be noisy and is not a passing type-check gate.
Use annotations for known contracts rather than labeling unknown values `any` just to
silence a diagnostic. Neither tool replaces the Lua tests or in-game checks.
