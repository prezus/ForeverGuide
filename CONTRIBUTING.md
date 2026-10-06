# Contributing to ForeverGuide

ForeverGuide targets the **WoW Forever beta**, not stock Classic or Retail. Players report problems
through the feedback form ([README](README.md#reporting-a-problem)). Issues are turned off here and
go to [forever-codex](https://github.com/prezus/forever-codex/issues).

## Propose a change

1. Branch from `main`, one fix per pull request. Read the
   [client and player-control policy](COMPATIBILITY_POLICY.md) before changing runtime Lua, UI or
   loaded files. In the PR, name each new game API call, what triggers it, and whether it acts for
   the player. Look API calls up in Forever's UI source as [AGENTS.md](AGENTS.md#look-up-forevers-api) describes.
2. Leave `Guides/` and `Data/` alone: [forever-codex](https://github.com/prezus/forever-codex)
   publishes them, the next publish replaces hand edits, and CI refuses a fork's PR that changes them.
3. Run the checks below, then test in the beta: the affected step or window, a `/reload`, and combat
   if the change touches the UI. Put the client build, the steps and the results in the PR.

Don't commit SavedVariables (`WTF/`), player logs, or anything with character, realm or account names.
Read [Data/README.md](Data/README.md) before adding third-party material.

## Checks

CI (`.github/workflows/check.yml`) runs these on every pull request. Run them from the addon root
with Lua 5.1 (or LuaJIT) and Python 3:

```sh
lua5.1 tools/test/run_tests.lua             # headless engine tests against the mock client
lua5.1 tools/test/check_data_only.lua       # Guides/ and Data/ hold data and nothing else
python3 tools/test/test_decode_share.py
python3 tools/check_forever_api.py <ui-source>   # C_ API paths exist on Forever (AGENTS.md)
python3 tools/test/test_package.py
python3 tools/package.py && python3 tools/check_package.py
```

Locally, also lint the engine files (`.luacheckrc` holds the settings):
`luacheck Core.lua Database.lua Events.lua Player.lua Navigation.lua Guide.lua DB.lua`,
plus any file you changed. LuaLS (`.luarc.json`) is useful in an editor but isn't a gate. The mock is not the client: an API that
passes here can still be missing, protected or secret in combat on Forever.

`tools/screenshots/` renders the addon's windows as PNGs without the game:
`luajit tools/screenshots/dump_ui.lua build/screenshots && uv run tools/screenshots/render.py build/screenshots`.

## Releases

The maintainer cuts a release from `main`:

1. Bump `## Version` in `ForeverGuide.toc`. `package.py` and the addon both read it.
2. Move `Unreleased` in [CHANGELOG.md](CHANGELOG.md) into a dated section for that version,
   written for players.
3. Merge both changes by pull request.
4. On the merged `main`: `python3 tools/package.py && python3 tools/check_package.py`. The zip holds
   only committed files.
5. `gh release create vX.Y.Z dist/ForeverGuide-X.Y.Z.zip --notes-file <the version's notes>`.
   `release-cleanup.yml` keeps the two newest releases.
6. Record the data provenance [Data/README.md](Data/README.md#redistribution-status-unresolved) asks for.

A private test build for Windows: `python3 tools/package.py --test` writes `dist/ForeverGuide-<commit>.zip`
and prints its SHA-256.
