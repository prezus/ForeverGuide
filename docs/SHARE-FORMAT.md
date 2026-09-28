# The `/fg share` format

A player who opts in to **Contribute data** (Options → Data collection, or `/fg share on`)
collects quest facts while they play. `/fg share` turns those facts, their `/fg wrong` reports
and any addon errors into one string that they paste into the feedback form. This page is the
contract between the addon (`Share.lua`) and the code that reads the string on our side.

## Privacy

The addon makes a copy of the data by walking the allowlist below. It never reads anything
else, so no other field can reach the string. The string, the in-game **JSON** view and the
**Readable** summary are all made from that copy. A reader must reject a share that contains a
field missing from this page. The allowlist is also published as a JSON Schema,
[`share-format.schema.json`](share-format.schema.json). The tests check that this page, the
schema and the allowlist in `Share.lua` list exactly the same fields.

A share never contains:

- **Other players.** A quest shared by a party member is only flagged `shared`. The sharer's
  name, level and id are never read.
- **Who the player is.** No character name, realm, account, GUID, guild or chat. The profile
  holds only race, class and faction. Each report carries the same three for the character that
  made it, since reports outlive the character that ran `/fg share`.
- **Time.** No timestamps or dates. `order` is the only sequence: the order in which quests
  were accepted and turned in during the session.
- **Exact positions.** Spots are rounded to half a map unit (`cells`).

Free text appears only in `/fg wrong` reports (`reports[].text`, up to 200 characters). The
addon asks players to leave names out, but readers should still flag text that looks like a name.

## The string

```text
FG2:<part>/<parts>:<payload>
```

The string uses only standard formats, so anyone can read it without ForeverGuide's code:

- `payload` is the JSON (UTF-8), compressed with zlib (RFC 1950, which carries its own Adler-32
  checksum) and then encoded as standard base64 (RFC 4648). Base64 and zlib only make the text
  shorter and safe to paste. They hide nothing: anyone can reverse them.
- A share longer than 50,000 characters is split into numbered parts, each pasted separately.
  Join the payloads of parts `1..parts` in order, then decode. A payload never contains a line
  break, so it runs to the end of its line.
- A client without `C_EncodingUtil` writes `FG2J:<part>/<parts>:<json>`, where the payload
  is the JSON itself.

## Check a share yourself

**In the game.** `/fg share` has three views:
- **Share string**: the text to paste.
- **Readable**: everything in the string, in words: quests, NPCs, spots, reports, and what is
  never included.
- **JSON**: the same data as indented JSON, exactly what the string decodes to.

**Decode it.** Copy the string into a file, `share.txt`, one part per line. Any of these
recipes decodes a one-part share. For several parts, join the payloads first.

- **In a browser, offline:** [CyberChef](https://gchq.github.io/CyberChef/), an open-source
  tool that runs entirely in your browser. Paste only the text after the second `:`, then apply
  the recipe **From Base64** followed by **Zlib Inflate**.
- **Python 3**, standard library only:

  ```sh
  python3 -c "import sys,base64,zlib; print(zlib.decompress(base64.b64decode(sys.stdin.read().split(':',2)[2].strip())).decode())" < share.txt
  ```

- **A shell:** `cut -d: -f3- share.txt | base64 -d > share.zlib`, then inflate `share.zlib`
  with any zlib tool, for example `python3 -c "import sys,zlib; sys.stdout.write(zlib.decompress(sys.stdin.buffer.read()).decode())" < share.zlib`.
- **JavaScript** (browsers and Node 18+): `DecompressionStream("deflate")` reads zlib data.

**Validate it.** Check the decoded JSON against
[`share-format.schema.json`](share-format.schema.json) with any JSON Schema (draft 2020-12)
validator, for example `check-jsonschema --schemafile share-format.schema.json share.json`.
It fails on any field outside the allowlist, a wrong type or a value over its limit.

**Or both at once:** [`tools/decode_share.py`](../tools/decode_share.py) needs only Python 3.
It joins the parts in any order, ignores other text around them, decodes the string, checks the
zlib checksum and validates the result against the schema:

```sh
python3 tools/decode_share.py share.txt
```

## The JSON

Objects keyed by id (`quests`, `npcs`, `maps`, `starts`, `titles`, `objectives`, `targets`,
`cells`) use the id as a string key. Empty values are left out. `cells` are `[x, y]` pairs on
the uiMapID's 0-100 map.

| Field | Type | Meaning |
|---|---|---|
| `format` | integer | Format version, currently 2 |
| `addon` | string | ForeverGuide version (`## Version` in the .toc) |
| `build` | string | Client build, e.g. `1.60.1.70009` |
| `profile.race` | string | The player's race token (`Human`, `Scourge`, ...), used to infer race-only quests |
| `profile.class` | string | The player's class token (`WARRIOR`, ...), used to infer class-only quests |
| `profile.faction` | string | `Alliance` or `Horde` |
| `quests.*.name` | string | Quest title |
| `quests.*.level` | integer | Quest level from the quest log |
| `quests.*.givers[]` | integer | Creature ids that offered the quest (quest window or gossip) |
| `quests.*.enders[]` | integer | Creature ids that took it in (turn-in window or gossip) |
| `quests.*.startItem` | integer | Item id the quest was started from |
| `quests.*.offeredAt[]` | integer | Lowest and highest player level the quest was offered at |
| `quests.*.shared` | boolean | The quest was shared by a party member (not from its NPC) |
| `quests.*.objectives.*.text` | string | Objective text, with its counter (`Kobold Vermin slain: 3/10`) |
| `quests.*.objectives.*.cells.*[][]` | number | Where the objective progressed, per uiMapID |
| `quests.*.objectives.*.targets.*` | integer | Votes: times the objective progressed while this creature id was targeted |
| `npcs.*.name` | string | Creature name |
| `npcs.*.level` | integer | Creature level |
| `npcs.*.cells.*[][]` | number | Where the creature was met, per uiMapID |
| `order[]` | integer | Quest ids accepted (`+id`) and turned in (`-id`), in session order |
| `maps.*.name` | string | uiMapID name |
| `maps.*.parent` | integer | Parent uiMapID |
| `maps.*.bounds[]` | number | `instanceID, x0, y0, x1, y1`: the map's world bounds |
| `starts.*.map` | integer | Quest-line start: uiMapID |
| `starts.*.x` | number | Quest-line start: x (0-100) |
| `starts.*.y` | number | Quest-line start: y (0-100) |
| `starts.*.line` | integer | Quest-line id |
| `titles.*` | string | Quest title the client knew, for quests the bundled database lacks |
| `errors[].key` | string | Where a ForeverGuide Lua error happened |
| `errors[].message` | string | The error, up to 300 characters |
| `errors[].guide` | string | Active guide id |
| `errors[].step` | integer | Active guide step |
| `errors[].map` | integer | uiMapID the player was on |
| `reports[].type` | string | Step type, or `MISSING_ROUTE_QUEST` |
| `reports[].mode` | string | `auto` when the report came from the quest tracker instead of a guide |
| `reports[].what` | string | The tracker's current action |
| `reports[].guide` | string | Guide id |
| `reports[].step` | integer | Guide step |
| `reports[].q` | integer | Quest id |
| `reports[].text` | string | What the player wrote (up to 200 characters) |
| `reports[].title` | string | Quest title (missing-quest reports) |
| `reports[].questLevel` | integer | Quest level (missing-quest reports) |
| `reports[].ready` | boolean | Quest ready to turn in (missing-quest reports) |
| `reports[].failed` | boolean | Quest failed (missing-quest reports) |
| `reports[].m` | integer | Where the player stood: uiMapID |
| `reports[].x` | number | Where the player stood: x |
| `reports[].y` | number | Where the player stood: y |
| `reports[].zone` | string | Zone name |
| `reports[].sub` | string | Subzone name |
| `reports[].lvl` | integer | Player level |
| `reports[].npc` | integer | Targeted creature id |
| `reports[].npcName` | string | Targeted creature name |
| `reports[].npcStep` | integer | The creature id the step names |
| `reports[].race` | string | The race token of the character that made the report (`Scourge`, ...) |
| `reports[].class` | string | Its class token (`ROGUE`, ...) |
| `reports[].faction` | string | Its faction, `Alliance` or `Horde` (Skyborne play on both) |
| `reports[].loc.m` | integer | Where the step pointed: uiMapID |
| `reports[].loc.x` | number | Where the step pointed: x |
| `reports[].loc.y` | number | Where the step pointed: y |
| `reports[].loc.id` | integer | The step target's id |
| `reports[].loc.kind` | string | The step target's kind (`npc`, `object`, ...) |
| `reports[].objectives[].text` | string | Objective text (missing-quest reports) |
| `reports[].objectives[].numFulfilled` | integer | Objective progress |
| `reports[].objectives[].numRequired` | integer | Objective goal |
| `reports[].objectives[].finished` | boolean | Objective done |

## Limits

These are the most the addon writes. A reader may reject a share that exceeds them:

- 2,000 quests and 2,000 NPCs;
- 50 givers or enders per quest, 20 objectives per quest, 24 cells per objective per map,
  and 20 targets per objective;
- 12 cells per NPC per map;
- 1,000 `order` entries, 500 maps, 3,000 `starts` and 3,000 `titles`;
- 50 errors and 300 reports.

Strings are cut to the lengths in `Share.lua`.
