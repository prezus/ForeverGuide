# ForeverGuide agent guidance

ForeverGuide runs on WoW Forever's beta client. The `.toc` file determines Lua load order;
`Init.lua` boots last. Use Lua 5.1 syntax. Game API values may be secret in combat: inspect
`Core.lua`'s `ns.Plain*`/`ns.Safe` helpers before comparing, converting, or displaying them.
Verify client-dependent behavior in-game; the headless mock is not the client.

PRs, commits and docs for the addon live here (prezus/ForeverGuide). Issues are turned off: they are
filed on [prezus/forever-codex](https://github.com/prezus/forever-codex/issues), which also publishes
`Guides/` and `Data/`. The original author's credit lives in `LICENSE`, the `.toc`, and the README credits.

## Change the source of truth

- Routes and quest data are published: `Guides/` and `Data/` arrive as finished Lua by pull
  request from forever-codex's route planner and data build
  ([README](README.md#how-this-repository-is-managed)). Route or data changes belong there; a wrong
  step becomes a forever-codex issue. CI refuses anything in them but data (`tools/test/check_data_only.lua`) and a fork's PR
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

When Forever ships a new build, move the pin together: the commit in `check.yml`, `VERSION` in the
checker, and the build and commit named in `types/forever.lua`.

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

## Validate locally

Run the checks in [CONTRIBUTING.md](CONTRIBUTING.md#checks), the list CI runs, plus luacheck on the
files you changed. `lua -v` must report 5.1 (or use `luajit`); on Windows `py -3` replaces `python3`.
Luacheck covers the engine files, not the whole addon, and LuaLS is editor help, not a gate: neither
replaces the Lua tests or in-game checks. Use annotations for known contracts rather than labeling
unknown values `any` to silence a diagnostic.
