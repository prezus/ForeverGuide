-- Prints the share JSON Run.lua and Share.lua write for a short recorded run, one segment per
-- line, outside the game:
--     lua5.1 tools/test/run_fixture.lua
-- The run: START, a quest, a kill, movement, a flight, Send; a death and a level, Send; a turn-in,
-- Stop. forever-codex imports these three segments as one run in its tests.
local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]test[/\\]run_fixture%.lua$") or "./"
if root == "" then root = "./" end

dofile(root .. "tools/test/mock_wow.lua")
local ns = {}
for line in io.lines(root .. "ForeverGuide.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") and not line:match("%.xml$") then
        assert(loadfile(root .. line:gsub("\\", "/")))("ForeverGuide", ns)
    end
end
print = function() end   -- the addon's chat lines
MOCK_FIRE("ADDON_LOADED", "ForeverGuide")
MOCK_FIRE("PLAYER_ENTERING_WORLD", true, false)
MOCK_ADVANCE(1)

local segments = {}
ns.Share.ShowRun = function(_, segment) segments[#segments + 1] = ns.Share:Json(false, ns.Share:RunDoc(segment)) end
math.randomseed(7)

local R = ns.Run
R:SetEnabled(true)
R:Start()
MOCK_ADVANCE(4)
MOCK_ACCEPT(783, "A Threat Within", { { text = "Kobold Vermin slain: 0/10", finished = false, numFulfilled = 0, numRequired = 10 } })
MOCK.target = { name = "Kobold Vermin", npcID = 6, level = 2, hostile = true }
MOCK_FIRE("PLAYER_TARGET_CHANGED")
MOCK_FIRE("PLAYER_REGEN_DISABLED")
MOCK_ADVANCE(9)
MOCK_FIRE("PARTY_KILL", UnitGUID("player"), UnitGUID("target"))
MOCK_FIRE("PLAYER_REGEN_ENABLED")
ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 783, 1, 1, 10, false, "Kobold Vermin slain: 1/10")
MOCK.target = nil
MOCK.mapX = MOCK.mapX + 0.02
MOCK_ADVANCE(6)
MOCK.money = 500
MOCK_FIRE("TAXIMAP_OPENED")
MOCK.money, MOCK.onTaxi = 420, true
MOCK_ADVANCE(1)
MOCK_ADVANCE(40)
MOCK.onTaxi = false
MOCK_ADVANCE(1)
R:Send()
MOCK_ADVANCE(3)
MOCK_DIE(40, 40)
MOCK_ADVANCE(25)
MOCK_REVIVE()
MOCK.level = 2
ns.Events:Fire("FG_LEVEL_CHANGED", 2)
R:Pause()
MOCK_ADVANCE(300)
R:Resume()
MOCK_ADVANCE(2)
R:Send()
ns.Events:Fire("FG_QUEST_TURNED_IN", 783, "A Threat Within", 450, 35)
MOCK_ADVANCE(2)
R:Stop()
io.write(table.concat(segments, "\n"), "\n")
