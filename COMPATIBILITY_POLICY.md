# ForeverGuide client and player-control policy

ForeverGuide targets WoW Forever's beta client, not stock Classic or Retail. This policy applies to every file the release loads (`ForeverGuide.toc`, its XML includes, handwritten Lua, and generated `Data/` and `Guides/` Lua). A documented Blizzard function is **not** automatically permitted: API availability, permission in combat, and whether we *should* call it are separate questions.

## Player-control boundary

- By default, read game state and display advice in ForeverGuide-owned frames. Never automate movement, targeting, combat, casting, item use, inventory/equipment changes, trades, purchases, mail, party actions, or public chat.
- The **only unattended gameplay actions** allowed are quest selection, acceptance, completion and single/no-choice reward claims in `AutoQuest.lua`, in response to the player's interaction with a quest NPC. Respect `/fg auto` settings and Shift bypass; do not accept shared quests from players, auto-accept trivial/repeatable quests outside the active guide, or choose among multiple rewards. Changing this exception requires explicit maintainer approval and in-game testing.
- Other game actions require a **direct player click or command for that specific action**, a clear label, and a documented maintainer-approved exception. A toggle enabled earlier is not itself permission to perform unrelated actions later. Never turn an advice tooltip, timer, login, nameplate scan, or quest-log event into an action on the player's behalf. A secure button may act only on a genuine player click/key press; its macro text must stay limited to its disclosed purpose and be reviewed for injection.
- Do not change Blizzard frames, input bindings, chat filters, or game CVars merely to display the guide. Changes to those surfaces need an explicit opt-in, a narrowly scoped purpose, restoration of the previous state, and review of combat, logout, reload, and failure paths. Do not obscure the UI or take over the screen. ForeverGuide overlays must be dismissible and must not block normal controls.
- Never load executable code from guide text, saved variables, chat, tooltips, or external data. Do not add dynamic Lua execution, concealed API lookup, or code that evades the client protection model. Handle game-provided secret values through `ns.Plain*`/`ns.Safe`; never assume a successful headless mock means an API exists or is permitted on this client.
- Recorder, Scanner, and Harvest are three **independent, off-by-default opt-ins** under Options → Data collection. No quest/NPC capture or automated scan/map requests before the relevant opt-in; opting out must stop in-flight work (previously saved records are retained until separately cleared). The beta persistence mirror must not interpret a legacy default-on setting as consent. User-initiated feedback and essential guide-progress persistence are separate. No collection or transmission of player data beyond these documented local features. No new outbound chat, invitations, queries, or network-like features without an explicit player-facing design and approval. Do not put player names or raw SavedVariables into PRs or releases.

## Compatibility and review gates

1. For every new/changed game API call, record its purpose, triggering event, player consent, default state, and whether it mutates game/client state. Review indirect calls (`ns.Call`, `ns.Safe`, `rawget(_G, ...)`, frame methods and secure attributes) as well as direct calls. Treat new capabilities and changed TOC/XML load paths as security-sensitive.
2. Check the API name against the pinned Forever UI documentation, then verify behavior in-game on the target build, including combat, `/reload`, and login persistence. Generated API docs do not prove that a call is safe, unprotected, or policy-compliant.
3. Run the Lua tests, guide compiler check, lint, and release-package check. The current `compile_guides.py --check` validates JSON **but does not compare generated Lua**; until CI checks reproducible output, review changes to `Guides/` and `Data/` as executable code. No passing scan replaces human review.
4. A PR introducing a capability outside this policy must explain the exception and its test evidence, and receive maintainer approval **before** the policy and code change are merged together. Do not treat an existing violation as permission for another one.

## Existing behavior to resolve (not blanket exceptions)

The following current paths cross or approach the boundary. They are recorded here for review, **not** declared policy-compliant by virtue of already shipping:

- `UI/MobMarker.lua`: automatically writes enemy/friendly nameplate CVars, and prepares a `/targetexact` secure macro (targeting requires the player's click/key).
- `UI/QuestGuideFrame.lua`: fades Blizzard's objective tracker and disables its mouse input by default. `UI.lua` also moves the guide above the world map.
- `Navigation.lua`: optional engine waypoint sets/super-tracks and later clears a map point.
- `Ding.lua`: optional level-up chat/emote; even when off, login requests played time and installs chat suppression hooks.
- `Crowd.lua`: opt-in crowd detection can automatically postpone a guide step; its Go there button changes the navigation target on click.
- `Commands.lua`: `/fg npdbg mark` attempts `SetRaidTarget` on explicit command (reported blocked on this client).
- `Persist.lua`: writes ForeverGuide-prefixed CVars to work around the beta SavedVariables bug; preserve this workaround until client persistence is verified fixed.

Any change to these paths should move them toward the boundary above or document a specific approved exception. In particular, do not add further automatic state-changing behavior just because another feature already does it.
