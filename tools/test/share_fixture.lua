-- Prints the JSON Share.lua writes for a fixed contribution, outside the game:
--     lua5.1 tools/test/share_fixture.lua
-- test_decode_share.py decodes and validates it the way anyone outside our code would.
local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]test[/\\]share_fixture%.lua$") or "./"
if root == "" then root = "./" end

local ns = {}
assert(loadfile(root .. "Core.lua"))("ForeverGuide", ns)
assert(loadfile(root .. "Share.lua"))("ForeverGuide", ns)

_G.UnitRace = function() return "Human", "Human", 1 end
_G.UnitClass = function() return "Warrior", "WARRIOR", 1 end
_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
_G.GetBuildInfo = function() return "1.60.1", "70009" end
ns.version = "0.3.10"
ns.DB = { GetQuest = function() return nil end }
ns.db = {
    contrib = {
        quests = {
            [783] = {
                name = "A Threat Within", level = 1, givers = { 197 }, enders = { 823 }, offeredAt = { 1, 2 },
                sharer = "never shared",    -- not on the allowlist
                objectives = { [1] = { text = "Kobold Vermin slain: 3/10", cells = { [1429] = { { 48.5, 41.5 } } },
                    targets = { [6] = 9, [38] = 1 } } },
            },
            [7] = { name = "Caf\195\169 " .. string.rep("x", 200), shared = true },   -- a long UTF-8 title, cut whole
        },
        npcs = { [197] = { name = "Marshal McBride", level = 20, cells = { [1429] = { { 48.5, 41.5 } } }, guid = "Player-1-1" } },
        order = { 783, -783, 7 },
        maps = { [1429] = { name = "Elwynn Forest", parent = 1415, bounds = { 0, -1.5, 2.25, 3, 4 } } },
        errors = { { key = "UI:OnUpdate", message = "attempt to index nil", guide = "G", step = 3, map = 1429 } },
    },
    harvest = { lines = { [5012] = { map = 1429, x = 40, y = 30, line = 7, lineName = "not shared" } } },
    scan = { quests = { [5013] = "Quote \" and back\\slash and\nnewline" } },
    reports = { { t = 99, text = "giver moved east", q = 783, m = 1429, x = 40.1, y = 50.2, lvl = 5,
        race = "Human", class = "WARRIOR", faction = "Alliance",
        loc = { m = 1429, x = 48.5, y = 41.5, id = 197, kind = "npc" } } },
}
io.write(ns.Share:Json())
