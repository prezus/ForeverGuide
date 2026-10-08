-- Headless test of the ForeverGuide engine against the mock WoW API.
--     cd <addon folder>;  lua5.1 tools/test/run_tests.lua
-- Loads the files in TOC order exactly like the client would, then plays
-- through the fixture guides (tools/test/fixtures/Guides) with simulated quest events.

local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]test[/\\]run_tests%.lua$") or "./"
if root == "" then root = "./" end
package.path = root .. "?.lua;" .. package.path

dofile(root .. "tools/test/mock_wow.lua")

-- ---- load the addon in TOC order ----------------------------------------
local ns = {}
local function loadAddonFile(path)
    local chunk, err = loadfile(root .. path)
    assert(chunk, err)
    chunk("ForeverGuide", ns)
end
--- an XML attribute's value as the game reads it: "&amp;" is "&" (TUGs' "Ashenvale&Wetlands")
local function xmlText(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
--- the files a guides .xml lists, addon-relative
local function xmlFiles(xmlPath)
    local dir, files = xmlPath:match("^(.*)/[^/]+$") or "", {}
    for xl in io.lines(root .. xmlPath) do
        local f = xl:match('file="([^"]+)"')
        if f then files[#files + 1] = (dir .. "/" .. xmlText(f)):gsub("\\", "/") end
    end
    return files
end
-- The engine plays a frozen set of compiled guides (tools/test/fixtures/Guides): a route that
-- is republished must not move these checks. The shipped guides are only checked to decode (see the section below).
local FIXTURE_GUIDES = "tools/test/fixtures/Guides/Guides.xml"
local order, shippedGuides = {}, nil
for line in io.lines(root .. "ForeverGuide.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
        if line:match("%.xml$") then
            shippedGuides = line:gsub("\\", "/")
            for _, f in ipairs(xmlFiles(FIXTURE_GUIDES)) do order[#order + 1] = f end
        else
            order[#order + 1] = line:gsub("\\", "/")
        end
    end
end
assert(shippedGuides, "the TOC lists no guides .xml")
-- the game reads Bindings.xml with the addon; the mock's binding indexes follow it
for xl in io.lines(root .. "Bindings.xml") do
    local name = xl:match('<Binding name="([^"]+)"')
    if name then MOCK.bindingDefs[#MOCK.bindingDefs + 1] = name end
end
for _, f in ipairs(order) do loadAddonFile(f) end

-- every error the addon swallows and reports must surface here
local reportedErrors = {}
do
    local realReport, realError = ns.ReportOnce, ns.Error
    ns.ReportOnce = function(key, err) reportedErrors[#reportedErrors + 1] = tostring(key) .. ": " .. tostring(err) realReport(key, err) end
    ns.Error = function(msg) reportedErrors[#reportedErrors + 1] = tostring(msg) realError(msg) end
end

-- ---- run lifecycle ------------------------------------------------------------
MOCK_FIRE("ADDON_LOADED", "ForeverGuide")
MOCK_FIRE("PLAYER_ENTERING_WORLD", true, false)
MOCK_ADVANCE(1)

-- ---- assertions -----------------------------------------------------------------
local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print("  FAIL: " .. msg) end
end
--- a precondition the rest of its section cannot do without: a failure is counted and ends the section
local function need(cond, msg)
    check(cond, msg)
    if not cond then error("precondition failed: " .. msg, 2) end
end
--- one test section: a Lua error inside it is one failure, and the sections after it still run
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        print("  FAIL: section '" .. name .. "' errored: " .. tostring(err))
    end
end
local G = ns.Guide
local function cur() return G.current end
local function step() return G:GetCurrentStep() end
local function settle() MOCK_ADVANCE(1) end
--- a generated chapter's id by its number prefix: the zone after it moves when the route is re-planned
local function chapterId(prefix)
    for _, id in ipairs(G.list) do if id:find("^" .. prefix) then return id end end
end

print("guide active: " .. tostring(G.active and G.active.id))
-- Listing the route's quests (the Unknown Quests count) reads other chapters' steps without keeping them.
section("listing the route's quests reads other chapters' steps without keeping them", function()
    local built = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if rawget(g, "steps") and g ~= G.active then built[#built + 1] = id end
    end
    check(#built == 0, "after login only the open guide's steps are built (" .. #built .. " others: " .. tostring(built[1]) .. ")")
    local laterQuest
    local ch3 = G.registry[chapterId("GEN_ALLIANCE_HUMAN_03_")]
    for _, s in ipairs(G:ScanSteps(ch3)) do if s.quest then laterQuest = s.quest break end end
    check(laterQuest and G:CoveredQuests()[laterQuest], "a later chapter's quest is still covered by the route")
    check(rawget(ch3, "steps") == nil, "...and scanning that chapter did not keep its steps")
end)
-- Compiled guides ship their steps as packed text, decoded to the same steps on first read.
section("Compiled guides ship their steps as packed text, decoded to the same steps on first read", function()
    local shipped
    local chunk = assert(loadfile(root .. "tools/test/fixtures/Guides/DUNGEON_HORDE_SHADOWFANG_KEEP.lua"))
    chunk("ForeverGuide", { RegisterGuide = function(g) shipped = g end })
    local steps = shipped and ns.DecodeRecord(shipped.steps)
    check(steps and #steps == shipped.stepCount and steps[1].type == "ACCEPT" and steps[1].quest == 1013,
        "...which decodes to its steps (" .. tostring(steps and #steps) .. " of " .. tostring(shipped and shipped.stepCount) .. ")")
end)
-- Every guide that ships loads and decodes to as many steps as it says it has.
section("every shipped guide decodes to its steps", function()
    local count, bad = 0, {}
    for _, path in ipairs(xmlFiles(shippedGuides)) do
        local shipped
        local chunk = assert(loadfile(root .. path))
        chunk("ForeverGuide", { RegisterGuide = function(g) shipped = g end })
        local steps = shipped and type(shipped.steps) == "string" and ns.DecodeRecord(shipped.steps)
        count = count + 1
        local some = steps and (#steps > 0 or shipped.source ~= nil)   -- TUGs' 6-9 Teldrassil has none
        if not (some and #steps == shipped.stepCount) then bad[#bad + 1] = path end
    end
    check(count > 0 and #bad == 0, count .. " shipped guides decode to their steps (" .. #bad .. " do not: " .. tostring(bad[1]) .. ")")
end)
-- The other faction's guides are dropped at login, so their step loaders can be collected.
section("The other faction's guides are dropped at login, so their step loaders can be collected", function()
    local horde, consistent = 0, true
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if not g then consistent = false elseif g.faction == "Horde" then horde = horde + 1 end
    end
    for id in pairs(G.registry) do if not ns.Contains(G.list, id) then consistent = false end end
    check(horde == 0, "an Alliance character keeps no Horde guides (" .. horde .. ")")
    check(consistent, "pruning keeps the guide list and registry in step")
    check(G.registry["GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST"] ~= nil or chapterId("GEN_ALLIANCE_HUMAN_01") ~= nil,
        "the character's own route survives")
    check(G:Dungeons()[1] ~= nil, "the character's dungeon guides survive")

    -- boundary: no faction yet (a Skyborne before choosing a side) prunes nothing
    local savedFaction = MOCK.faction
    MOCK.faction, ns.Player.cache = "Neutral", {}
    ns.RegisterGuide({ id = "TEST_PRUNE_HORDE", name = "prune test", faction = "Horde", steps = {} })
    G:PruneForFaction()
    check(G.registry.TEST_PRUNE_HORDE ~= nil, "no faction: nothing is pruned")
    -- the active guide is never pruned, whatever its faction
    MOCK.faction, ns.Player.cache = savedFaction, {}
    local savedActive = G.active
    G.active = G.registry.TEST_PRUNE_HORDE
    G:PruneForFaction()
    check(G.registry.TEST_PRUNE_HORDE ~= nil, "the active guide is never pruned")
    G.active = savedActive
    G:PruneForFaction()
    check(G.registry.TEST_PRUNE_HORDE == nil and not ns.Contains(G.list, "TEST_PRUNE_HORDE"),
        "an other-faction guide is pruned from list and registry")
end)
-- Contributing data is one opt-in; old switches, mirrors and SavedVariables cannot opt anyone in.
section("contributing data is one opt-in; old switches, mirrors and SavedVariables cannot opt anyone in", function()
    check(ns.db.contribute == false and ns.db.scanEnabled == false, "fresh login: contributing and the scanner start off")
    check(next(ns.db.contrib.quests) == nil and next(ns.db.contrib.npcs) == nil and #ns.db.contrib.order == 0
        and ns.db.scan == nil and ns.db.harvest == nil, "fresh login does not collect session data")
    ns.db.version, ns.db.contribute = 1, true
    ns.Database:Init()
    check(not ns.db.contribute and not ns.db.scanEnabled, "old SavedVariables are not treated as consent")
    -- the old recorder log and harvest switch are dropped with what they held (player names included)
    ForeverGuideDB.recorder = { enabled = true, entries = { { e = "OFFER", npcName = "OldPartymate" } }, maps = {} }
    ForeverGuideDB.harvestEnabled = true
    ns.Database:Init()
    check(ns.db.recorder == nil and ns.db.harvestEnabled == nil, "the old recorder log and harvest switch are removed")
    ns.Scanner:Start(1, 2)
    check(not ns.Scanner.running and ns.db.scan == nil, "scanner refuses to run without opt-in")
    local calls = 0
    local priorQuestLine = rawget(_G, "C_QuestLine")
    _G.C_QuestLine = { RequestQuestLinesForMap = function() calls = calls + 1 end }
    ns.Harvest:OnEnterWorld()
    ns.Events:Fire("FG_ZONE_CHANGED", MOCK.mapID)
    ns.Harvest:HarvestAllMaps()
    check(calls == 0 and ns.db.harvest == nil, "no map requests before opting in to contributing")
    ns.Harvest:Sweep(1, 5000)
    check(not ns.Harvest.sweeping, "harvest sweep refuses to run before opt-in")
    ns.Options:Create()
    local contribute, scan = ns.Options:GetWidget("contribute"), ns.Options:GetWidget("scanner")
    need(contribute and scan and not ns.Options:GetWidget("recorder") and not ns.Options:GetWidget("harvest"),
        "contribute and scanner are separate options; the old recorder and harvest switches are gone")
    do
        contribute:SetChecked(true); contribute:GetScript("OnClick")(contribute)
        check(ns.db.contribute and not ns.db.scanEnabled, "contributing does not enable the scanner")
        check(calls == 1, "contributing permits map quest-line requests")
        scan:SetChecked(true); scan:GetScript("OnClick")(scan)
        local have = rawget(_G, "HaveQuestData")
        _G.HaveQuestData = function() return false end
        ns.Harvest:Sweep(1, 5000)
        check(ns.Harvest.sweeping ~= nil, "an opted-in harvest can start a sweep")
        contribute:SetChecked(false); contribute:GetScript("OnClick")(contribute)
        MOCK_ADVANCE(0.1)
        ns.Harvest:OnEnterWorld()
        check(not ns.Harvest.sweeping and not ns.db.contribute and calls == 1, "opting out cancels an active harvest sweep and map requests")
        _G.HaveQuestData = have
        contribute:SetChecked(true); contribute:GetScript("OnClick")(contribute)
        -- probe: raw answers of the map APIs that place things without the player there
        local taxi, areaPoi = C_TaxiMap.GetTaxiNodesForMap, rawget(_G, "C_AreaPoiInfo")
        C_TaxiMap.GetTaxiNodesForMap = function(mapID)
            if mapID ~= MOCK.mapID then return {} end
            return { { nodeID = 7, name = "Thor", isUndiscovered = true, position = { x = 0.335, y = 0.62 } } }
        end
        _G.C_AreaPoiInfo = {
            GetQuestHubsForMap = function(mapID) return mapID == MOCK.mapID and { 42 } or {} end,
            GetAreaPOIInfo = function(_, id) return { areaPoiID = id, name = "Quest hub", position = { x = 0.5, y = 0.25 } } end,
        }
        local probe = ns.Harvest:Probe()
        local m = probe and probe.maps[MOCK.mapID] or {}
        local node = (m["C_TaxiMap.GetTaxiNodesForMap"] or {})[1]
        local hub = (m["C_AreaPoiInfo.GetQuestHubsForMap"] or {})[1]
        check(node and node.name == "Thor" and math.abs(node.x - 33.5) < 0.01 and node.isUndiscovered == "true", "probe stores flight nodes on the map with their position")
        check(hub and hub.areaPoiID == 42 and hub.name == "Quest hub" and math.abs(hub.y - 25) < 0.01, "probe looks up quest hub details by id")
        check(probe.at == nil, "probe stores no wall-clock time")
        check(probe.spells[1243969] ~= nil and probe.spells[1243969].aura == false, "probe records whether the character has the kill-XP aura")
        C_TaxiMap.GetTaxiNodesForMap, _G.C_AreaPoiInfo = taxi, areaPoi
    end
    _G.C_QuestLine = priorQuestLine
    ns.Database:Init()
    check(ns.db.contribute and ns.db.scanEnabled, "explicit v2 opt-ins survive a normal SavedVariables login")
end)
-- Addon Lua errors join the contribution while contributing is on.
section("Addon Lua errors join the contribution while contributing is on", function()
    local errors = ns.db.contrib.errors
    local before, errorsBefore = #errors, #reportedErrors
    ns.ReportOnce("test:ui-error", "broken button")
    local e = errors[#errors]
    check(#errors == before + 1 and e.key == "test:ui-error" and e.message == "broken button" and e.map == MOCK.mapID
        and e.guide == G.active.id and e.step == G.current, "a reported UI Lua error is kept with its map, guide and step")
    ns.ReportOnce("test:ui-error", "broken button")
    check(#errors == before + 1, "the same error does not flood the contribution")
    ns.db.contribute = false
    ns.ReportOnce("test:ui-disabled", "not captured")
    check(#errors == before + 1, "contributing off skips Lua error capture")
    ns.db.contribute = true
    while #errors > before do table.remove(errors) end
    while #reportedErrors > errorsBefore do table.remove(reportedErrors) end
end)
-- Contributing keeps facts, not an event log: who gives and ends a quest, where, at what level,
-- and what was targeted when an objective moved. Never another player, never the time.
local function mentions(t, needle, seen)
    seen = seen or {}
    if type(t) == "string" then return t:find(needle, 1, true) ~= nil end
    if type(t) ~= "table" or seen[t] then return false end
    seen[t] = true
    for k, v in pairs(t) do
        if mentions(k, needle, seen) or mentions(v, needle, seen) then return true end
    end
    return false
end
section("contributing keeps facts, not an event log; never another player, never the time", function()
    local c = ns.db.contrib
    local npc, offered, fromPlayer, target = MOCK.npc, MOCK.offeredQuest, MOCK.offerFromPlayer, MOCK.target
    local autoShared = ns.AutoQuest.Cfg().shared
    ns.AutoQuest.Cfg().shared = false
    MOCK.npc = { name = "Marshal Test", npcID = 9001, level = 20 }
    MOCK.offeredQuest = 5010
    MOCK.log[5010] = { title = "Fact Quest", level = 5, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL", 4242); settle()
    MOCK_FIRE("QUEST_DETAIL", 4242); settle()
    local q = c.quests[5010]
    check(q and q.name == "Fact Quest" and #q.givers == 1 and q.givers[1] == 9001 and q.startItem == 4242,
        "the offer window records the quest's giver and the item that starts it, once")
    check(q and q.offeredAt and q.offeredAt[1] == MOCK.level and q.offeredAt[2] == MOCK.level, "the player level at the offer is kept")
    local n = c.npcs[9001]
    local cells = n and n.cells[MOCK.mapID]
    check(n and n.name == "Marshal Test" and n.level == 20 and cells and #cells == 1
        and cells[1][1] * 2 == math.floor(cells[1][1] * 2) and cells[1][2] * 2 == math.floor(cells[1][2] * 2),
        "the giver's spot is kept once, on a half-unit map cell")
    ns.Events:Fire("FG_QUEST_ACCEPTED", 5010, "Fact Quest")
    check(c.order[#c.order] == 5010, "accepting adds the quest to the session's order")
    -- an objective moves while a hostile mob is targeted
    MOCK.target = { name = "Test Wolf", npcID = 321, level = 3, hostile = true }
    ns.Events:Fire("FG_TARGET_CHANGED", { npcID = 321, name = "Test Wolf", level = 3, reaction = "hostile", isPlayer = false })
    ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 5010, 1, 1, 5, false, "Test Wolf slain: 1/5")
    local o = q.objectives and q.objectives[1]
    check(o and o.text == "Test Wolf slain: 1/5" and o.targets and o.targets[321] == 1 and o.cells[MOCK.mapID] and #o.cells[MOCK.mapID] == 1,
        "objective progress keeps its text, spot, and a vote for the targeted mob")
    -- a player target is never a vote
    MOCK.target = nil
    ns.Events:Fire("FG_TARGET_CHANGED", { name = "Somebody", level = 30, reaction = "hostile", isPlayer = true })
    MOCK_ADVANCE(30)
    ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 5010, 1, 2, 5, false, "Test Wolf slain: 2/5")
    check(o.targets[321] == 1 and not mentions(c, "Somebody"), "a player target is never kept, and an old target gets no vote")
    -- turn-in
    MOCK.npc = { name = "Ender Test", npcID = 9002, level = 20 }
    MOCK_FIRE("QUEST_COMPLETE"); settle()
    ns.Events:Fire("FG_QUEST_TURNED_IN", 5010, "Fact Quest")
    check(#q.enders == 1 and q.enders[1] == 9002 and c.order[#c.order] == -5010, "the turn-in NPC and the turn-in order are kept")
    -- a quest shared by a party member: flagged, never who
    MOCK.npc = { name = "Partymate", npcID = 424242, level = 12 }
    MOCK.offerFromPlayer = true
    MOCK.offeredQuest = 5005
    MOCK.log[5005] = { title = "Shared Privacy", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    ns.Events:Fire("FG_QUEST_ACCEPTED", 5005, "Shared Privacy")
    check(c.quests[5005] and c.quests[5005].shared == true and #(c.quests[5005].givers or {}) == 0,
        "a quest shared by a player is flagged shared, with no giver")
    check(not mentions(ns.db, "Partymate") and c.npcs[424242] == nil, "a sharing player's name, level and id are not stored anywhere")
    -- the share's window has no "npc" unit: the targeted mob nearby is not the quest's giver
    MOCK.npc, MOCK.target = nil, { name = "Hostile Wolf", npcID = 777, level = 5, hostile = true }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(#(c.quests[5005].givers or {}) == 0 and c.npcs[777] == nil, "a shared quest window is not credited to the player's target")
    check(not mentions(c, "Tester") and not mentions(c, "Classic Beta PvE 2"), "the player's own name and realm are never kept")
    MOCK.log[5005], MOCK.log[5010] = nil, nil
    MOCK.npc, MOCK.offeredQuest, MOCK.offerFromPlayer, MOCK.target = npc, offered, fromPlayer, target
    ns.AutoQuest.Cfg().shared = autoShared
    -- contributing off: windows record nothing
    ns.db.contribute = false
    MOCK.npc = { name = "Off Giver", npcID = 9003, level = 20 }
    MOCK_FIRE("GOSSIP_SHOW"); settle()
    check(c.npcs[9003] == nil, "with contributing off nothing is kept")
    MOCK.npc = npc
    ns.db.contribute = true
end)
-- /fg share: one string for the feedback form, holding only allowlisted fields.
section("/fg share: one string for the feedback form, holding only allowlisted fields", function()
    local json = dofile(root .. "tools/test/json.lua")
    local c = ns.db.contrib
    -- data that must never leave, planted where the store could hold it
    c.quests[5010].sharer = "Partymate"
    c.npcs[9001].guid = "Player-1-000001"
    ns.db.reports = { { t = 1234.5, text = "giver moved", q = 5010, m = MOCK.mapID, x = 40.1, y = 50.2, lvl = 5,
        npc = 9001, npcName = "Marshal Test", secret = "Tester", race = "Scourge", class = "ROGUE", faction = "Horde" } }
    local doc = json.decode(ns.Share:Json())
    local q = doc.quests and doc.quests["5010"]
    check(doc.format == 2 and doc.addon == ns.version and doc.profile and doc.profile.race and doc.profile.class
        and doc.profile.faction, "the share carries the format, addon version and race/class/faction")
    check(q and q.name == "Fact Quest" and q.givers[1] == 9001 and q.enders[1] == 9002 and q.startItem == 4242
        and q.objectives["1"].targets["321"] == 1, "the share carries the quest facts")
    local order = doc.order or {}
    check(order[#order - 2] == 5010 and order[#order - 1] == -5010 and order[#order] == 5005, "the share carries the session order")
    local r = doc.reports and doc.reports[1]
    check(r and r.text == "giver moved" and r.npc == 9001 and r.t == nil and r.secret == nil, "reports are shared without their time or unknown fields")
    check(r and r.race == "Scourge" and r.class == "ROGUE" and r.faction == "Horde", "a shared report names the character that made it")
    check(ns.Share:Summary():find("as Scourge Rogue, Horde", 1, true), "Readable names the character of each report")
    local raw = ns.Share:Json()
    check(not raw:find("Partymate", 1, true) and not raw:find("Player-", 1, true) and not raw:find("Tester", 1, true)
        and not raw:find("Classic Beta PvE 2", 1, true) and not raw:find("sharer", 1, true) and not raw:find("guid", 1, true),
        "fields outside the allowlist never reach the share")
    c.quests[5010].sharer, c.npcs[9001].guid = nil, nil
    -- the share string: zlib + base64 when the client has C_EncodingUtil, plain JSON otherwise
    local enc = rawget(_G, "C_EncodingUtil")
    _G.C_EncodingUtil = nil
    local parts = ns.Share:Strings()
    check(#parts == 1 and parts[1] == "FG2J:1/1:" .. raw, "without C_EncodingUtil the share is the JSON itself")
    local method
    _G.C_EncodingUtil = {
        CompressString = function(s, m) method = m return "z(" .. s .. ")" end,
        EncodeBase64 = function(s) return "b64<" .. s .. ">" end,
    }
    parts = ns.Share:Strings()
    check(#parts == 1 and parts[1] == "FG2:1/1:b64<z(" .. raw .. ")>" and method == 1, "the share is zlib-compressed, then base64")
    -- long shares split into numbered parts that join back into the payload
    for id = 90001, 90900 do c.quests[id] = { name = string.rep("Q", 60), givers = { 1 }, enders = { 2 } } end
    _G.C_EncodingUtil = nil
    parts = ns.Share:Strings()
    local joined, ok = {}, #parts > 1
    for i, p in ipairs(parts) do
        local head, body = p:match("^(FG2J:" .. i .. "/" .. #parts .. ":)(.*)$")
        ok = ok and head ~= nil and #p <= ns.Share.PART_MAX
        joined[#joined + 1] = body or ""
    end
    check(ok and table.concat(joined) == ns.Share:Json(), "a long share splits into numbered parts that join back ("
        .. #parts .. " parts)")
    for id = 90001, 90900 do c.quests[id] = nil end
    _G.C_EncodingUtil = enc
    -- /fg share opens the string to copy; Readable explains it in words, JSON shows it as data
    ns.Commands:Run("share")
    local win = rawget(_G, "ForeverGuideShare")
    local text = win and win.text:GetText() or ""
    check(win and win:IsShown() and text:find("^FG2J?:1/1:"), "/fg share opens the share string, selected for copying")
    win.views.readable:GetScript("OnClick")()
    text = win.text:GetText() or ""
    check(text:find("WHAT THIS SHARE CONTAINS", 1, true) and text:find("[5010] Fact Quest", 1, true)
        and text:find("Given by: Marshal Test (9001)", 1, true) and text:find("Turned in to: Ender Test (9002)", 1, true)
        and text:find("Started from item 4242", 1, true) and text:find("Targeted when it moved: Test Wolf (321) x1", 1, true)
        and text:find("Never included:", 1, true) and text:find("SHARE-FORMAT.md", 1, true),
        "Readable lists the quests, NPCs and what is never included, in words (" .. text:sub(1, 300):gsub("\n", " | ") .. ")")
    check(not text:find("Partymate", 1, true) and not text:find("Tester", 1, true), "Readable shows only what the string holds")
    win.views.json:GetScript("OnClick")()
    text = win.text:GetText() or ""
    check(text:find('"format": 2', 1, true) and text:find("Fact Quest", 1, true), "JSON shows the data the string holds")
    win.views.string:GetScript("OnClick")()
    check((win.text:GetText() or ""):find("^FG2J?:1/1:"), "Share string switches back to the string")
    win:Hide()
    -- anyone can validate a share without our code: the published JSON Schema is the allowlist
    local schemaFile = io.open(root .. "docs/share-format.schema.json")
    local committed = schemaFile and schemaFile:read("*a") or ""
    if schemaFile then schemaFile:close() end
    local generate = dofile(root .. "tools/lib/share_schema.lua")
    check(committed == generate(ns.Share.SCHEMA), "docs/share-format.schema.json is generated from the allowlist "
        .. "(regenerate: lua5.1 tools/share_schema.lua > docs/share-format.schema.json)")
    -- capped text never cuts a character in half (a cut UTF-8 sequence is not valid JSON)
    check(ns.Utf8Sub("abc\195\169", 4) == "abc" and ns.Utf8Sub("abc\195\169", 5) == "abc\195\169"
        and ns.Utf8Sub("\226\130\172x", 2) == "" and ns.Utf8Sub("plain", 3) == "pla", "text is cut on whole UTF-8 characters")
    c.quests[5010].name = string.rep("a", 119) .. "\195\169"
    local cut = json.decode(ns.Share:Json()).quests["5010"].name
    check(cut == string.rep("a", 119), "a quest title capped mid-character loses the whole character")
    c.quests[5010].name = "Fact Quest"
    -- the allowlist and its documentation agree
    local documented = {}
    for line in io.lines(root .. "docs/SHARE-FORMAT.md") do
        local path = line:match("^| `([^`]+)` |")
        if path then documented[path] = true end
    end
    local missing, extra = {}, {}
    for _, path in ipairs(ns.Share:Paths()) do
        if not documented[path] then missing[#missing + 1] = path end
        documented[path] = nil
    end
    for path in pairs(documented) do extra[#extra + 1] = path end
    check(#missing == 0 and #extra == 0, "docs/SHARE-FORMAT.md documents exactly the allowlist (missing: "
        .. table.concat(missing, ", ") .. "; extra: " .. table.concat(extra, ", ") .. ")")
    ns.Commands:Run("share clear")
    check(next(c.quests) == nil and next(c.npcs) == nil and #c.order == 0, "/fg share clear empties the collected facts")
    ns.db.reports = {}
end)
-- Record runs: an opt-in of its own that shows run controls on the guide window. The player
-- starts, pauses and stops a run and sends it in segments through the share window. Times count
-- seconds of recording since the run started: never the clock.
section("record runs: an opt-in, run controls on the guide window, segments through the share window", function()
    local json = dofile(root .. "tools/test/json.lua")
    local R = ns.Run
    need(R ~= nil, "the run recorder module exists")
    local function last() local run = ns.char.run return run and run.entries[#run.entries] end
    local function find(kind)
        local out = {}
        for _, e in ipairs(ns.char.run and ns.char.run.entries or {}) do if e.e == kind then out[#out + 1] = e end end
        return out
    end
    ns.UI:Show()
    local header = ForeverGuideFrame.header
    -- off by default: no controls, nothing recorded, Start refuses
    check(ns.db.recordRuns == false, "recording runs is off by default")
    check(not (header.run and header.run:IsShown()) and ns.QuestGuideHeader.HEIGHT == 50, "with it off the guide window shows no run controls")
    R:Start()
    MOCK_ACCEPT(7101, "Run Off Quest")
    check(ns.char.run == nil, "with it off a run cannot start and nothing is recorded")
    -- the option shows the controls; nothing records until Start
    ns.Options:Create()
    local opt = ns.Options:GetWidget("runs")
    need(opt ~= nil, "Record runs has its own switch under Data collection")
    local contributeWas = ns.db.contribute
    opt:SetChecked(true); opt:GetScript("OnClick")(opt)
    local strip = header.run
    need(ns.db.recordRuns and strip and strip:IsShown(), "switching Record runs on shows the run controls on the guide window")
    check(ns.QuestGuideHeader.HEIGHT > 50, "the header grows to hold the controls")
    check(ns.db.contribute == contributeWas, "Record runs does not touch Contribute data")
    check(R:State() == "idle" and ns.char.run == nil and strip.start:IsShown() and not strip.stop:IsShown(),
        "the controls start idle with only Start offered")
    -- Start: the run begins at t = 0
    strip.start:GetScript("OnClick")(strip.start)
    local run = ns.char.run
    need(R:State() == "recording" and run and run.id and run.seg == 1, "Start begins a run in its first segment")
    check(type(run.id) == "string" and run.id:match("^%x+$") and #run.id == 16 and run.id:find("[1-9a-f]"),
        "the run id is random hex, not the character (" .. tostring(run.id) .. ")")
    check(run.entries[1].e == "START" and run.entries[1].t == 0, "the run opens with START at t = 0")
    check(strip.pause:IsShown() and strip.stop:IsShown() and strip.send:IsShown() and not strip.start:IsShown(),
        "while recording the controls offer Pause, Stop and Send")
    -- quest events carry the common fields and the guide step being followed
    MOCK_ADVANCE(10)
    MOCK_ACCEPT(7102, "Run Quest", { { text = "Run Wolf slain: 0/2", finished = false, numFulfilled = 0, numRequired = 2 } })
    settle()
    local a = find("ACCEPT")[1]
    check(a and a.q == 7102 and a.lvl == MOCK.level and a.m == MOCK.mapID and a.x and a.y, "an accept is kept with the quest, level and position")
    check(a and a.t >= 10 and a.t < 13, "t counts seconds since the run started (" .. tostring(a and a.t) .. ")")
    check(a and a.g == G.active.id and a.s == G.current, "each entry names the guide and step being followed")
    -- movement: sampled every 5 s while the player moves, with the mount flag
    local moves = #find("MOVE")
    MOCK_ADVANCE(6)
    check(#find("MOVE") == moves, "standing still records no movement")
    MOCK.mapX, MOCK.mounted = MOCK.mapX + 0.01, true
    MOCK_ADVANCE(6)
    local mv = find("MOVE")[moves + 1]
    check(mv and mv.mounted == true and mv.taxi == false and math.abs(mv.x - MOCK.mapX * 100) < 0.01, "moving records a sample with the mount and taxi flags")
    MOCK.mounted = false
    -- a kill: the mob's level and class, and the seconds from the pull
    MOCK.target = { name = "Run Wolf", npcID = 7201, level = 6, hostile = true, classification = "elite" }
    MOCK_FIRE("PLAYER_TARGET_CHANGED")
    MOCK_FIRE("PLAYER_REGEN_DISABLED")
    MOCK_ADVANCE(8)
    local wolf = UnitGUID("target")
    MOCK_FIRE("PARTY_KILL", UnitGUID("player"), wolf)
    local k = find("KILL")[1]
    check(k and k.npc == 7201 and k.mobLevel == 6 and k.elite == true and k.secs and math.abs(k.secs - 8) < 1.5,
        "a kill keeps the creature, its level, elite, and seconds from the pull (" .. tostring(k and k.secs) .. ")")
    MOCK_FIRE("UNIT_DIED", wolf)
    check(#find("KILL") == 1, "the same death reported twice is one kill")
    MOCK_FIRE("PARTY_KILL", "Player-1-000099", "Creature-0-1-1-1-7202-0000000009")
    check(#find("KILL") == 1, "a kill by someone else on a mob the player never fought is not the player's")
    MOCK.target = { name = "Run Boar", npcID = 7203, level = 5, hostile = true }
    MOCK_FIRE("PLAYER_TARGET_CHANGED")
    MOCK_FIRE("PARTY_KILL", UnitGUID("player"), UnitGUID("target"))
    MOCK_FIRE("PARTY_KILL", UnitGUID("player"), "Creature-0-1-1-1-7204-0000000011")
    local boar, unseen = find("KILL")[2], find("KILL")[3]
    check(boar and boar.npc == 7203 and boar.elite == false and unseen and unseen.npc == 7204 and unseen.elite == nil
        and unseen.mobLevel == nil, "a normal mob is recorded not elite; one never targeted leaves level and class unknown")
    table.remove(ns.char.run.entries) table.remove(ns.char.run.entries)
    MOCK.target = nil
    MOCK_FIRE("PLAYER_TARGET_CHANGED")
    MOCK_FIRE("PLAYER_REGEN_ENABLED")
    -- objective progress, turn-in and a level
    ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 7102, 1, 1, 2, false, "Run Wolf slain: 1/2")
    local o = find("OBJ")[1]
    check(o and o.q == 7102 and o.obj == 1 and o.f == 1 and o.r == 2 and o.done == false, "objective progress is kept with its count")
    ns.Events:Fire("FG_QUEST_TURNED_IN", 7102, "Run Quest", 450, 125)
    local ti = find("TURNIN")[1]
    check(ti and ti.q == 7102 and ti.xp == 450 and ti.money == 125, "a turn-in keeps its xp and money")
    ns.Events:Fire("FG_LEVEL_CHANGED", MOCK.level + 1)
    check(last().e == "LEVEL" and last().l == MOCK.level + 1 and last().rested ~= nil, "a level-up keeps the new level and rested xp")
    -- a flight: the fare when it starts, the seconds when it lands
    MOCK.money = 1000
    MOCK_FIRE("TAXIMAP_OPENED")
    MOCK.money, MOCK.onTaxi = 900, true
    MOCK_ADVANCE(1)
    local tx = find("TAXI")[1]
    check(tx and tx.cost == 100, "taking a flight keeps where it started and its fare (" .. tostring(tx and tx.cost) .. ")")
    MOCK_ADVANCE(60)
    MOCK.onTaxi = false
    MOCK_ADVANCE(1)
    local land = find("LAND")[1]
    check(land and land.secs and math.abs(land.secs - 61) < 2, "landing keeps where and how long the flight took (" .. tostring(land and land.secs) .. ")")
    -- death and the way back
    MOCK_DIE(40, 40)
    check(#find("DEATH") == 1 and #find("RESURRECT") == 0, "dying is kept; releasing the spirit is not a resurrection")
    MOCK_ADVANCE(30)
    MOCK_REVIVE()
    local res = find("RESURRECT")[1]
    check(res and res.secs and math.abs(res.secs - 30) < 2, "coming back keeps the seconds dead")
    -- the hearthstone
    MOCK_FIRE("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 8690)
    check(last().e == "HEARTH" and last().action == "use", "using the hearthstone is kept")
    MOCK_FIRE("HEARTHSTONE_BOUND")
    check(last().e == "HEARTH" and last().action == "bind", "setting the hearthstone is kept")
    -- Pause: nothing is recorded, and paused time does not count
    strip.pause:GetScript("OnClick")(strip.pause)
    local pausedAt = last().t
    check(R:State() == "paused" and last().e == "PAUSE" and strip.pause.label:GetText():find("Resume"), "Pause stops the clock and offers Resume")
    local n = #ns.char.run.entries
    MOCK_ADVANCE(100)
    MOCK_ACCEPT(7103, "Paused Quest")
    MOCK.mapX = MOCK.mapX + 0.02
    MOCK_ADVANCE(6)
    check(#ns.char.run.entries == n, "while paused nothing is recorded")
    strip.pause:GetScript("OnClick")(strip.pause)
    check(R:State() == "recording" and last().e == "RESUME" and last().t == pausedAt, "Resume carries on from the paused time")
    -- no clock, no identity, only allowlisted fields
    local stamps = true
    for _, e in ipairs(ns.char.run.entries) do if e.t > 100000 then stamps = false end end
    check(stamps and not mentions(ns.char.run, "Tester") and not mentions(ns.char.run, "Player-")
        and not mentions(ns.char.run, "Creature-"), "a run holds no clock time, names or GUIDs")
    -- Send: the segment goes to the share window; recording carries on in the next segment
    local sentCount = #ns.char.run.entries
    strip.send:GetScript("OnClick")(strip.send)
    local win = rawget(_G, "ForeverGuideShare")
    need(win and win:IsShown(), "Send opens the share window")
    check((win.text:GetText() or ""):find("^FG2J?:1/1:"), "the segment is one share string to paste into the feedback form")
    local doc = json.decode(win.json)
    check(doc.format == 2 and doc.profile and doc.profile.class and doc.run and doc.run.id == ns.char.run.id and doc.run.seg == 1
        and #doc.run.entries == sentCount, "the share holds the profile and the run's first segment, every entry of it")
    check(doc.quests == nil and doc.npcs == nil and doc.reports == nil, "a segment share holds the run, not the contributed facts")
    check(doc.maps and doc.maps[tostring(MOCK.mapID)] ~= nil, "a segment share names the maps its entries stand on")
    local raw = win.json
    check(not raw:find("Tester", 1, true) and not raw:find("Player-", 1, true) and not raw:find("Creature-", 1, true),
        "the segment share holds no names or GUIDs")
    win.views.readable:GetScript("OnClick")()
    check((win.text:GetText() or ""):find("RUN SEGMENT", 1, true), "Readable describes the run segment")
    win:Hide()
    check(R:State() == "recording" and ns.char.run.seg == 2 and #ns.char.run.entries == 0, "after Send recording carries on in segment 2")
    MOCK_ADVANCE(5)
    MOCK_ACCEPT(7104, "Second Segment Quest")
    local nextT = find("ACCEPT")[1]
    check(nextT and nextT.t > doc.run.entries[#doc.run.entries].t, "segment 2 carries on the run's clock")
    -- logout pauses the run; a login with SavedVariables carries it on as it was
    MOCK_FIRE("PLAYER_LOGOUT")
    check(R:State() == "paused" and last().e == "PAUSE", "logging out pauses the run")
    ns.Database:Init()
    check(ns.char.run and ns.char.run.seg == 2 and #find("ACCEPT") == 1, "SavedVariables carry the paused run and its entries")
    R:Resume()
    check(last().e == "RESUME" and last().t >= nextT.t, "the run resumed after a login carries on its clock")
    -- a full segment pauses itself (the run notice dialog asks to send it: its own section)
    for _ = #ns.char.run.entries, R.MAX_ENTRIES do ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 7104, 1, 1, 2, false, "x") end
    check(R:State() == "paused" and #ns.char.run.entries <= R.MAX_ENTRIES + 1, "a full segment pauses the run")
    R:Send()
    rawget(_G, "ForeverGuideShare"):Hide()
    -- Stop: the last segment goes out marked done; the run ends; Send shows it again to copy
    R:Resume()
    MOCK_ACCEPT(7105, "Last Quest")
    strip.stop:GetScript("OnClick")(strip.stop)
    win = rawget(_G, "ForeverGuideShare")
    doc = json.decode(win.json)
    check(doc.run and doc.run.seg == 3 and doc.run.done == true and doc.run.entries[#doc.run.entries].e == "STOP",
        "Stop sends the last segment, marked done")
    check(R:State() == "idle" and ns.char.run == nil and strip.start:IsShown(), "after Stop the controls are idle again")
    win:Hide()
    R:Send()
    check(win:IsShown() and json.decode(win.json).run.seg == 3, "Send while idle shows the last segment again, to copy it")
    win:Hide()
    -- commands mirror the buttons
    ns.Commands:Run("run start")
    check(R:State() == "recording", "/fg run start starts a run")
    ns.Commands:Run("run pause")
    check(R:State() == "paused", "/fg run pause pauses it")
    ns.Commands:Run("run discard")
    check(R:State() == "idle" and ns.char.run == nil, "/fg run discard throws the run away")
    -- switching the option off while recording pauses the run and hides the controls
    R:Start()
    opt:SetChecked(false); opt:GetScript("OnClick")(opt)
    check(not ns.db.recordRuns and R:State() == "paused" and not strip:IsShown() and ns.QuestGuideHeader.HEIGHT == 50,
        "switching Record runs off pauses the run and hides the controls")
    n = #ns.char.run.entries
    MOCK_ACCEPT(7106, "Off Again Quest")
    R:Resume()
    check(#ns.char.run.entries == n and R:State() == "paused", "with the option off nothing records and Resume refuses")
    ns.char.run = nil
    for q = 7101, 7106 do MOCK.log[q] = nil end
end)
section("engine walkthrough of the fixture guide", function()
check(ns.db.ding.enabled == false and ns.db.nav.blizzardWaypoint == false
    and ns.db.nav.waypoint.enabled == false and ns.db.nav.waypoint.route == false
    and ns.db.ui.arrow.enabled == true, "quiet defaults: no ding, pin or dotted route; arrow on")
check(G.active and G.active.faction == "Alliance" and G.active.minLevel == 1 and ns.Contains(G.active.race, "Human"), "auto-picked a human 1-10 guide: " .. tostring(G.active and G.active.id))
G:Activate("HUMAN_NORTHSHIRE_1_6", true); settle()
check(cur() == 1 and step().type == "ACCEPT" and step().quest == 783, "starts at step 1 (accept 783)")
check(not ns.QuestGuide.frame.extra:IsShown(), "extra panel starts hidden with an empty quest log")

-- accept A Threat Within -> advance to turn-in
MOCK_ACCEPT(783, "A Threat Within"); settle()
check(cur() == 2 and step().type == "TURNIN", "after accepting 783, current is TURNIN 783 (" .. tostring(cur()) .. ")")
check(G:GetStepProgress(step()) == "ready to turn in", "a quest without objectives is immediately ready: " .. G:GetStepProgress(step()))

-- turn in -> ACCEPT 7
MOCK_TURNIN(783); settle()
check(cur() == 3 and step().quest == 7, "after turning in 783, current is ACCEPT 7 (" .. tostring(cur()) .. ")")

-- accept 7 -> warrior class quest steps (we ARE a warrior) -> ACCEPT 3100
MOCK_ACCEPT(7, "Kobold Camp Cleanup", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
check(cur() == 4 and step().quest == 3100, "warrior sees the class quest step (" .. tostring(cur()) .. ")")

-- switch to a mage: class steps are skipped
MOCK.class = { "Mage", "MAGE", 8 }; ns.Player.cache.classFile = nil
G:Evaluate("test")
check(cur() == 6 and step().quest == 5261, "mage skips warrior-only steps (" .. tostring(cur()) .. ")")
MOCK.class = { "Warrior", "WARRIOR", 1 }; ns.Player.cache.classFile = nil
G:Evaluate("test")
check(cur() == 6, "position only moves forward on its own (" .. tostring(cur()) .. ")")
G:SetStep(4); settle()
check(cur() == 4, "/fg step 4 brings the class step back (" .. tostring(cur()) .. ")")
do
    local classRow, plainRow
    for _, e in ipairs((ns.QuestGuide:BuildGuideEntries())) do
        if e.questID == 3100 and not classRow then classRow = e end
        if e.questID == 7 and not plainRow then plainRow = e end
    end
    check(classRow and classRow.title:find("[Warrior]", 1, true) ~= nil, "a class quest's row says whose it is (" .. tostring(classRow and classRow.title) .. ")")
    check(plainRow and plainRow.title:find("[", 1, true) == nil, "...and a quest for everyone says nothing (" .. tostring(plainRow and plainRow.title) .. ")")
end

-- skipping an ACCEPT skips the whole quest (3100 turn-in too)
G:Skip(); settle()
check(cur() == 6 and step().quest == 5261, "skipping ACCEPT 3100 also skips its TURNIN (" .. tostring(cur()) .. ")")

-- accept 5261, 18, turn in 5261, accept 33
MOCK_ACCEPT(5261, "Eagan Peltskinner"); settle()
MOCK_ACCEPT(18, "Brotherhood of Thieves", { { text = "Red Burlap Bandana", finished = false, numFulfilled = 0, numRequired = 12 } }); settle()
MOCK_TURNIN(5261); settle()
MOCK_ACCEPT(33, "Wolves Across the Border", { { text = "Tough Wolf Meat", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 10 and step().type == "KILL" and step().quest == 7, "now killing kobold vermin (" .. tostring(cur()) .. ")")
check(G:GetStepProgress(step()) == "0 / 10", "kill progress 0/10: " .. G:GetStepProgress(step()))

-- objective progress updates but does not advance
MOCK_PROGRESS(7, 1, 6); settle()
check(cur() == 10 and G:GetStepProgress(step()) == "6 / 10", "progress 6/10 keeps the step (" .. G:GetStepProgress(step()) .. ")")

-- navigation target follows the step
MOCK_MOVE(49.0, 36.3)
local nav = ns.Navigation:Update()
check(nav and nav.distance and nav.distance < 1, "distance ~0 when standing on the target: " .. tostring(nav and nav.distance))
MOCK_MOVE(49.0, 40.0)
nav = ns.Navigation:Update()
check(nav and math.abs(nav.distance - 37) < 1, "distance 37 yd (fake projection) when 3.7 map units south: " .. tostring(nav and nav.distance))
-- target is north of us, facing north (0): angle ~0 -> "ahead"
check(nav.angle and math.abs(nav.angle) < 0.01 and ns.Navigation:DirectionWord(nav.angle) == "ahead", "target straight ahead when facing north")
MOCK.facing = math.pi / 2  -- facing west -> target is to the right
nav = ns.Navigation:Update()
check(ns.Navigation:DirectionWord(nav.angle) == "right", "facing west, target to the right: " .. ns.Navigation:DirectionWord(nav.angle))
MOCK.facing = 0

-- finish kobolds: KILL 7 done, wolves objective still open -> COLLECT 33 current
MOCK_PROGRESS(7, 1, 10); settle()
check(cur() == 11 and step().type == "COLLECT" and step().quest == 33, "kobolds done -> collect wolf meat (" .. tostring(cur()) .. ")")

-- player abandons quest 33: COLLECT is blocked, engine jumps back to ACCEPT 33 (step 9)
MOCK_ABANDON(33); settle()
check(cur() == 9 and step().type == "ACCEPT" and step().quest == 33, "abandoned quest -> back to its ACCEPT step (" .. tostring(cur()) .. ")")
check(G.note ~= nil, "recovery note shown: " .. tostring(G.note))

-- re-accept and complete it, turn in 7 too
MOCK_ACCEPT(33, "Wolves Across the Border", { { text = "Tough Wolf Meat", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 11, "re-accepted -> collect step again (" .. tostring(cur()) .. ")")
MOCK_PROGRESS(33, 1, 8); settle()
check(cur() == 12 and step().type == "TURNIN" and step().quest == 7, "wolf meat done -> turn in 7 (" .. tostring(cur()) .. ")")
-- Forever quirk: the completion flag can read true for a quest that is still in the log (seen after
-- /reload); the log wins and the turn-in stays current instead of being walked past
MOCK.completed[7] = true; ns.Guide:Evaluate("reload"); settle()
check(cur() == 12 and step().type == "TURNIN" and step().quest == 7, "a completion flag on a quest still in the log does not skip its turn-in (" .. tostring(cur()) .. ")")
MOCK.completed[7] = nil

-- player is AHEAD of the guide: turns in 7, 33, accepts 15, 3903 and even turns 3903 in
MOCK_TURNIN(7); settle()
MOCK_ACCEPT(15, "Investigate Echo Ridge", { { text = "Kobold Worker slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
MOCK_TURNIN(33); settle()
MOCK_ACCEPT(3903, "Milly Osworth"); settle()
MOCK_TURNIN(3903); settle()
MOCK_ACCEPT(3904, "Milly's Harvest", { { text = "Milly's Harvest", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 18 and step().type == "KILL" and step().quest == 15, "guide caught up to the player: kill kobold workers (" .. tostring(cur()) .. ")")

-- GRIND optional step + TRAVEL auto-completion via arrival
G:SetStep(33); settle()
need(cur() == 33 and step().type == "GRIND", "jumped to GRIND step (" .. tostring(cur()) .. ")")
MOCK_LEVEL(5); settle()
check(cur() == 34 and step().type == "TRAVEL", "level 5 reached -> TRAVEL step (" .. tostring(cur()) .. ")")
MOCK_MOVE(45.6, 47.7)
ns.UI:UpdateNavigation(true); settle()
check(cur() == 35 and step().type == "ACCEPT" and step().quest == 2158, "arrival completes TRAVEL -> accept 2158 (" .. tostring(cur()) .. ")")

-- TALK-style completion: a manual step completes when the next automatic step is done
MOCK_ACCEPT(2158, "Rest and Relaxation"); settle()
check(cur() == 36 and step().type == "TRAVEL", "accepted 2158 -> travel to Goldshire (" .. tostring(cur()) .. ")")
MOCK_ACCEPT(54, "Report to Goldshire"); settle()
MOCK_TURNIN(54); settle()
check(cur() == 38 and step().quest == 2158 and step().type == "TURNIN", "turning in 54 auto-completes the TRAVEL before it (" .. tostring(cur()) .. ")")

-- HEARTH: bound at the step's innkeeper (HEARTHSTONE_BOUND), or earlier (GetBindLocation)
MOCK_TURNIN(2158); settle()
check(cur() == 39 and step().type == "HEARTH", "hearth step (" .. tostring(cur()) .. ")")
check(G:GetStepText(step()) == "Set your hearthstone at the Lion's Pride Inn", "a hand-written hearth step keeps its text")
check(G:GetStepText({ type = "HEARTH", npc = 295, npcName = "Innkeeper Farley", zone = "Goldshire" }) == "Set your hearthstone with Innkeeper Farley (Goldshire)",
    "a generated hearth step names the innkeeper")
do
    local function bindWith(npcID, name)
        MOCK.npc = { npcID = npcID, name = name, level = 30 }
        MOCK_FIRE("HEARTHSTONE_BOUND"); settle()
        MOCK.npc = nil
    end
    bindWith(6727, "Innkeeper Brianna")
    check(cur() == 39, "binding with another innkeeper leaves the hearth step open (" .. tostring(cur()) .. ")")
    bindWith(295, "Innkeeper Farley")
    check(cur() == 40 and step().type == "NOTE", "binding with the step's innkeeper completes it, whatever the inn is called (" .. tostring(cur()) .. ")")
    -- a bind made before the step: the bind location stands in for the event
    G.progress.done[39] = nil; G:SetStep(39); settle()
    MOCK.bind = "Goldshire"; G:Evaluate("test")
    check(cur() == 40 and step().type == "NOTE", "bind location matched -> final NOTE (" .. tostring(cur()) .. ")")
end
G:Skip(); settle()
check(step() == nil and G.active ~= nil, "guide complete")

-- back / reset
G:Back()
check(cur() == 40, "back returns to the last step (" .. tostring(cur()) .. ")")
G:Reset(); settle()
check(cur() == 4 and step().quest == 3100 and next(G.progress.done) == nil,
    "reset forgets manual skips (3100 is back) but still passes completed quests 783 and 7 (" .. tostring(cur()) .. ")")

ns.UI:Refresh()
end)
-- The extra quest panel follows the guide window but never duplicates a routed quest.
section("The extra quest panel follows the guide window but never duplicates a routed quest", function()
    local f = ns.QuestGuide.frame
    MOCK_ACCEPT(999991, "Unplanned errand", { { text = "Gather 2 things", finished = false, numFulfilled = 1, numRequired = 2 } }); settle()
    local extra = f.extra
    check(extra and not extra:IsShown(), "the Unknown Quests panel stays closed until its button is clicked")
    check(f.unknownBtn and (f.unknownBtn.label:GetText() or ""):find("Unknown Quests (1)", 1, true),
        "the Unknown Quests button counts the quests no guide covers (" .. tostring(f.unknownBtn and f.unknownBtn.label:GetText()) .. ")")
    f.unknownBtn:GetScript("OnClick")(f.unknownBtn)
    check(extra and extra:IsShown() and extra.list.entries[1] and extra.list.entries[1].questID == 999991,
        "unrouted log quest appears in the panel below the guide")
    local openedTo
    local priorOpen = rawget(_G, "QuestMapFrame_OpenToQuestDetails")
    _G.QuestMapFrame_OpenToQuestDetails = function(questID) openedTo = questID end
    extra.list.rows[1]:GetScript("OnClick")(extra.list.rows[1], "LeftButton")
    check(openedTo == 999991, "left click on an unknown quest opens it in the quest log (" .. tostring(openedTo) .. ")")
    _G.QuestMapFrame_OpenToQuestDetails = priorOpen
    -- a quest a later chapter of the route handles is not unknown, although the open guide lacks it
    local later
    for _, s in ipairs(G:Get(chapterId("GEN_ALLIANCE_HUMAN_03_")).steps) do
        if s.type == "ACCEPT" and s.quest then later = s.quest break end
    end
    MOCK_ACCEPT(later, "Later chapter quest", {}); settle()
    local listedLater = false
    for _, e in ipairs(extra.list.entries) do if e.questID == later then listedLater = true end end
    check(later and not listedLater and #extra.list.entries == 1, "a quest from another chapter of the route is not unknown")
    MOCK_ABANDON(later); settle()
    check(extra and extra:GetParent() == f and extra.list.entries[1].subtitle:find("Gather 2 things", 1, true),
        "extra panel is attached to guide and shows objective progress")
    local reportsBefore = #(ns.db.reports or {})
    extra.list.rows[1]:GetScript("OnClick")(extra.list.rows[1], "RightButton")
    local missing = ns.db.reports and ns.db.reports[reportsBefore + 1]
    check(missing and missing.q == 999991 and missing.title == "Unplanned errand" and missing.questLevel == 1
        and missing.guide == G.active.id and missing.type == "MISSING_ROUTE_QUEST" and missing.m ~= nil
        and missing.objectives and missing.objectives[1] and missing.objectives[1].text == "Gather 2 things"
        and missing.objectives[1].numFulfilled == 1 and missing.objectives[1].numRequired == 2,
        "right-click captures unknown quest, objectives, route and player location")
    check(missing and missing.race == "Human" and missing.class == "WARRIOR" and missing.faction == "Alliance",
        "a missing-quest report records the character's race, class and faction")
    check(missing and ns.Reports.Export({ missing }):find("Unplanned errand", 1, true)
        and ns.Reports.Export({ missing }):find("Gather 2 things", 1, true),
        "copyable report includes quest title and objectives")
    MOCK_ABANDON(999991); settle(); settle()
    local afterAbandon = #(ns.db.reports or {})
    ns.Reports:MissingQuest(999991)
    check(#ns.db.reports == afterAbandon, "abandoned quest cannot be reported as current")
    if missing then table.remove(ns.db.reports, reportsBefore + 1) end
    MOCK_ACCEPT(783, "A Threat Within"); settle()
    local duplicated = false
    for _, e in ipairs(extra.list.entries) do if e.questID == 783 then duplicated = true end end
    check(not duplicated, "quest present in guide steps is not listed as extra")
    local remains = false
    for _, e in ipairs(extra.list.entries) do if e.questID == 999991 then remains = true end end
    check(not remains, "abandoned quest leaves the extra panel")
    check((f.unknownBtn.label:GetText() or "") == "Unknown Quests", "no count on the button once every quest is covered")
    f.unknownBtn:GetScript("OnClick")(f.unknownBtn)
    check(not extra:IsShown(), "the Unknown Quests button closes its panel again")
    MOCK_ABANDON(783); settle()
end)

-- ---- quest database: lean steps resolve through the DB ----
section("quest database: lean steps resolve through the DB", function()
    local starts = ns.DB:QuestStarts(783)
    local objs = ns.DB:QuestObjectives(7)
    check(objs[1] and objs[1].kind == "kill" and objs[1].name == "Kobold Vermin" and #objs[1].locations > 5, "quest 7 objective = kill Kobold Vermin with spawns (" .. tostring(objs[1] and #objs[1].locations) .. ")")
    local m = ns.DB:MatchObjective(7, 1, "Kobold Vermin slain: 3/10")
    check(m and m.id == 6, "objective text matched to npc 6")
    local ok, why = ns.DB:IsAvailable(76)
    check(ok == false and why:match("requires"), "76 needs 62 first: " .. tostring(why))

    -- a guide with no coordinates at all
    ns.RegisterGuide({ id = "LEAN_TEST", name = "Lean test", steps = {
        { type = "ACCEPT", quest = 62 }, { type = "TURNIN", quest = 62 }, { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11 }, { type = "TURNIN", quest = 11 } } })
    G:Activate("LEAN_TEST", true); settle()
    local plain = G:GetStepText(step()):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(plain == "Accept [7] The Fargodeep Mine", "lean ACCEPT text from DB with level tag: " .. plain)
    local t = ns.Navigation.target
    check(t and t.map == 1429 and math.abs(t.x - 42.1) < 0.05 and math.abs(t.y - 65.9) < 0.05, "lean ACCEPT navigates to Marshal Dughan (" .. tostring(t and t.x) .. "," .. tostring(t and t.y) .. ")")
    G:SetStep(4); settle()
    check(cur() == 3 and step().type == "ACCEPT" and step().quest == 11, "KILL of a quest not in the log falls back to its ACCEPT (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Painted Gnoll Armband", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
    plain = G:GetStepText(step()):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(cur() == 4 and plain:match("^Kill .* %(%[%d+%] Riverpaw Gnoll Bounty%)$"), "lean KILL text from DB: " .. plain)
    t = ns.Navigation.target
    check(t and t.map == 1429, "lean KILL step navigates to a gnoll spawn (" .. tostring(t and t.x) .. "," .. tostring(t and t.y) .. ")")

    -- tracker / auto mode
    ns.Tracker:SetMode("auto"); settle()
    ns.Tracker:Rethink()
    check(ns.Tracker.current ~= nil, "tracker picked a quest from the log: " .. tostring(ns.Tracker.current and ns.Tracker.current.title))
    ns.UI:Refresh()
    ns.UI:TogglePicker()
    check(ForeverGuidePicker and ForeverGuidePicker:IsShown() and #ForeverGuidePicker.rows >= 2, "guide picker shows auto mode + guides (" .. tostring(ForeverGuidePicker and #ForeverGuidePicker.rows) .. " rows)")
    -- rows: auto, "ROUTES" header, routes..., "CHAPTERS" header, chapters...; click the first chapter row
    local chapterRow, routeRow
    for _, row in ipairs(ForeverGuidePicker.rows) do
        if row:IsShown() and not row.header then
            if row.onClick and not routeRow then routeRow = row end
            if row.guideID and row.guideID ~= "__auto" and not chapterRow then chapterRow = row end
        end
    end
    check(routeRow ~= nil and chapterRow ~= nil, "picker lists routes and chapters")
    chapterRow:GetScript("OnClick")(chapterRow)
    check(ns.char.mode == "guide" and ns.Guide.active ~= nil and not ForeverGuidePicker:IsShown(), "clicking a guide activates it and closes the picker")
    check(ForeverGuideArrowFrame ~= nil and (ForeverGuideArrowFrame:IsShown() or (ns.Waypoint.overlay and ns.Waypoint.overlay:IsShown())), "a target shows either the chevron arrow or the world waypoint")
    -- any route of the faction can be chosen; the race's own is only the default
    local routes = ns.Guide:Routes()
    local other
    for _, r in ipairs(routes) do if not r.mine then other = r break end end
    need(other ~= nil, "routes of other races are offered too")
    do
        local r, pick = ns.Guide:ChooseRoute(other.key)
        check(r and r.key == other.key and pick ~= nil and ns.char.route == other.key and ns.Guide.active and ns.Guide.active.id == pick.id, string.format("choosing another race's route activates its fitting chapter (r=%s pick=%s active=%s route=%s)", tostring(r and r.key), tostring(pick and pick.id), tostring(ns.Guide.active and ns.Guide.active.id), tostring(ns.char.route)))
        local ap = ns.Guide:AutoPick()
        check(ap and ns.Guide:RouteOf(ap) == other.key, "auto-pick follows the chosen route (" .. tostring(ap and ap.id) .. ")")
        ns.Commands:Run("path race")
        check(ns.char.route == nil, "/fg path race goes back to the race's own route")
    end
    ns.Tracker:SetMode("guide")
end)

-- ---- auto quest + minimap ----
section("auto quest + minimap", function()
    MOCK.offeredQuest = 60
    MOCK.log[60] = { title = "Kobold Candles", level = 7, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == 60, "QUEST_DETAIL auto-accepts the offered quest")
    MOCK.shift = true
    MOCK.offeredQuest = 62
    MOCK.log[62] = { title = "The Fargodeep Mine", level = 7, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "holding shift bypasses auto-accept")
    MOCK.shift = false

    -- alt-click the minimap button: everything off the screen, and back
    local mb = ForeverGuideMinimapButton
    ns.UI:Show()
    ns.Navigation:SetTarget({ map = 1429, x = 40, y = 60, label = "test", owner = "test" })
    ns.Arrow:SetEnabled(true); ns.Arrow:Refresh()
    -- arrow size: /fg arrow size, /fg qg arrowsize, and out-of-range values
    check(ns.Arrow:GetScale() == 1, "arrow size defaults to 1")
    ns.Commands:Run("arrow size 1.5")
    check(ns.Arrow:GetScale() == 1.5 and ForeverGuideArrowFrame:GetScale() == 1.5, "/fg arrow size resizes the live frame")
    ns.Commands:Run("qg arrowsize 0.7")
    check(ns.Arrow:GetScale() == 0.7, "/fg qg arrowsize also sets it")
    local okBig, msgBig = ns.QuestGuideConfig.SetNumber("arrowsize", 9)
    check(okBig == true and ns.Arrow:GetScale() == 2.5, "an out-of-range size is clamped to the max, not rejected (" .. tostring(msgBig) .. ")")
    ns.Commands:Run("arrow size 1")
    -- a typo after "arrow " must not silently flip it off (Ilya, 2026-09-24: this happened live)
    local arrowWasOn = ns.db.ui.arrow.enabled
    ns.Commands:Run("arrow sized 2")
    check(ns.db.ui.arrow.enabled == arrowWasOn, "an unrecognized /fg arrow option is rejected, not treated as a toggle")
    -- the Options panel exposes arrow size as a real slider, not just the chat command
    do
        ns.Options:Create()
        local slider = ns.Options:GetWidget("arrowsize")
        need(slider ~= nil, "the panel built a slider for arrow size")
        do
            -- drive it the way a player drags it, then confirm Refresh() reads the change back
            slider:SetValue(2.0)
            check(ns.Arrow:GetScale() == 2.0, "dragging the panel slider resizes the arrow")
            ns.Commands:Run("arrow size 1.2")
            ns.Options:Refresh()
            check(slider:GetValue() == 1.2, "setting it from /fg is reflected back onto the panel slider")
            slider:SetValue(9)
        end
        ns.Commands:Run("arrow size 1")
    end
    check(ForeverGuideArrowFrame.mouse == true, "arrow accepts dragging when unlocked and tracking a target")
    ns.Commands:Run("lock")
    check(ForeverGuideArrowFrame.mouse == false and not ForeverGuideFrame.resizeGrip:IsShown(), "locking disables arrow drag and hides resize grip")
    ns.Commands:Run("unlock")
    check(ForeverGuideArrowFrame.mouse == true and ForeverGuideFrame.resizeGrip:IsShown(), "unlocking enables arrow drag and resize grip")
    local function pointerShown() return ns.Arrow:IsShown() or (ns.Waypoint.overlay and ns.Waypoint.overlay:IsShown()) end
    local frameWasShown = ForeverGuideFrame:IsShown()
    local arrowWasShown = pointerShown()
    need(frameWasShown and arrowWasShown, "window and waypoint/arrow are up before the alt-click")
    MOCK.alt = true
    mb.scripts.OnClick(mb, "LeftButton"); settle()
    check(not ForeverGuideFrame:IsShown(), "alt-click hides the guide window")
    check(not pointerShown(), "alt-click hides the waypoint and the arrow")
    check(ns.db.ui.arrow.enabled ~= false, "hiding everything does not disable the arrow itself")
    mb.scripts.OnClick(mb, "LeftButton"); settle()
    MOCK.alt = false
    check(ForeverGuideFrame:IsShown(), "the window comes back")
    check(pointerShown(), "the waypoint / arrow comes back")
    -- combat hiding must not undo it, and /fg hideall is the same switch
    ns.Commands:Run("hideall on")
    ns.db.ui.hideInCombat = true
    MOCK_FIRE("PLAYER_REGEN_DISABLED"); settle()
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(not ForeverGuideFrame:IsShown(), "leaving combat does not undo the hide-everything switch")
    check(not pointerShown(), "leaving combat does not bring the waypoint / arrow back while hidden")
    ns.db.ui.hideInCombat = false
    ns.Commands:Run("hideall off")
    check(not ns.UI:AllHidden() and ForeverGuideFrame:IsShown(), "/fg hideall off brings everything back")
    ns.Navigation:Clear()

    MOCK.questChoices = 1
    MOCK_FIRE("QUEST_COMPLETE"); settle()
    check(MOCK.rewardTaken == 1, "single-reward turn-in is completed automatically")
    MOCK.rewardTaken = nil
    MOCK.questChoices = 3
    MOCK_FIRE("QUEST_COMPLETE"); settle()
    check(MOCK.rewardTaken == nil, "multi-reward turn-in is left for the player")
    ns.AutoQuest:Set("accept", "guide")
    MOCK.offeredQuest = 5001
    MOCK.log[5001] = { title = "Bijou's Belongings", level = 55, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "accept=guide ignores quests outside the guide")
    ns.AutoQuest:Set("accept", "on")
    -- direct QUEST_DETAIL path: grey / repeatable / player-shared quests are not auto-accepted
    MOCK.trivial = { [5002] = true }
    MOCK.offeredQuest = 5002
    MOCK.log[5002] = { title = "Grey Quest", level = 1, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "trivial (grey) quest offered directly is not auto-accepted")
    MOCK.repeatable = { [5003] = true }
    MOCK.offeredQuest = 5003
    MOCK.log[5003] = { title = "Repeatable", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "repeatable quest offered directly is not auto-accepted")
    MOCK.offerFromPlayer = true
    MOCK.offeredQuest = 5004
    MOCK.log[5004] = { title = "Shared", level = 10, objectives = {} }
    ns.AutoQuest:Set("shared", "off")
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "with shared-quest accept off, a quest shared by another player is left to the player")
    ns.AutoQuest:Set("shared", "on")
    MOCK.offerFromPlayer = false
    MOCK.offeredQuest = 0
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "closed quest window (id 0) is ignored")
    MOCK.offeredQuest = 5004
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == 5004, "a normal directly-offered quest is still auto-accepted")
    ns.Commands:Run("auto")
    MOCK.log[60], MOCK.log[62], MOCK.log[5001], MOCK.log[5002], MOCK.log[5003], MOCK.log[5004] = nil, nil, nil, nil, nil, nil
    MOCK.trivial, MOCK.repeatable = nil, nil
end)

-- ---- party quest sharing: share what you accept, accept what the party shares ----
section("party quest sharing: share what you accept, accept what the party shares", function()
    local A = ns.AutoQuest
    check(A.Cfg().share == true and A.Cfg().shared == true, "sharing and accepting shared quests are on by default")
    local function pushed(qid)
        for _, id in ipairs(MOCK.pushed) do if id == qid then return true end end
        return false
    end

    -- accepting a quest from an NPC while grouped shares it
    MOCK.group = true
    MOCK_ACCEPT(7001, "Party Quest"); settle()
    check(pushed(7001), "a quest accepted while grouped is shared with the group")
    MOCK.pushed = {}
    MOCK.unpushable = { [7002] = true }
    MOCK_ACCEPT(7002, "Unshareable"); settle()
    check(not pushed(7002), "a quest the game will not let you share is not shared")
    MOCK.unpushable = nil

    -- solo, or with the option off: nothing is shared
    MOCK.group = false
    MOCK_ACCEPT(7003, "Solo Quest"); settle()
    check(not pushed(7003), "solo, an accepted quest is not shared")
    MOCK.group = true
    ns.Commands:Run("auto share off")
    MOCK_ACCEPT(7004, "Private Quest"); settle()
    check(not pushed(7004), "/fg auto share off stops sharing")
    ns.Commands:Run("auto share on")

    -- a quest a party member shares is accepted, and not shared back
    MOCK.acceptedViaFrame = nil
    MOCK.offerFromPlayer = true
    MOCK.offeredQuest = 7005
    MOCK.log[7005] = { title = "Shared With Me", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == 7005, "a quest shared by a party member is auto-accepted")
    MOCK.log[7005] = nil
    MOCK_ACCEPT(7005, "Shared With Me"); settle()
    check(not pushed(7005), "a quest accepted from a share is not shared back to the group")

    -- the shared quest still goes through the grey / repeatable filter
    MOCK.acceptedViaFrame = nil
    MOCK.trivial = { [7006] = true }
    MOCK.offeredQuest = 7006
    MOCK.log[7006] = { title = "Grey Share", level = 1, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "a shared grey quest outside the guide is not auto-accepted")
    MOCK.trivial, MOCK.log[7006] = nil, nil

    -- taken by hand with the option off: still not shared back
    ns.Commands:Run("auto shared off")
    MOCK.offeredQuest = 7007
    MOCK.log[7007] = { title = "Hand Accepted", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "/fg auto shared off leaves a shared quest to the player")
    MOCK.log[7007] = nil
    MOCK_ACCEPT(7007, "Hand Accepted"); settle()
    check(not pushed(7007), "a shared quest the player accepted by hand is not shared back either")
    MOCK_ABANDON(7007)
    MOCK.offerFromPlayer = false
    MOCK_FIRE("QUEST_DETAIL"); settle()               -- the same quest, now offered by its NPC
    MOCK_ACCEPT(7007, "Hand Accepted"); settle()
    check(pushed(7007), "a declined share taken later from the NPC is shared again")

    -- a group escort ("<name> is starting <quest>. Would you like to join?")
    MOCK.confirmedEscort = nil
    MOCK_FIRE("QUEST_ACCEPT_CONFIRM", "Partymate", "Escort Quest", 7008); settle()
    check(MOCK.confirmedEscort == nil, "with shared-quest accept off, a group escort is left to the player")
    ns.Commands:Run("auto shared on")
    MOCK_FIRE("QUEST_ACCEPT_CONFIRM", "Partymate", "Escort Quest", 7008); settle()
    check(MOCK.confirmedEscort == 1 and MOCK.popupHidden == "QUEST_ACCEPT", "a group escort is joined and its popup closed")
    MOCK.shift = true
    MOCK_FIRE("QUEST_ACCEPT_CONFIRM", "Partymate", "Escort Quest", 7008); settle()
    check(MOCK.confirmedEscort == 1, "holding shift leaves a group escort to the player")
    MOCK.shift = false
    -- a full log: the client shows its own log-full popup with Yes disabled, so the escort cannot be joined
    MOCK.popupHidden = nil
    MOCK.logCap = ns.Quest:GetNumQuests()
    MOCK_FIRE("QUEST_ACCEPT_CONFIRM", "Partymate", "Escort Quest", 7008); settle()
    check(MOCK.confirmedEscort == 1 and MOCK.popupHidden == nil, "with a full quest log a group escort is left to the player")
    MOCK.logCap = nil


    for _, qid in ipairs({ 7001, 7002, 7003, 7004, 7005, 7007 }) do MOCK_ABANDON(qid) end
    MOCK.group, MOCK.pushed, MOCK.acceptedViaFrame, MOCK.offeredQuest = false, {}, nil, nil
end)

-- ---- multi-objective steps: each KILL/COLLECT step tracks its own objective ----
section("multi-objective steps: each KILL/COLLECT step tracks its own objective", function()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
    local steps = G.active.steps
    local a, b
    for i, s in ipairs(steps) do
        if s.quest == 52 and (s.type == "KILL" or s.type == "COLLECT") then
            if not a then a = i elseif not b then b = i end
        end
    end
    need(a and b, "Elwynn guide has two objective steps for quest 52 (" .. tostring(a) .. "," .. tostring(b) .. ")")
    do
        MOCK_ACCEPT(52, "Young Forest Bear... no: Rolf and Malakai", {
            { text = "Young Forest Bear slain: 0/8", finished = false, numFulfilled = 0, numRequired = 8 },
            { text = "Prowler slain: 0/8", finished = false, numFulfilled = 0, numRequired = 8 },
        }); settle()
        G:SetStep(a); settle()
        check(G:StepObjectiveIndex(steps[a]) == 1 and G:StepObjectiveIndex(steps[b]) == 2,
            "steps map to objectives 1 and 2 by target name (" .. tostring(G:StepObjectiveIndex(steps[a])) .. "," .. tostring(G:StepObjectiveIndex(steps[b])) .. ")")
        -- the route interleaves other quests' objectives between the two: put those quests in the log, finished
        local between = {}
        for i = a + 1, b - 1 do
            local st = steps[i]
            if st.quest and st.quest ~= 52 and not MOCK.log[st.quest] then
                MOCK_ACCEPT(st.quest, "Quest " .. st.quest, { { text = "done: 1/1", finished = true, numFulfilled = 1, numRequired = 1 } })
                between[#between + 1] = st.quest
            end
        end
        settle()
        MOCK.log[52].objectives[1] = { text = "Young Forest Bear slain: 8/8", finished = true, numFulfilled = 8, numRequired = 8 }
        MOCK_FIRE("QUEST_LOG_UPDATE"); settle()
        check(cur() == b, "first objective done -> second objective step is current (" .. tostring(cur()) .. ")")
        check(G:GetStepProgress(steps[b]) == "0 / 8", "progress shows the second objective's own count: " .. G:GetStepProgress(steps[b]))
        -- /fg back holds the previous (already finished) step
        G:Back(); settle()
        check(cur() < b and cur() >= a, "back holds a finished step (" .. tostring(cur()) .. ")")
        G:Skip(); settle()
        check(cur() == b, "skip releases the hold (" .. tostring(cur()) .. ")")
        MOCK.log[52] = nil
        for i, id in ipairs(MOCK.logOrder) do if id == 52 then table.remove(MOCK.logOrder, i) break end end
        for _, qid in ipairs(between) do
            MOCK.log[qid] = nil
            for i, id in ipairs(MOCK.logOrder) do if id == qid then table.remove(MOCK.logOrder, i) break end end
        end
    end
end)

-- ---- scanner: simulated server with silence for unknown ids and a throttle ----
section("scanner: simulated server with silence for unknown ids and a throttle", function()
    local server = { [5]=true,[6]=true,[7]=true,[8]=true,[9]=true,[11]=true,[12]=true,[13]=true,[14]=true,[15]=true,
                     [16]=true,[18]=true,[19]=true,[20]=true,[21]=true,[22]=true,[26]=true,[27]=true,[28]=true,[29]=true,
                     [30]=true,[31]=true,[33]=true,[34]=true,[35]=true,[36]=true,[37]=true,[38]=true,[39]=true,[40]=true,
                     [45]=true,[46]=true,[47]=true,[52]=true,[54]=true,[56]=true,[59]=true,[60]=true,[90001]=true }
    local answered, requests, throttleUntil = 0, 0, nil
    MOCK.titles = {}
    for id in pairs(server) do MOCK.titles[id] = "Quest " .. id end
    local realHave, realRequest = rawget(_G, "HaveQuestData"), C_QuestLog.RequestLoadQuestByID
    _G.HaveQuestData = function() return false end
    local realTitle = C_QuestLog.GetTitleForQuestID
    C_QuestLog.GetTitleForQuestID = function(id) return nil end
    C_QuestLog.RequestLoadQuestByID = function(id)
        requests = requests + 1
        if requests == 30 then throttleUntil = MOCK.time + 12 end       -- server goes deaf for 12 s
        if throttleUntil and MOCK.time < throttleUntil then return end
        if server[id] then
            C_Timer.After(0.5, function()
                C_QuestLog.GetTitleForQuestID = function(q) return server[q] and ("Quest " .. q) or nil end
                MOCK_FIRE("QUEST_DATA_LOAD_RESULT", id, true)
                answered = answered + 1
            end)
        end
    end
    ns.db.scan = nil
    ns.Scanner:Start(1, 60)
    for i = 1, 1200 do MOCK_ADVANCE(0.25) if not ns.Scanner.running then break end end
    local sc = ns.db.scan
    local exist, silent = 0, 0
    for _ in pairs(sc.quests) do exist = exist + 1 end
    for _ in pairs(sc.missing) do silent = silent + 1 end
    check(not ns.Scanner.running and sc.done, "scanner finished in " .. tostring(MOCK.time) .. "s")
    check(exist == 38, "scanner found all 38 existing ids in 1-60 despite the throttle (" .. exist .. ")")
    local wrong = 0
    for id in pairs(sc.missing) do if server[id] then wrong = wrong + 1 end end
    check(wrong == 0, "no existing quest was judged silent (" .. wrong .. ")")
    local un = 0
    for _ in pairs(sc.unanswered) do un = un + 1 end
    check(silent + un == 60 - 38, "the other " .. (60 - 38) .. " ids are silent or unanswered (" .. silent .. " + " .. un .. ")")
    ns.Commands:Run("scan status")
    -- "/fg scan new": exactly the bundled Forever-only id ranges, with level + objectives captured
    local realDifficulty, realObjectives = C_QuestLog.GetQuestDifficultyLevel, C_QuestLog.GetQuestObjectives
    C_QuestLog.GetQuestDifficultyLevel = function(id) return server[id] and 7 or 0 end
    C_QuestLog.GetQuestObjectives = function(id) return server[id] and { { text = "Dark Iron Spy slain: 0/10", type = "monster" } } or {} end
    server[90104] = true
    local savedRanges = ns.ForeverNewQuestIDRanges
    ns.ForeverNewQuestIDRanges = { { 90001, 90001 }, { 90104, 90104 } }
    throttleUntil = nil
    ns.Scanner:Start("new")
    for i = 1, 400 do MOCK_ADVANCE(0.25) if not ns.Scanner.running then break end end
    check(sc.quests[90104] == "Quest 90104" and sc.info[90104] and sc.info[90104].lvl == 7 and sc.info[90104].obj[1] == "Dark Iron Spy slain: 0/10",
        "scan new records title, level and objectives of a Forever quest")
    ns.ForeverNewQuestIDRanges = savedRanges
    ns.Scanner:Start(1, 1000)
    ns.Commands:Run("scan off")
    local sent = requests
    MOCK_ADVANCE(2)
    check(not ns.Scanner.running and requests == sent, "opting out stops an in-progress server scan")
    ns.Commands:Run("scan on")
    C_QuestLog.GetTitleForQuestID = realTitle
    C_QuestLog.GetQuestDifficultyLevel, C_QuestLog.GetQuestObjectives = realDifficulty, realObjectives
    _G.HaveQuestData, C_QuestLog.RequestLoadQuestByID = realHave, realRequest
    ns.Quest:Refresh()
end)


-- ---- Forever overlay data merged into the Classic database ---------------------------------
section("Forever overlay data merged into the Classic database", function()
    check(ns.DB:GetQuest(317) and ns.DB:GetQuest(317).fobj and ns.DB:GetQuest(317).fobj[1].spm ~= nil, "overlay objective evidence attached to vanilla quest 317")
    check(ns.DB:GetNPC(1131) and ns.DB:GetNPC(1131).spm ~= nil, "overlay npc points merged into vanilla npc 1131")
    local locs = ns.DB:NPCLocations(1131)
    local hasForever = false
    for _, l in ipairs(locs) do if l.forever and l.map == 1426 then hasForever = true end end
    check(hasForever, "spm points show up in NPCLocations")
    local objs = ns.DB:QuestObjectives(317)
    check(objs[1] and #objs[1].locations > 0, "vanilla objective of 317 keeps its own locations (" .. tostring(objs[1] and #objs[1].locations) .. ")")
    local fq = ns.DB:GetQuest(99128)
    check(ns.Quest:XPMultiplier(783, 1) == 1 and ns.Quest:XPMultiplier(783, 7) == 0.8 and ns.Quest:XPMultiplier(783, 12) == 0.1, "xp multiplier follows the Classic reduction table")
end)

-- ---- packed records: the indexes match the records, decoding is safe and cached --------------
section("packed records: the indexes match the records, decoding is safe and cached", function()
    local DB = ns.DB
    local byZone, byItem = {}, {}
    for id, q in DB:EachQuest() do
        if q.zone and q.zone > 0 then
            local z = DB:ParentZone(q.zone)
            byZone[z] = byZone[z] or {}
            byZone[z][id] = true
        end
        for _, e in ipairs(q.item or {}) do
            if e[1] then byItem[e[1]] = byItem[e[1]] or {} byItem[e[1]][id] = true end
        end
    end
    local function same(built, index)
        local n = 0
        for key, set in pairs(built) do
            local listed = {}
            for _, id in ipairs(index[key] or {}) do listed[id] = true end
            for id in pairs(set) do if not listed[id] then return false, key .. ":" .. id end end
            for id in pairs(listed) do if not set[id] then return false, key .. ":" .. id end end
            n = n + 1
        end
        for key in pairs(index) do if not built[key] then return false, "extra " .. key end end
        return n > 0, n
    end
    local okZ, whyZ = same(byZone, ns.QuestIndex.byZone)
    local okI, whyI = same(byItem, ns.QuestIndex.byItem)
    check(okZ, "the zone index lists exactly the quests of each zone (" .. tostring(whyZ) .. ")")
    check(okI, "the item index lists exactly the quests each item is for (" .. tostring(whyI) .. ")")
    check(DB:GetQuest(317) == DB:GetQuest(317), "a record read twice is decoded once")
    check(ns.DecodeRecord("{1,2}")[2] == 2, "a packed constructor decodes")
    check(ns.DecodeRecord("{") == nil, "broken packed text decodes to nothing, not an error")
    check(ns.DecodeRecord("{x=print}").x == nil and ns.DecodeRecord("(function() y = 1 end)()") == nil and rawget(_G, "y") == nil,
        "packed text sees no globals and cannot set any")
end)

-- ---- /fg wrong: feedback reports ----------------------------------------------------------
section("/fg wrong: feedback reports", function()
    ns.Commands:Run("wrong the giver is 10 yards north")
    check(ns.db.reports and #ns.db.reports == 1 and ns.db.reports[1].text == "the giver is 10 yards north" and (ns.db.reports[1].guide == (ns.Guide.active and ns.Guide.active.id) or ns.db.reports[1].mode == "auto"), "/fg wrong stores a report with guide + step")
    ns.Commands:Run("wrong")
    check(ForeverGuideReportPrompt and ForeverGuideReportPrompt:IsShown(), "/fg wrong opens feedback dialog")
    ForeverGuideReportPrompt.input:SetText("giver moved east")
    ForeverGuideReportPrompt.save:GetScript("OnClick")()
    check(not ForeverGuideReportPrompt:IsShown() and ns.db.reports[2].text == "giver moved east", "Save records dialog feedback and closes it")
    ns.Commands:Run("wrong " .. string.rep("x", 300))
    check(#ns.db.reports[3].text == 200, "report text is capped at 200 characters")
    local first = ns.db.reports[1]
    check(first.race == "Human" and first.class == "WARRIOR" and first.faction == "Alliance",
        "a report records the race, class and faction of the character that made it")
    check(ns.Reports.Export({ first }):find("| level %d+ Human WARRIOR Alliance |"),
        "the copyable report names the character after its level")
    check(ns.Reports.Export({ { t = 1, text = "old", lvl = 3 } }):find("| level 3 | ", 1, true),
        "a report saved before reports named the character exports as before")
    table.remove(ns.db.reports, 3)
    ns.Commands:Run("wrong " .. string.rep("x", 199) .. "\195\169")
    check(ns.db.reports[3].text == string.rep("x", 199), "a report capped mid-character loses the whole character")
    table.remove(ns.db.reports, 3)
    ns.Commands:Run("reports")
    check(ForeverGuideReports and ForeverGuideReports:IsShown() and ForeverGuideReports.text:GetText():find("giver moved east", 1, true)
        and ForeverGuideReports.text:GetText():find("expected map", 1, true), "/fg reports shows copyable full feedback")
    ForeverGuideReports.clear:GetScript("OnClick")()
    check(#ns.db.reports == 2, "first clear click asks for confirmation without deleting feedback")
    ForeverGuideReports.clear:GetScript("OnClick")()
    check(#ns.db.reports == 0 and ForeverGuideReports.text:GetText():find("No reports yet", 1, true),
        "confirmed clear deletes feedback and refreshes the list")
end)

-- ---- audit regressions (2026-09-20) --------------------------------------------------------
section("audit regressions (2026-09-20)", function()
    -- 1. an objective step whose wording matches no live objective must not count as done
    ns.RegisterGuide({ id = "AUDIT_OBJ", name = "audit obj", steps = {
        { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11, target = "Defias Trapper", npc = 6 },   -- npc 6 = Kobold Vermin in the DB, wording matches nothing
        { type = "TURNIN", quest = 11 } } })
    if ns.Quest:IsOnQuest(11) then MOCK_ABANDON(11); settle() end
    G:Activate("AUDIT_OBJ", true); settle()
    -- quest 11 needs a higher level than the test character has: the whole quest is deferred (guide runs past its end)
    check(G.progress.deferred[11] == 1 and cur() == 4, "a quest above the level is deferred with all its steps (cur=" .. tostring(cur()) .. " lvl=" .. tostring(ns.Player:GetLevel()) .. ")")
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 6 }, { text = "Painted Gnoll Armband", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
    check(G.progress.deferred[11] == nil and cur() == 2, "taking a deferred quest by hand brings the guide back to its objective steps, and a kill step with unmatched wording stays current at 0/6 instead of being skipped (" .. tostring(cur()) .. ")")
    MOCK_PROGRESS(11, 1, 6); settle()
    check(cur() == 3, "...and completes once the objective its index points at is finished (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(11); settle()
    -- 2. two steps at the same spot: the arrow label follows the step, and a repeated TRAVEL completes
    ns.RegisterGuide({ id = "AUDIT_NAV", name = "audit nav", steps = {
        { type = "ACCEPT", quest = 62, map = 1429, x = 40, y = 60, npc = 240 },
        { type = "TURNIN", quest = 62, map = 1429, x = 40, y = 60, npc = 240 },
        { type = "TRAVEL", map = 1429, x = 40, y = 60, text = "Go to A" },
        { type = "TRAVEL", map = 1429, x = 40, y = 60, text = "Go to A again" },
        { type = "NOTE", text = "end" } } })
    G:Activate("AUDIT_NAV", true); settle()
    MOCK_ACCEPT(62, "The Fargodeep Mine", {}); settle()
    check(cur() == 2 and ns.Navigation.target and ns.Navigation.target.label == G:GetStepText(step()), "same spot, next step: the navigation label follows the step (" .. tostring(ns.Navigation.target and ns.Navigation.target.label) .. ")")
    MOCK_TURNIN(62); settle()
    MOCK_MOVE(40, 60); ns.Navigation:Update(); settle()
    ns.Navigation:Update(); settle()
    check(cur() == 5, "two TRAVEL steps to the same spot both complete on arrival (" .. tostring(cur()) .. ")")
end)

-- ---- optional group quests ------------------------------------------------------------------
section("optional group quests", function()
    ns.RegisterGuide({ id = "AUDIT_GROUP", name = "group", steps = {
        { type = "ACCEPT", quest = 990001 },
        { type = "ACCEPT", quest = 990002, optional = true, note = "group quest" },
        { type = "KILL", quest = 990002, target = "Kobold Vermin", optional = true },
        { type = "TURNIN", quest = 990002, optional = true },
        { type = "TURNIN", quest = 990001 } } })
    if ns.Quest:IsOnQuest(990001) then MOCK_ABANDON(990001); settle() end
    G:Activate("AUDIT_GROUP", true); settle()
    MOCK_ACCEPT(990001, "Base quest", {}); settle()
    check(cur() == 5 and step().type == "TURNIN" and step().quest == 990001, "optional group quest steps are walked past when the quest is not taken (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(990002, "Group quest", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 5 } }); settle()
    check(cur() == 3 and step().quest == 990002, "taking the group quest by hand guides its objectives (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(990002); settle()
    check(cur() == 5, "dropping it walks past again (" .. tostring(cur()) .. ")")
    MOCK_TURNIN(990001); settle()
end)

-- ---- full quest log ---------------------------------------------------------------------------
section("full quest log", function()
    ns.RegisterGuide({ id = "AUDIT_FULL", name = "full log", steps = {
        { type = "ACCEPT", quest = 4010 }, { type = "TURNIN", quest = 4010 } } })
    G:Activate("AUDIT_FULL", true); settle()
    MOCK.logCap = 2
    if not ns.Quest:IsOnQuest(4011) then MOCK_ACCEPT(4011, "Spare quest A", {}) end
    if not ns.Quest:IsOnQuest(4012) then MOCK_ACCEPT(4012, "Spare quest B", {}) end
    settle()
    local n = ns.Quest:GetNumQuests()
    MOCK.logCap = n
    G:Evaluate("test")
    check(G.note and G.note:find("Quest log full", 1, true) and G.note:find("Spare quest", 1, true), "a full log on an ACCEPT step names quests the guide does not need (" .. tostring(G.note) .. ")")
    MOCK.logCap = 40
    G:Evaluate("test")
    check(not (G.note and G.note:find("Quest log full", 1, true)), "room again: the note goes away")
    MOCK_ABANDON(4011); MOCK_ABANDON(4012); settle()
end)

-- ---- corpse run ---------------------------------------------------------------------------------
-- ---- a run near its limit, full, or paused at login asks the player with a dialog --------------
-- (a long recording must not lose play: the chat line at 2,000 entries is easy to miss)
section("a run near its limit, full, or paused at login asks the player with a dialog", function()
    local R = ns.Run
    need(R ~= nil and R.NOTICE_AT ~= nil, "the recorder knows when to ask")
    local recordWas = ns.db.recordRuns
    ns.db.recordRuns = true
    ns.char.run = nil
    R:Start()
    local function fill(to) while #ns.char.run.entries < to do ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 7104, 1, 1, 2, false, "x") end end
    local function notice() return rawget(_G, "ForeverGuideRunNotice") end
    local function shown() local n = notice() return n ~= nil and n:IsShown() end

    fill(R.NOTICE_AT - 1)
    check(not shown(), "below the mark nothing interrupts play")
    fill(R.NOTICE_AT)
    check(shown() and notice().kind == "near", "near the limit a dialog asks to send the segment")
    local seg = ns.char.run.seg
    notice().send:GetScript("OnClick")(notice().send)
    local share = rawget(_G, "ForeverGuideShare")
    check(share and share:IsShown() and ns.char.run.seg == seg + 1 and R:State() == "recording" and not shown(),
        "Send now hands the segment to the share window and recording carries on in the next one")
    share:Hide()

    fill(R.NOTICE_AT)
    notice().later:GetScript("OnClick")(notice().later)
    check(not shown(), "Later closes the dialog")
    fill(R.MAX_ENTRIES + 1)
    check(R:State() == "paused" and shown() and notice().kind == "full", "a full segment pauses the run and the dialog says so")
    seg = ns.char.run.seg
    notice().send:GetScript("OnClick")(notice().send)
    check(rawget(_G, "ForeverGuideShare"):IsShown() and ns.char.run.seg == seg + 1 and R:State() == "recording",
        "Send and resume sends the full segment and records on from the same step")
    rawget(_G, "ForeverGuideShare"):Hide()

    R:Pause()
    notice():Hide()
    R:OnEnterWorld(true, false)
    check(shown() and notice().kind == "paused", "logging in to a paused run asks to resume it")
    notice().send:GetScript("OnClick")(notice().send)
    check(R:State() == "recording" and not shown(), "Resume recording resumes the run")
    R:Pause()
    R:OnEnterWorld(true, false)
    R:Resume()
    check(not shown(), "resuming from the guide window closes the dialog too")

    ns.Commands:Run("run discard")
    ns.db.recordRuns = recordWas
end)

section("record runs with ForeverGuide Companion: closed segments wait in the outbox until its receipt", function()
    local json = dofile(root .. "tools/test/json.lua")
    local R = ns.Run
    need(R ~= nil and R.Outbox ~= nil, "the run recorder keeps an outbox")
    local recordWas = ns.db.recordRuns
    local function fill(n)
        for _ = 1, n do ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 7201, 1, 1, 2, false, "x") end
    end
    local function share() return rawget(_G, "ForeverGuideShare") end
    local function hideShare() if share() then share():Hide() end end
    ns.char.run, ns.char.runSent, ns.char.runOutbox = nil, nil, nil
    hideShare()

    -- without the companion nothing changes: a full segment pauses and nothing goes to the outbox
    _G.ForeverGuideCompanionReceipt = nil
    R:SetEnabled(true)
    R:Start()
    fill(R.MAX_ENTRIES + 1)
    check(R:State() == "paused" and #R:Outbox() == 0, "without the companion a full segment pauses and waits for Send")
    if ns.UI.HideRunNotice then ns.UI:HideRunNotice() end
    ns.Commands:Run("run discard")

    -- with the companion: 2,600 entries leave a closed segment of 2,500 and recording carries on
    _G.ForeverGuideCompanionReceipt = {}
    R:Start()
    local id = ns.char.run.id
    fill(2600)
    local outbox = R:Outbox()
    need(#outbox == 1, "a full segment closes into the outbox (" .. #outbox .. " waiting)")
    local doc = outbox[1]
    check(doc.run and doc.run.id == id and doc.run.seg == 1 and #doc.run.entries == R.MAX_ENTRIES,
        "the outbox holds the closed segment, all 2,500 entries of it")
    check(R:State() == "recording" and ns.char.run.seg == 2 and #ns.char.run.entries == 2600 + 1 - R.MAX_ENTRIES,
        "recording carries on in the next segment, losing no entry")
    check(not (share() and share():IsShown()), "the companion uploads it: no share window, no dialog interrupts play")
    local said = {}
    local printWas = print
    print = function(...) said[#said + 1] = table.concat({ ... }, " ") end
    -- each entry is the segment's share document, exactly what /fg share would encode
    check(doc.format == 2 and doc.profile and doc.profile.class and doc.maps and doc.maps[MOCK.mapID] ~= nil,
        "an outbox entry is the share document: format, profile and the maps its entries stand on")
    local decoded = json.decode(ns.Share:Json(false, doc))
    check(decoded.run and decoded.run.seg == 1 and #decoded.run.entries == R.MAX_ENTRIES and decoded.quests == nil,
        "an outbox entry encodes as a run segment share, nothing else in it")

    -- Send hands the segment to the companion too; logout closes the open one
    fill(10)
    R:Send()
    check(#R:Outbox() == 2 and R:Outbox()[2].run.seg == 2 and not (share() and share():IsShown()),
        "with the companion, Send puts the segment in the outbox instead of the share window")
    print = printWas
    check(#said == 0, "and says nothing in chat: chat stays quiet (" .. tostring(said[1]) .. ")")
    fill(5)
    MOCK_FIRE("PLAYER_LOGOUT")
    outbox = R:Outbox()
    check(#outbox == 3 and outbox[3].run.seg == 3 and outbox[3].run.entries[#outbox[3].run.entries].e == "PAUSE",
        "logging out pauses the run and closes the open segment into the outbox")
    check(R:State() == "paused" and #ns.char.run.entries == 0 and ns.char.run.seg == 4,
        "the run waits paused in segment 4")
    MOCK_FIRE("PLAYER_LOGOUT")
    check(#R:Outbox() == 3, "an empty segment is not sent")

    -- the next load: SavedVariables keep the outbox, and the receipt drops what codex has
    ns.Database:Init()
    check(#R:Outbox() == 3, "SavedVariables keep the outbox across a login")
    _G.ForeverGuideCompanionReceipt = { [id .. ":1"] = true, [id .. ":3"] = true, ["someone-else:2"] = true }
    R:OnEnterWorld(true, false)
    outbox = R:Outbox()
    check(#outbox == 1 and outbox[1].run.seg == 2, "the receipt's segments leave the outbox; the others wait")
    _G.ForeverGuideCompanionReceipt = { [id .. ":2"] = true }
    R:OnEnterWorld(false, true)
    check(ns.char.runOutbox == nil, "once the receipt names them all the outbox is gone")

    -- Stop: the last segment, marked done, waits for the companion too
    R:Resume()
    fill(3)
    R:Stop()
    outbox = R:Outbox()
    check(#outbox == 1 and outbox[1].run.done == true and outbox[1].run.seg == 4 and R:State() == "idle",
        "Stop puts the last segment, marked done, in the outbox")
    -- without the companion's receipt, nothing leaves the outbox
    _G.ForeverGuideCompanionReceipt = nil
    R:OnEnterWorld(true, false)
    check(#R:Outbox() == 1, "without the receipt the outbox keeps everything")

    ns.char.runOutbox, ns.char.runSent = nil, nil
    hideShare()
    ns.db.recordRuns = recordWas
end)

section("corpse run", function()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); G:SetStep(1); settle()
    local before = ns.Navigation.target
    need(before and before.owner == "guide", "guide target before dying")
    MOCK_DIE(55.5, 66.6); settle()
    local t = ns.Navigation.target
    check(t and t.owner == "corpse" and math.abs(t.x - 55.5) < 0.01 and math.abs(t.y - 66.6) < 0.01 and t.label:find("corpse", 1, true), "dead: the target is the corpse (" .. tostring(t and t.label) .. ")")
    G:Evaluate("test"); settle()
    check(ns.Navigation.target and ns.Navigation.target.owner == "corpse", "the guide does not steal the target back while a ghost")
    MOCK_REVIVE(); settle()
    check(ns.Navigation.target and ns.Navigation.target.owner == "guide" and ns.Navigation.override == nil, "alive again: the guide's target returns (" .. tostring(ns.Navigation.target and ns.Navigation.target.owner) .. ")")
end)

-- ---- mob tooltips: live progress, only for objectives this mob actually serves ----------------
section("mob tooltips: live progress, only for objectives this mob actually serves", function()
    MOCK_ACCEPT(52, "Protect the Frontier", { { text = "Young Forest Bear slain: 2/5", finished = false, numFulfilled = 2, numRequired = 5 } }); settle()
    local lines = ns.ItemTips:MobLinesFor("Young Forest Bear")
    check(#lines == 1 and lines[1] == "2/5 Young Forest Bear slain", "hovering a kill mob shows the count, then its objective (" .. tostring(lines[1]) .. ")")
    check(#ns.ItemTips:MobLinesFor("Riverpaw Runt") == 0, "a mob not needed for a live objective gets no quest status")
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Painted Gnoll Armband: 3/8", finished = false, numFulfilled = 3, numRequired = 8 } }); settle()
    lines = ns.ItemTips:MobLinesFor("Riverpaw Runt")
    check(#lines == 1 and lines[1] == "3/8 Painted Gnoll Armband", "a count-last objective (\"Armband: 3/8\") is shown count first (" .. tostring(lines[1]) .. ")")
    MOCK_ABANDON(11); settle()
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "3/8 Painted Gnoll Armband", finished = false, numFulfilled = 3, numRequired = 8 } }); settle()
    lines = ns.ItemTips:MobLinesFor("Riverpaw Runt")
    check(#lines == 1 and lines[1] == "3/8 Painted Gnoll Armband", "a counter-first objective shows its count once, with no quest title (" .. tostring(lines[1]) .. ")")
    GameTooltip.unitName, GameTooltip.lines = "Riverpaw Runt", {}
    GameTooltip:GetScript("OnTooltipSetUnit")(GameTooltip)
    check(#GameTooltip.lines == 2 and GameTooltip.lines[2]:find("3/8", 1, true), "the unit tooltip actually receives the current quest progress")
    GameTooltip.unitName, GameTooltip.lines = "Unrelated Critter", {}
    GameTooltip:GetScript("OnTooltipSetUnit")(GameTooltip)
    check(#GameTooltip.lines == 0 and #ns.ItemTips:MobLinesFor("Unrelated Critter") == 0, "unrelated mobs have no quest lines")
    MOCK_PROGRESS(52, 1, 5); settle()
    lines = ns.ItemTips:MobLinesFor("Young Forest Bear")
    check(#lines == 1 and lines[1]:find("5/5", 1, true), "completed kills show their final count until turn-in")
    MOCK_ABANDON(52); MOCK_ABANDON(11); settle()
    check(#ns.ItemTips:MobLinesFor("Riverpaw Runt") == 0, "abandoned quests no longer show mob progress")
end)

-- ---- item tooltips ------------------------------------------------------------------------------
section("item tooltips", function()
    -- Riverpaw Gnoll Bounty (11) collects Painted Gnoll Armband (782)
    if not ns.Quest:IsOnQuest(11) then MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Painted Gnoll Armband", finished = false, numFulfilled = 3, numRequired = 8 } }); settle() end
    local lines = ns.ItemTips:LinesFor(782, "Painted Gnoll Armband")
    check(#lines >= 1 and lines[1][1]:find("Quest item: Riverpaw Gnoll Bounty (3/8)", 1, true) and lines[1][2] == "log", "an item in the log's objectives is labelled with the quest and progress (" .. tostring(lines[1] and lines[1][1]) .. ")")
    MOCK_ABANDON(11); settle()
    lines = ns.ItemTips:LinesFor(782, "Painted Gnoll Armband")
    check(#lines >= 1 and lines[1][1]:find("Quest item for: Riverpaw Gnoll Bounty", 1, true), "an item a database quest collects is labelled even before the quest is taken (" .. tostring(lines[1] and lines[1][1]) .. ")")
    -- a Forever-only wording: the live objective names the item, the database does not know it
    MOCK_ACCEPT(92, "Redridge Goulash", { { text = "Tough Condor Meat", finished = false, numFulfilled = 1, numRequired = 5 } }); settle()
    lines = ns.ItemTips:LinesFor(1080, "Tough Condor Meat")
    check(#lines >= 1 and lines[1][1]:find("Redridge Goulash (1/5)", 1, true), "an item named by a live objective is labelled from the log alone (" .. tostring(lines[1] and lines[1][1]) .. ")")
    -- turned in: the meat is left over, and the tooltip says so
    MOCK_TURNIN(92); settle()
    lines = ns.ItemTips:LinesFor(1080, "Tough Condor Meat")
    check(#lines == 1 and lines[1][2] == "leftover" and lines[1][1]:find("safe to sell", 1, true), "tooltip: no longer needed, safe to sell (" .. tostring(lines[1] and lines[1][1]) .. ")")
    do local l = ns.ItemTips:LinesFor(999999, "Broken Sword") check(#l == 0, "an ordinary item gets no line (" .. tostring(l[1] and l[1][1]) .. ")") end
end)

-- ---- a COLLECT step names the creatures that drop its item --------------------------------------
section("a COLLECT step names the creatures that drop its item", function()
    ns.RegisterGuide({ id = "AUDIT_MOBS", name = "mobs", steps = {
        { type = "ACCEPT", quest = 990700 },
        { type = "COLLECT", quest = 990700, target = "Pristine Leopard Pelt", count = 6, mobs = "Elder Snow Leopard / Snow Leopard" },
        { type = "TURNIN", quest = 990700 } } })
    G:Activate("AUDIT_MOBS", true); settle()
    MOCK_ACCEPT(990700, "Never Saddle on Quality", { { text = "Pristine Leopard Pelt: 0/6", finished = false, numFulfilled = 0, numRequired = 6 } }); settle()
    local names = ns.MobMarker:WantedNames()
    check(step().type == "COLLECT" and names["elder snow leopard"] == "Elder Snow Leopard" and names["snow leopard"] == "Snow Leopard", "a COLLECT step's mobs are the creatures the marker and target key look for")
    check(names["pristine leopard pelt"] == nil, "the item itself is not a creature to look for")
end)

-- ---- skulls over quest mobs ----------------------------------------------------------------
section("skulls over quest mobs", function()
    ns.RegisterGuide({ id = "AUDIT_SKULL", name = "skull", steps = {
        { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11, target = "Kobold Vermin", npc = 6, near = true },
        { type = "TURNIN", quest = 11 } } })
    if ns.Quest:IsOnQuest(11) then MOCK_ABANDON(11); settle() end
    G:Activate("AUDIT_SKULL", true); settle()
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
    need(cur() == 2 and step().type == "KILL", "skull test: on the kill step (cur=" .. tostring(cur()) .. " lvl=" .. tostring(ns.Player:GetLevel()) .. " deferred=" .. tostring(next(G.progress.deferred or {})) .. " note=" .. tostring(G.note) .. ")")
    local names = ns.MobMarker:WantedNames()
    ns.MobMarker:Scan()
    local macro = ForeverGuideTargetButton and ForeverGuideTargetButton:GetAttribute("macrotext") or ""
    check(macro:find("/targetexact", 1, true) ~= nil and macro:find("Kobold Vermin", 1, true) ~= nil, "the secure target button carries a /targetexact macro for the step's mobs (" .. macro:gsub("\n", " | ") .. ")")
    -- The mock cannot run macros, so this runs the macro text by the client's rules for the three
    -- commands it may use: [conditions] test the current target, the first true group runs;
    -- /targetexact finds a unit by name and (pessimistically) returns a corpse whenever there is one.
    do
        local function press(text, units, target)
            local function holds(conds)
                for c in (conds .. ","):gmatch("%s*([^,]-)%s*,") do
                    if c == "dead" and not (target and target.dead) then return false end
                    if c == "nodead" and (target and target.dead) then return false end
                    if c == "exists" and not target then return false end
                    if c == "noexists" and target then return false end
                end
                return true
            end
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local cmd, rest = line:match("^(/%a+)%s*(.-)%s*$")
                local groups, arg = {}, rest or ""
                while arg:sub(1, 1) == "[" do
                    local g, after = arg:match("^%[(.-)%]%s*(.*)$")
                    groups[#groups + 1] = g
                    arg = after
                end
                local run = #groups == 0
                for _, g in ipairs(groups) do if holds(g) then run = true break end end
                if run and cmd == "/cleartarget" then target = nil
                elseif run and cmd == "/targetexact" then
                    local pick
                    for _, u in ipairs(units) do if u.name == arg and (u.dead or not pick) then pick = u end end
                    if pick then target = pick end
                end
            end
            return target
        end
        local corpse, live = { name = "Kobold Vermin", dead = true }, { name = "Kobold Worker" }
        ns.MobMarker:UpdateTargetMacro({ ["kobold vermin"] = "Kobold Vermin", ["kobold worker"] = "Kobold Worker" })
        local text = ForeverGuideTargetButton:GetAttribute("macrotext") or ""
        check(press(text, { corpse, live }) == live, "the target key passes over a quest mob's corpse to a living quest mob (" .. text:gsub("\n", " | ") .. ")")
        local workerCorpse, liveVermin0 = { name = "Kobold Worker", dead = true }, { name = "Kobold Vermin" }
        check(press(text, { liveVermin0, workerCorpse }) == liveVermin0, "a corpse whose name comes later in the macro does not replace a living target")
        check(press(text, { corpse }) == nil, "only corpses around: the key leaves you with no target rather than a dead one")
        local liveVermin = { name = "Kobold Vermin" }
        check(press(text, { liveVermin, live }) ~= nil and not press(text, { liveVermin, live }).dead, "living quest mobs: the key targets one")
        local unrelated = { name = "Stray Cat" }
        check(press(text, { live }, unrelated) == live, "with something else targeted, the key still switches to the quest mob")
        check(press(text, { corpse, live }, live) == live, "already on a living quest mob: it stays on a living one")
        ns.MobMarker:UpdateTargetMacro({})
        check(press(ForeverGuideTargetButton:GetAttribute("macrotext") or "", { corpse, live }, unrelated) == unrelated, "no quest mobs wanted: the key leaves your target alone")
        ns.MobMarker:UpdateTargetMacro(names)
    end
    ns.MobMarker:UpdateTargetMacro({ ["young wolf"] = "Young Wolf" })   -- stale macro from an earlier step
    MOCK.inCombat = true
    ns.MobMarker:Scan()
    check((ForeverGuideTargetButton:GetAttribute("macrotext") or ""):find("Young Wolf", 1, true) ~= nil, "in combat the macro is left alone (secure attributes are locked)")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check((ForeverGuideTargetButton:GetAttribute("macrotext") or ""):find("Kobold Vermin", 1, true) ~= nil, "...and rewritten for the step once combat ends")
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, scale = 0.8, y = 500 })   -- far
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, scale = 1.0, y = 300 })   -- near
    MOCK_PLATE("nameplate3", { name = "Kobold Worker", npcID = 257, scale = 1.0, y = 320, quest = true })  -- another quest's mob
    MOCK_PLATE("nameplate4", { name = "Young Wolf", npcID = 299, scale = 1.0, y = 310 })     -- not a quest mob
    settle(); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate2", "the nearest untagged quest mob gets the big skull (" .. tostring(ns.MobMarker.primaryUnit) .. ")")
    check(ns.MobMarker.markedCount == 3, "the other quest mobs get small skulls, the wolf none (" .. tostring(ns.MobMarker.markedCount) .. ")")
    check(GetCVar("nameplateShowEnemies") == "1", "enemy nameplates were switched on for the kill step")
    SetCVar("nameplateShowEnemies", "0"); ns.MobMarker:Scan()     -- the plates key, or a loading screen
    check(GetCVar("nameplateShowEnemies") == "1" and ns.MobMarker.markedCount == 3, "plates switched off under a held kill step come back with their skulls, no reload (" .. tostring(ns.MobMarker.markedCount) .. ")")
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, scale = 1.0, y = 300, tagged = true }); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate1" and ns.MobMarker.markedCount == 2, "a tagged mob loses its skull entirely, the next one gets the big skull (" .. tostring(ns.MobMarker.primaryUnit) .. ", " .. tostring(ns.MobMarker.markedCount) .. ")")
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, scale = 0.8, y = 500, tagged = true }); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == nil and ns.MobMarker.markedCount == 1, "all wanted mobs tagged: no big skull, only the other quest's mob keeps a small one")
    -- in combat the nameplate frames cannot be measured (restricted regions): fall back to interact rings
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 25 })
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 8 })
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate2" and #reportedErrors == 0, "restricted nameplates: no error, nearest by interact distance (" .. tostring(ns.MobMarker.primaryUnit) .. ")")
    -- Protect the Frontier (52): prowlers done, bears open -> prowlers get no skull even though the client
    -- still calls them "related to an active quest"; the step's own mob keeps the big one
    if not ns.Quest:IsOnQuest(52) then
        MOCK_ACCEPT(52, "Protect the Frontier", { { text = "Prowler slain", finished = true, numFulfilled = 8, numRequired = 8 }, { text = "Young Forest Bear slain", finished = false, numFulfilled = 2, numRequired = 5 } }); settle()
    end
    MOCK_PLATE("nameplate5", { name = "Prowler", npcID = 118, scale = 1.0, y = 330, quest = true })
    MOCK_PLATE("nameplate6", { name = "Young Forest Bear", npcID = 822, scale = 1.0, y = 330, quest = true })
    ns.MobMarker:Scan()
    local fin = ns.MobMarker:FinishedNames()
    check(ns.MobMarker.markedUnits["nameplate6"] and not ns.MobMarker.markedUnits["nameplate5"], "the open objective's mob has a skull, the finished one has none")
    MOCK_PLATE("nameplate5", nil); MOCK_PLATE("nameplate6", nil); MOCK_ABANDON(52); settle()
    -- An unknown quest has no DB objective mapping: its finished live kill must still remove the skull.
    MOCK_ACCEPT(999992, "Unlisted hunt", { { text = "Unlisted Ravager slain", finished = false, numFulfilled = 0, numRequired = 1 },
        { text = "Collect a keepsake", finished = false, numFulfilled = 0, numRequired = 1 } }); settle()
    MOCK_PLATE("nameplate5", { name = "Unlisted Ravager", npcID = 999992, quest = true })
    ns.MobMarker:Scan()
    check(ns.MobMarker.markedUnits["nameplate5"], "unknown quest mob is marked while its kill objective is open")
    MOCK_PROGRESS(999992, 1, 1); settle(); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate5"], "completed unknown quest objective loses its skull while the quest stays in the log")
    MOCK_ACCEPT(999993, "Another hunt", { { text = "Unlisted Ravager slain", finished = false, numFulfilled = 0, numRequired = 2 } }); settle()
    ns.MobMarker:Scan()
    check(ns.MobMarker.markedUnits["nameplate5"], "a second quest with the same mob still open keeps its skull")
    MOCK_PLATE("nameplate5", nil); MOCK_ABANDON(999992); MOCK_ABANDON(999993); settle()
    -- The client can still call a mob quest-related after its quest is ready to turn in.
    MOCK_ACCEPT(999994, "Finished hunt", { { text = "Unlisted Ravager defeated", finished = true, numFulfilled = 1, numRequired = 1 } }); settle()
    MOCK_PLATE("nameplate5", { name = "Unlisted Ravager", npcID = 999994, quest = true })
    ns.MobMarker:Scan()
    check(ns.Quest:IsReadyForTurnIn(999994) and not ns.MobMarker.markedUnits["nameplate5"],
        "ready-to-turn-in quest mob has no small skull even if the client still calls it quest-related")
    local getStep = G.GetCurrentStep
    G.GetCurrentStep = function() return { type = "KILL", quest = 999994, target = "Unlisted Ravager" } end
    ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate5"] and ns.MobMarker.primaryUnit ~= "nameplate5",
        "ready-to-turn-in quest has no large skull even if the guide step has not advanced")
    G.GetCurrentStep = getStep
    MOCK_PLATE("nameplate5", nil); MOCK_ABANDON(999994); settle()
    -- Quests off the route. Forever writes the count first ("0/2 X slain").
    check(ns.MobMarker.MobFromText("0/8 Murloc slain") == "Murloc" and ns.MobMarker.MobFromText("Murloc slain: 3/8") == "Murloc"
        and ns.MobMarker.MobFromText("Murloc Streamrunners slain (4)") == "Murloc Streamrunners"
        and ns.MobMarker.MobFromText("0/3 Thing defeated") == "Thing" and ns.MobMarker.MobFromText("6/6 Crag Boar Rib") == nil,
        "kill wording names its mob in every format, and an item objective names none")
    local function macro() local b = rawget(_G, "ForeverGuideTargetButton") return b and b:GetAttribute("macrotext") or "" end
    G.GetCurrentStep = function() return { type = "TRAVEL", map = 1429, x = 50, y = 50, text = "walk" } end
    MOCK_ACCEPT(999995, "Count-first hunt", { { text = "0/2 Unlisted Stalker slain", type = "monster", finished = false, numFulfilled = 0, numRequired = 2 } }); settle()
    MOCK_PLATE("nameplate7", { name = "Unlisted Stalker", npcID = 999995, scale = 2.0, y = 330 })
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate7", "a quest off the route, worded count first: its mob gets the big skull while the route wants no kill ("
        .. tostring(ns.MobMarker.primaryUnit) .. ")")
    check(macro():find("Unlisted Stalker", 1, true) ~= nil, "...and the target key targets it (" .. macro():gsub("\n", " | ") .. ")")
    MOCK.log[999995].objectives[1].text = "2/2 Unlisted Stalker slain"; MOCK_PROGRESS(999995, 1, 2); settle(); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate7"], "its objective done: the skull goes")
    MOCK_PLATE("nameplate7", nil); MOCK_ABANDON(999995); settle()
    -- a route kill step keeps the big skull; the off-route mob stays small
    G.GetCurrentStep = function() return { type = "KILL", quest = 999996, target = "Route Boar" } end
    MOCK_ACCEPT(999996, "Route hunt", { { text = "0/4 Route Boar slain", type = "monster", finished = false, numFulfilled = 0, numRequired = 4 } })
    MOCK_ACCEPT(999997, "Side hunt", { { text = "0/4 Side Wolf slain", type = "monster", finished = false, numFulfilled = 0, numRequired = 4 } }); settle()
    MOCK_PLATE("nameplate7", { name = "Route Boar", npcID = 999996, scale = 1.0, y = 330 })
    MOCK_PLATE("nameplate8", { name = "Side Wolf", npcID = 999997, scale = 2.0, y = 330 })
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate7" and ns.MobMarker.markedUnits["nameplate8"] == "other",
        "during a route kill step its mob keeps the big skull and the side quest's mob gets a small one")
    check(macro():find("Route Boar", 1, true) ~= nil and not macro():find("Side Wolf", 1, true), "...and the target key stays on the route's mob")
    MOCK_PLATE("nameplate7", nil); MOCK_PLATE("nameplate8", nil); MOCK_ABANDON(999996); MOCK_ABANDON(999997); settle()
    -- a loot objective nothing names: the mob's own tooltip says it is for your open objective
    G.GetCurrentStep = function() return { type = "TRAVEL", map = 1429, x = 50, y = 50, text = "walk" } end
    local function tip(done, player)
        local lines = { { type = 17, leftText = "Gem hunt" } }
        if player then lines[#lines + 1] = { type = 18, leftText = player } end
        lines[#lines + 1] = { type = 8, leftText = (done and "4/4" or "0/4") .. " Strange Gem", completed = done }
        return lines
    end
    MOCK_ACCEPT(999998, "Gem hunt", { { text = "0/4 Strange Gem", type = "item", finished = false, numFulfilled = 0, numRequired = 4 } }); settle()
    MOCK_PLATE("nameplate7", { name = "Gem Hoarder", npcID = 999998, scale = 2.0, y = 330, quest = true, tooltip = tip(false) })
    MOCK_PLATE("nameplate8", { name = "Plain Hoarder", npcID = 999999, scale = 2.0, y = 330, quest = true })
    MOCK_PLATE("nameplate9", { name = "Party Hoarder", npcID = 999990, scale = 2.0, y = 330, tooltip = tip(false, "Partymate") })
    ns.MobMarker:Scan()
    check(ns.MobMarker.markedUnits["nameplate7"] and ns.MobMarker.primaryUnit == "nameplate7",
        "an unnamed loot objective: the mob whose tooltip lists it open gets the big skull")
    check(not ns.MobMarker.markedUnits["nameplate8"], "the client's quest-related flag alone marks nothing")
    check(ns.MobMarker.Cfg().party == nil, "party skulls have no saved setting yet")
    check(ns.MobMarker.markedUnits["nameplate9"] == "party" and ns.MobMarker.primaryUnit == "nameplate7",
        "party skulls are on by default: a party member's objective marks its mob with a small party skull, never the big one ("
        .. tostring(ns.MobMarker.markedUnits["nameplate9"]) .. ")")
    MOCK.plates.nameplate7.tooltip[#MOCK.plates.nameplate7.tooltip + 1] = { type = 18, leftText = "Partymate" }
    MOCK.plates.nameplate7.tooltip[#MOCK.plates.nameplate7.tooltip + 1] = { type = 8, leftText = "1/4 Strange Gem", completed = false }
    ns.MobMarker:ForgetTooltips(); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate7", "a mob both of you need keeps your own big skull")
    -- the party member finishes their objective: your log does not change, the blue skull still goes
    MOCK.plates.nameplate9.tooltip = { { type = 17, leftText = "Gem hunt" }, { type = 18, leftText = "Partymate" },
        { type = 8, leftText = "4/4 Strange Gem", completed = true } }
    ns.MobMarker:Scan()
    check(ns.MobMarker.markedUnits["nameplate9"] == "party", "precondition: just after, the cached answer still stands")
    MOCK_ADVANCE(4); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate9"], "a party member's objective done: the blue skull clears within seconds, without your log changing")
    MOCK.plates.nameplate9.tooltip = tip(false, "Partymate")
    ns.MobMarker:ForgetTooltips(); ns.MobMarker:Scan()
    need(ns.MobMarker.markedUnits["nameplate9"] == "party", "the party member's objective open again: blue skull back")
    MOCK.plates.nameplate9.tooltip = {}
    MOCK_FIRE("UNIT_QUEST_LOG_CHANGED", "party1"); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate9"], "the party member's quest log changing (turned in) clears the blue skull at once")
    MOCK.plates.nameplate9.tooltip = tip(false, "Partymate")
    ns.MobMarker:ForgetTooltips()
    ns.Commands:Run("skull party off"); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate9"], "/fg skull party off takes the party skulls away")
    ns.Commands:Run("skull party on")
    MOCK.plates.nameplate7.tooltip = tip(false)
    MOCK.plates.nameplate7.tooltip = tip(true)
    MOCK.log[999998].objectives[1].text = "4/4 Strange Gem"; MOCK_PROGRESS(999998, 1, 4); settle(); ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate7"], "the objective done: the tooltip lists it completed and the skull goes")
    MOCK_PLATE("nameplate7", nil); MOCK_PLATE("nameplate8", nil); MOCK_PLATE("nameplate9", nil); MOCK_ABANDON(999998); settle()
    -- the tooltip also overrules a name: a mob whose tooltip shows only completed objectives has none left
    MOCK_ACCEPT(999997, "Side hunt", { { text = "0/4 Side Wolf slain", type = "monster", finished = false, numFulfilled = 0, numRequired = 4 } }); settle()
    MOCK_PLATE("nameplate8", { name = "Side Wolf", npcID = 999997, scale = 2.0, y = 330,
        tooltip = { { type = 17, leftText = "Other hunt" }, { type = 8, leftText = "4/4 Side Wolf slain", completed = true } } })
    ns.MobMarker:Scan()
    check(not ns.MobMarker.markedUnits["nameplate8"], "a mob whose tooltip lists only completed objectives gets no skull, whatever its name")
    MOCK_PLATE("nameplate8", nil); MOCK_ABANDON(999997); settle()
    G.GetCurrentStep = getStep
    ns.Commands:Run("skull off"); ns.MobMarker:Scan()
    check(ns.MobMarker.markedCount == 0 and GetCVar("nameplateShowEnemies") == "0", "/fg skull off removes the skulls and restores the nameplate setting")
    ns.Commands:Run("skull on")
    MOCK_ABANDON(11); settle()
    -- plates also stay while any quest in the log has an open kill or loot objective: drop those first
    do
        local drop = {}
        for _, qid in ipairs(ns.Quest.order) do
            for _, o in ipairs(ns.Quest:GetObjectives(qid) or {}) do
                if not o.finished then
                    local copy = {}
                    for i, oo in ipairs(ns.Quest:GetObjectives(qid)) do copy[i] = { text = oo.text, finished = oo.finished, numFulfilled = oo.numFulfilled, numRequired = oo.numRequired } end
                    drop[#drop + 1] = { id = qid, title = ns.Quest:GetTitle(qid), objs = copy }
                    break
                end
            end
        end
        for _, q in ipairs(drop) do MOCK_ABANDON(q.id) end
        settle()
        ns.MobMarker:Scan()
        local openKills = ns.MobMarker:OpenKillNames()
        check(GetCVar("nameplateShowEnemies") == "0", "leaving the kill step restores enemy nameplates (step=" .. tostring(step() and step().type) .. " cvar=" .. tostring(GetCVar("nameplateShowEnemies")) .. ")")
        for _, q in ipairs(drop) do MOCK_ACCEPT(q.id, q.title, q.objs) end
        settle()
    end
    for i = 1, 4 do MOCK_PLATE("nameplate" .. i, nil) end
end)

-- ---- the target key on TUGs' steps: no target field, the quest names the mob -----------------
section("the target key takes the mob a COMPLETE step's own kill objective names", function()
    -- TUGs' steps name no target. Here the database knows only "Kobold", a name the live objective
    -- merely contains, and /targetexact on it finds no "Kobold Vermin".
    ns.NpcDB[990911] = { n = "Kobold" }
    ns.QuestDB[990910] = { n = "Vermin Cull", kill = { { 990911 } } }
    ns.RegisterGuide({ id = "AUDIT_TARGET_TEXT", name = "target text", steps = {
        { type = "ACCEPT", quest = 990910 },
        { type = "COMPLETE", quest = 990910 },
        { type = "TURNIN", quest = 990910 },
        { type = "ACCEPT", quest = 990912 },     -- a Forever quest the database does not know
        { type = "COMPLETE", quest = 990912, objective = 2 },
        { type = "TURNIN", quest = 990912 } } })
    G:Activate("AUDIT_TARGET_TEXT", true); settle()
    local function macro() return (ForeverGuideTargetButton:GetAttribute("macrotext") or "") .. "\n" end
    local function targets(name) return macro():find("/targetexact [noexists][dead] " .. name .. "\n", 1, true) ~= nil end

    MOCK_ACCEPT(990910, "Vermin Cull", { { text = "0/8 Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
    need(step().type == "COMPLETE" and step().quest == 990910, "target text: on the kill step (cur=" .. tostring(cur()) .. ")")
    ns.MobMarker:Scan()
    check(targets("Kobold Vermin"), "the key targets the mob by the name the objective gives (" .. macro():gsub("\n", " | ") .. ")")

    MOCK_ACCEPT(990912, "Forever Quest", {
        { text = "0/1 Ancient Relic", finished = false, numFulfilled = 0, numRequired = 1 },
        { text = "0/6 Murloc Forager slain", finished = false, numFulfilled = 0, numRequired = 6 } }); settle()
    G:SetStep(5); settle(); ns.MobMarker:Scan()
    need(step().quest == 990912, "target text: on the Forever quest's step (cur=" .. tostring(cur()) .. ")")
    check(targets("Murloc Forager"), "a quest the database does not know: the step's objective names the mob (" .. macro():gsub("\n", " | ") .. ")")
    check(not macro():find("Kobold", 1, true), "...and only the step's mob, not another quest's in the log (" .. macro():gsub("\n", " | ") .. ")")
    local said, realPrint = {}, ns.Print
    ns.Print = function(msg) said[#said + 1] = tostring(msg) end
    ns.Commands:Run("skull debug")
    ns.Print = realPrint
    local shown = table.concat(said, "\n")
    check(shown:find("quest=990912 objective=2", 1, true) and shown:find("0/6 Murloc Forager slain", 1, true)
        and shown:find("target key: /cleartarget | /targetexact [noexists][dead] Murloc Forager", 1, true),
        "/fg skull debug shows the step, its objectives and the key's macro (" .. shown .. ")")
    MOCK_PROGRESS(990912, 2, 6); settle(); ns.MobMarker:Scan()
    check(not targets("Murloc Forager"), "the objective is done: its mob leaves the key (" .. macro():gsub("\n", " | ") .. ")")

    for _, q in ipairs({ 990910, 990912 }) do if ns.Quest:IsOnQuest(q) then MOCK_ABANDON(q) end end
    settle()
    ns.QuestDB[990910], ns.NpcDB[990911] = nil, nil
end)

-- ---- combat lockdown: nameplate cvars are protected, must never be touched mid-fight -------
-- (Ilya, 2026-09-24: live "Interface action failed because of an AddOn" - forcePlates() called
-- SetCVar unconditionally, and Scan() retries every 0.5s while a kill step is current, so it kept
-- retrying - and kept getting denied - for the whole fight it fired in.)
section("combat lockdown: nameplate cvars are protected, must never be touched mid-fight", function()
    ns.RegisterGuide({ id = "AUDIT_COMBAT_PLATES", name = "combat plates", steps = {
        { type = "ACCEPT", quest = 990010 },
        { type = "KILL", quest = 990010, target = "Test Grunt", npc = 990010, near = true },
        { type = "TURNIN", quest = 990010 } } })
    -- other quests elsewhere in the log may already have open kill objectives by this point in the
    -- suite, so get a genuinely clean baseline by disabling (which unconditionally releases any
    -- forced cvar - confirmed a reliable reset) and re-enabling without a Scan() in between, rather
    -- than assuming nothing else in the log wants plates on.
    MOCK.inCombat = false
    MOCK_ABANDON(990010); settle()
    ns.MobMarker:SetEnabled(false); settle()
    need(GetCVar("nameplateShowEnemies") == "0", "clean baseline: nothing forcing nameplates on")
    ns.MobMarker.Cfg().enabled = true
    -- enter combat BEFORE touching the guide/quest log, so every Scan() this triggers - from
    -- G:Activate, from accepting the quest, from the ticker - runs while already in combat, same
    -- as a kill step appearing mid-fight for real.
    MOCK.inCombat = true
    G:Activate("AUDIT_COMBAT_PLATES", true); settle()
    check(GetCVar("nameplateShowEnemies") == "0", "activating the guide mid-combat does not touch the cvar")
    MOCK_ACCEPT(990010, "Test Grunt Bounty", { { text = "Test Grunt slain", finished = false, numFulfilled = 0, numRequired = 5 } }); settle()
    need(cur() == 2 and step().type == "KILL", "on the kill step, started while already in combat")
    check(GetCVar("nameplateShowEnemies") == "0", "a kill step starting mid-combat does not touch the protected cvar")
    ns.MobMarker:Scan(); ns.MobMarker:Scan()   -- the 0.5s ticker would otherwise retry every tick all fight
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(GetCVar("nameplateShowEnemies") == "1", "nameplates switch on once combat ends and Scan() re-runs")
    MOCK.inCombat = true
    ns.MobMarker:Scan()
    MOCK.inCombat = false
    MOCK_ABANDON(990010); settle()
end)

-- ---- a stray Forever position must not pull a giver step away from its own spot ---------
section("a stray Forever position must not pull a giver step away from its own spot", function()
    -- Tundra MacGrann (1266): four Forever points at the giver, one stray far off. A player standing
    -- by the stray one was sent there instead of to the step's giver.
    ns.NpcDB[990501] = { n = "Stray Giver", spm = { [1429] = { { 34.6, 51.7 }, { 34.7, 51.6 }, { 43.0, 47.4 } } } }
    local step = { type = "ACCEPT", quest = 990501, npc = 990501, map = 1429, zone = "Elwynn Forest", x = 34.6, y = 51.7 }
    MOCK_MOVE(43.5, 47.4)
    local map, x, y = ns.Navigation:ResolveStep(step)
    check(map == 1429 and math.abs(x - 34.6) < 0.2 and math.abs(y - 51.7) < 0.2, "a giver step keeps the Forever point at its own spot, not the one nearest the player (" .. tostring(x) .. "," .. tostring(y) .. ")")
    local bare = { type = "ACCEPT", quest = 990501, npc = 990501 }
    local _, bx, by = ns.Navigation:ResolveStep(bare)
    check(math.abs(bx - 43.0) < 0.2 and math.abs(by - 47.4) < 0.2, "a giver step without coordinates still takes the Forever point nearest the player")
    -- boundary: the spot's nearest spawn is chosen by distance, not by its place in the list
    ns.NpcDB[990502] = { n = "Two Spawns", spm = { [1429] = { { 43.0, 47.4 }, { 34.7, 51.6 } } } }
    local _, cx, cy = ns.Navigation:ResolveStep({ type = "ACCEPT", quest = 990502, npc = 990502, map = 1429, x = 34.6, y = 51.7 })
    check(math.abs(cx - 34.7) < 0.2 and math.abs(cy - 51.6) < 0.2, "the spawn nearest the step's spot wins even when listed last (" .. tostring(cx) .. "," .. tostring(cy) .. ")")
    ns.NpcDB[990501], ns.NpcDB[990502] = nil, nil
end)

-- ---- distances: yards, abbreviated from a thousand on, like the game's own waypoint --------
section("distances: yards, abbreviated from a thousand on, like the game's own waypoint", function()
    local N = ns.Navigation
    local got = { N:FormatDistance(85), N:FormatDistance(999.4), N:FormatDistance(999.6), N:FormatDistance(1500), N:FormatDistance(2000), N:FormatDistance(12345) }
    local want = { "85 yd", "999 yd", "1k yd", "1.5k yd", "2k yd", "12.3k yd" }
    check(table.concat(got, "|") == table.concat(want, "|"), "distances read in yards, 1.5k yd past a thousand (" .. table.concat(got, "|") .. ")")
    check(N:FormatDistance(nil) == "?", "an unknown distance is ?")
end)

-- ---- Blizzard's quest map pin is the primary target of an objective step ----------------
section("Blizzard's quest map pin is the primary target of an objective step", function()
    -- the world map's numbered pin marks where the client wants the player to go for a quest in
    -- the log; our spawn data (vanilla-era, or none for new Forever quests) only fills in
    ns.NpcDB[990601] = { n = "Pin Wolf", spm = { [1429] = { { 40.0, 60.0 } } } }
    MOCK_ACCEPT(990601, "Pin Test", { { text = "Pin Wolf slain: 0/5", finished = false, numFulfilled = 0, numRequired = 5 } })
    settle()
    MOCK_MOVE(41.0, 60.0)
    local step = { type = "KILL", quest = 990601, npc = 990601, target = "Pin Wolf", map = 1429, x = 45.0, y = 50.0 }
    local _, sx, sy = ns.Navigation:ResolveStep(step)
    local fallbackX, fallbackY = sx, sy

    MOCK.questPins = { [1429] = { { questID = 990601, x = 0.70, y = 0.20 } } }
    local map, x, y, _, loc = ns.Navigation:ResolveStep(step)
    check(map == 1429 and x and math.abs(x - 70) < 0.01 and math.abs(y - 20) < 0.01, "a pin on the current map beats spawns and the step's spot (" .. tostring(x) .. "," .. tostring(y) .. ")")

    MOCK.questPins = { [1429] = { { questID = 990602, x = 0.70, y = 0.20 }, { questID = 990601, x = nil, y = 0.20 } } }
    local _, ox, oy = ns.Navigation:ResolveStep(step)
    check(ox == fallbackX and oy == fallbackY, "another quest's pin and a pin without x are ignored (" .. tostring(ox) .. "," .. tostring(oy) .. ")")

    MOCK.questPins = { [1426] = { { questID = 990601, x = 0.30, y = 0.40 } } }
    local away = { type = "KILL", quest = 990601, npc = 990601, map = 1426, x = 50.0, y = 50.0 }
    local amap, ax, ay = ns.Navigation:ResolveStep(away)
    check(amap == 1426 and ax and math.abs(ax - 30) < 0.01 and math.abs(ay - 40) < 0.01, "the pin on the step's own map when the player is elsewhere (" .. tostring(amap) .. " " .. tostring(ax) .. "," .. tostring(ay) .. ")")

    MOCK.questPins = { [1429] = { { questID = 990601, x = 0.70, y = 0.20 } } }
    local accept = { type = "ACCEPT", quest = 990601, npc = 990601, map = 1429, x = 45.0, y = 50.0 }
    local _, cx = ns.Navigation:ResolveStep(accept)
    check(cx ~= 70, "a giver step does not follow the objective pin (" .. tostring(cx) .. ")")
    local edited = { type = "KILL", quest = 990601, npc = 990601, map = 1429, x = 12.0, y = 13.0, edited = true }
    local _, ex, ey = ns.Navigation:ResolveStep(edited)
    check(ex == 12.0 and ey == 13.0, "an in-game edit still beats the pin (" .. tostring(ex) .. "," .. tostring(ey) .. ")")

    -- auto mode follows the same pin, even for a quest the database does not know
    local entry = ns.Quest.log[990601]
    local best = entry and ns.Tracker:BestForQuest(entry)
    check(best and best.loc.map == 1429 and math.abs(best.loc.x - 70) < 0.01 and math.abs(best.loc.y - 20) < 0.01, "the tracker aims at the pin too (" .. tostring(best and best.loc.x) .. ")")
    MOCK.questPins = nil
    check(entry and ns.Tracker:BestForQuest(entry) == nil, "no pin and no database entry: the tracker has nothing for the quest")
    MOCK.questPins = { [1429] = { { questID = 990601, x = 0.70, y = 0.20 } } }

    MOCK_ABANDON(990601); settle()
    local _, nx = ns.Navigation:ResolveStep(step)
    check(nx ~= 70, "quest not in the log: its pin is not used (" .. tostring(nx) .. ")")
    MOCK.questPins = nil
    ns.NpcDB[990601] = nil
end)

-- ---- editor + resync -------------------------------------------------------------------
section("editor + resync", function()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); G:SetStep(1); settle()
    local step = G:GetCurrentStep()
    MOCK_MOVE(33.3, 44.4)
    ns.Commands:Run("edit here")
    local map, x, y = ns.Navigation:ResolveStep(step)
    check(map == 1429 and math.abs(x - 33.3) < 0.01 and math.abs(y - 44.4) < 0.01, "/fg edit here overrides the step location (" .. tostring(x) .. "," .. tostring(y) .. ")")
    ns.Commands:Run("edit note test note")
    check(ns.Editor:Effective(step).note == "test note", "/fg edit note sets the note")
    do
        ns.Commands:Run("edit clear")
        local near
        for _, s in ipairs(G.active.steps) do if s.near and not G:IsStepDone(s, s.index) then near = s break end end
        G:SetStep(near.index); settle()
        near = G:GetCurrentStep()   -- Evaluate may have moved on; the note lands on the current step
        need(near and near.near == true, "the nearest-spawn step is current (" .. tostring(near and near.index) .. ")")
        local m0, x0, y0 = ns.Navigation:ResolveStep(near)
        ns.Commands:Run("edit note just a note")
        local m1, x1, y1 = ns.Navigation:ResolveStep(near)
        check(m0 == m1 and x0 == x1 and y0 == y1, string.format("a note-only edit does not move a nearest-spawn step (%s,%s -> %s,%s)", tostring(x0), tostring(y0), tostring(x1), tostring(y1)))
        ns.Commands:Run("edit clear")
        G:SetStep(1); settle()
        MOCK_MOVE(33.3, 44.4)
        ns.Commands:Run("edit here")
        ns.Commands:Run("edit note test note")
    end
    do
        -- a near step goes to a spawn around its own spot, not the nearest one anywhere in the zone
        local spawn = ns.DB:NPCLocations(6)[1]
        local far = { type = "KILL", quest = 11, target = "Kobold Vermin", npc = 6, near = true, map = spawn.map, x = spawn.x > 50 and spawn.x - 40 or spawn.x + 40, y = spawn.y }
        local _, fx, fy = ns.Navigation:ResolveStep(far)
        check(fx == far.x and fy == far.y, string.format("no spawn around a near step's spot: its own spot (%s,%s)", tostring(fx), tostring(fy)))
        local close = { type = "KILL", quest = 11, target = "Kobold Vermin", npc = 6, near = true, map = spawn.map, x = spawn.x + 1, y = spawn.y }
        local _, cx = ns.Navigation:ResolveStep(close)
        check(cx ~= close.x, "spawns around the spot: the nearest of them (" .. tostring(cx) .. ")")
    end
    ns.Commands:Run("edits")
    ns.Commands:Run("edit clear")
    local map2, x2 = ns.Navigation:ResolveStep(step)
    check(not (map2 == 1429 and x2 and math.abs(x2 - 33.3) < 0.01), "/fg edit clear restores the original location")
    -- resync: a level-20 character skips out-levelled quests
    MOCK_LEVEL(20); settle()
    local n = G:Resync(); settle()
    check(n >= 5, "resync skipped the out-levelled quests (" .. n .. ")")
    -- auto-pick prefers the race's natural chain / same continent over a far zone of the same level
    MOCK_LEVEL(11); settle()
    local pick = G:AutoPick()
    check(pick and (pick.id:find("^GEN_ALLIANCE_HUMAN_0[12]_") ~= nil), "level-11 human in Elwynn auto-picks the Human route's chapter 1 or 2, not another race's chapter (" .. tostring(pick and pick.id) .. ")")
    MOCK_LEVEL(5); settle()
    G:Reset(); settle()
end)

-- ---- the Quest Guide window: rows, header, states, settings, waypoint fallback ----------
section("the Quest Guide window: rows, header, states, settings, waypoint fallback", function()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true)
    -- a step this character follows and has not done, with a done step before it and an undone one
    -- soon after: placed class steps come and go, and earlier tests have finished much of Northshire
    local steps = G.active.steps
    local function open(k) return steps[k] and G:StepApplies(steps[k]) and not steps[k].optional and not G:IsStepDone(steps[k], k) end
    local start = 5
    while steps[start] do
        local doneBefore, openAfter = false, false
        for k = 1, start - 1 do if G:StepApplies(steps[k]) and G:IsStepDone(steps[k], k) then doneBefore = true end end
        for k = start + 1, start + 4 do if open(k) then openAfter = true end end
        if open(start) and doneBefore and openAfter then break end
        start = start + 1
    end
    G:SetStep(start); settle()
    ns.Tracker:SetMode("guide"); settle()
    ns.UI:Show(); settle()
    local f = ForeverGuideFrame
    -- the distance column: a row in view says how far its step is, and follows the player
    do
        local px, py = MOCK.mapX, MOCK.mapY
        f.list:UpdateDistances(true)
        local row
        for i = f.list.first or 1, f.list.last or 0 do
            local e = f.list.entries[i]
            if e and e.step and e.state ~= "active" then row = f.list:RowFor(i) break end
        end
        need(row ~= nil, "a step other than the current one is in view")
        local d1 = row.dist:GetText()
        check(type(d1) == "string" and d1:find("yd", 1, true) ~= nil, "a row in view shows its step's distance (" .. tostring(d1) .. ")")
        MOCK_MOVE(95, 95); f.list:UpdateDistances(true)
        local d2 = row.dist:GetText()
        check(d2 ~= d1, "...and it follows the player (" .. tostring(d1) .. " -> " .. tostring(d2) .. ")")
        ns.Commands:Run("qg distances off"); f.list:UpdateDistances(true)
        check((row.dist:GetText() or "") == "", "distances off clears the column")
        ns.Commands:Run("qg distances on")
        MOCK.mapX, MOCK.mapY = px, py
    end
    local shownRows, activeRows, activeIdx = 0, 0, nil
    for i, e in ipairs(f.list.entries) do
        shownRows = shownRows + 1
        if e.state == "active" then activeRows = activeRows + 1 activeIdx = e.index end
    end
    local applicable = 0
    for _, st in ipairs(G.active.steps) do if G:StepApplies(st) then applicable = applicable + 1 end end
    check(shownRows == applicable, "the list holds the whole guide, to scroll through (" .. shownRows .. " of " .. applicable .. ")")
    -- the window keeps its own height and scrolls; a refresh does not yank the list back while you read ahead
    f.scroll:SetVerticalScroll(0)
    ns.UI:Refresh(); settle()
    -- the scroll bar: shows where the view is in the guide, and where the current step is
    local bar = f.scrollBar
    check(bar and bar:IsShown(), "a long list gets a scroll bar")
    if bar then
        ns.QuestGuide:ScrollToFraction(1)
        check(math.abs(bar.thumbOffset - (bar.trackHeight - bar.thumbHeight)) < 0.5, "scrolled to the end: the thumb sits at the bottom")
        check(f.scroll:GetVerticalScroll() > 0, "and the list moved with it")
        ns.QuestGuide:ScrollToFraction(0)
        check(bar.thumbOffset == 0 and f.scroll:GetVerticalScroll() == 0, "and back to the top")
    end
    check(activeRows == 1 and activeIdx == G.current, "exactly one row is the active step and it is the current one")
    check(f.header.count:GetText():find("^%d+ / %d+$") ~= nil, "header shows current / total (" .. tostring(f.header.count:GetText()) .. ")")
    local e1 = f.list.entries[1]
    check(e1.title and e1.title ~= "" and e1.number, "rows carry a title and a step number")
    local hasDone = false
    for _, e in ipairs(f.list.entries) do if e.state == "done" then hasDone = true end end
    check(hasDone, "a completed step stays visible above the current one")
    -- clicking a row jumps to that step; a turn-in whose quest is not picked up yet lands on its accept
    local target
    for _, e in ipairs(f.list.entries) do if e.state == "available" then target = e break end end
    need(target ~= nil, "the list offers a step to jump to")
    if target then
        local st = G.active.steps[target.index]
        local expected = target.index
        if st.type == "TURNIN" and not ns.Quest:IsOnQuest(st.quest) then
            for k = target.index - 1, 1, -1 do
                local s2 = G.active.steps[k]
                if s2.type == "ACCEPT" and s2.quest == st.quest then expected = k break end
            end
        end
        f.list.rows[1].entry = target
        f.list.rows[1]:GetScript("OnClick")(f.list.rows[1], "LeftButton"); settle()
        check(G.current == expected, "clicking a row jumps to that step (" .. tostring(G.current) .. " vs " .. tostring(expected) .. ")")
    end
    -- width grip: drag to resize, persist the new width, and reflow the list
    check(f.resizeGrip ~= nil and f.resizable == true, "guide has a resize grip")
    if f.resizeGrip then
        f.resizeGrip:GetScript("OnMouseDown")(f.resizeGrip)
        check(f.sizing == true, "resize grip starts sizing the guide")
        f:GetScript("OnSizeChanged")(f, 400, 200)
        local wideList, lowFooter = f.list:GetWidth(), f.footerLine.points[1][5]
        f:SetWidth(360)
        f:SetHeight(160)
        f:GetScript("OnSizeChanged")(f, 360, 160)
        check(wideList - f.list:GetWidth() == 40 and f.footerLine.points[1][5] - lowFooter == 40,
            "quest list and footer follow the resize while the mouse is still down")
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
        check(ns.db.ui.width == 360 and f.sizing == false, "resize saves guide width")
        check(ns.db.ui.height == 160 and f:GetHeight() == 160 and f.scroll and f.scroll:GetScrollChild() == f.list,
            "resize saves height and clips the quest list to a scroll viewport")
        check(f.list:GetWidth() > 0 and f.list:GetWidth() < f:GetWidth() and f.list:GetHeight() > 0,
            "scroll child has a real width and height so quest text renders")
        f.scroll:SetVerticalScroll(0)
        -- jump to an accept further down: the list follows the new current step
        local target
        for _, e in ipairs(f.list.entries) do
            if e.number > G:PosOf(G.current) + 5 and e.step.type == "ACCEPT" and e.state ~= "done" then target = e.index break end
        end
        local beforeStep = G.current
        G:SetStep(target); settle()
        need(G.current ~= beforeStep, "the jump changed the current step (" .. tostring(beforeStep) .. " -> " .. tostring(G.current) .. ")")
        check(f.scroll:GetVerticalScroll() > 0, "a new current step far down the list scrolls the list to it (" .. f.scroll:GetVerticalScroll() .. ")")
        f:SetHeight(520)
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
        f:SetHeight(160)
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
    end
    -- settings
    ns.Commands:Run("qg opacity 0.7")
    ns.Commands:Run("qg rows 4"); settle()
    ns.UI:Refresh(); settle()
    local fourRows = f:GetHeight()
    ns.Commands:Run("qg rows 7"); ns.UI:Refresh(); settle()
    check(fourRows < f:GetHeight(), "/fg qg rows sets how many rows the window shows (" .. fourRows .. " < " .. f:GetHeight() .. ")")
    ns.Commands:Run("qg rows 7"); ns.UI:Refresh(); settle()
    local tall = f.list.rows[1]:GetHeight()
    ns.Commands:Run("qg subtitles off"); ns.UI:Refresh(); settle()
    check(f.list.rows[1]:GetHeight() < tall, "subtitles off makes shorter rows (" .. f.list.rows[1]:GetHeight() .. " vs " .. tall .. ")")
    ns.Commands:Run("qg subtitles on"); ns.UI:Refresh(); settle()
    ns.Commands:Run("qg completed off"); ns.UI:Refresh(); settle()
    local anyDone = false
    for _, e in ipairs(f.list.entries) do if e.state == "done" then anyDone = true end end
    check(not anyDone, "completed rows hidden when the option is off")
    ns.Commands:Run("qg completed on"); ns.UI:Refresh(); settle()
    -- the Guide info popup
    ns.QuestGuide:ToggleInfo(); settle()
    check(ForeverGuideInfo and ForeverGuideInfo:IsShown() and (ForeverGuideInfo.body:GetText() or ""):find("Step") ~= nil, "the Guide button opens the info popup with the current step")
    ns.QuestGuide:ToggleInfo(); settle()
    -- The chevron is the default; opt into the map pin to exercise its behavior.
    ns.Commands:Run("waypoint on")
    ns.Navigation:SetTarget({ map = 1429, x = 40, y = 60, label = "Hilary's Necklace", owner = "test" }); settle()
    ns.Waypoint:Tick()
    check(ns.Navigation.ownsWaypoint and MOCK.superTrack == true, "a target sets the engine's user waypoint and super-tracks it")
    check(not ns.Waypoint.overlay:IsShown(), "by default the diamond stays off and the chevron is the indicator (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    check(ns.Arrow:IsShown(), "the chevron is visible by default")
    ns.Commands:Run("waypoint engine on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.engine == true and ns.Waypoint.mode == "engine", "/fg waypoint engine on rides the client's pin (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    check(ns.Waypoint.overlay:IsShown(), "the world waypoint overlay shows on the engine pin")
    check(ns.Waypoint.overlay.name:GetText() == "Hilary's Necklace", "the overlay carries the quest name")
    check(SuperTrackedFrame.Icon.alpha == 0, "the engine pin's own icon is faded out under our diamond")
    check(not ns.Arrow:IsShown(), "the chevron arrow steps aside while the world pin shows")
    -- the engine cannot project the pin after all (Forever: NavigationState Invalid, frame
    -- faded): even with engine mode on, the diamond does NOT fall back to a guessed screen
    -- position any more (that guess is what felt sluggish) - it simply steps aside for the chevron
    MOCK.superTrack = false; ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow.suppressedByWaypoint == false, "engine pin unusable: no guessed fallback - the chevron takes over (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    MOCK.superTrack = true; ns.Waypoint:Tick()
    check(ns.Waypoint.overlay:IsShown() and ns.Waypoint.mode == "engine", "engine pin usable again: the diamond is back")
    ns.Commands:Run("waypoint off"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == false and not ns.Waypoint.overlay:IsShown(), "/fg waypoint off hides the overlay")
    check(SuperTrackedFrame.Icon.alpha == 1, "the engine pin's own art is restored when the waypoint is off")
    check(ns.Arrow.suppressedByWaypoint == false, "the chevron arrow is back when the waypoint is off")
    ns.Commands:Run("waypoint on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == true and ns.db.nav.blizzardWaypoint == true and ns.Waypoint.overlay:IsShown(), "/fg waypoint on brings the overlay back (engine mode is still on from above)")
    -- Map stays behind the guide even with a saved legacy hideOnMap setting.
    ns.db.ui.hideOnMap = true
    MOCK.mapOpen = true; WorldMapFrame.hooks.OnShow(); settle()
    check(not ns.Waypoint.overlay:IsShown() and not ns.Arrow:IsShown(), "world map open: waypoint and chevron hide")
    check(ForeverGuideFrame:IsShown() and ForeverGuideFrame:GetFrameStrata() == "FULLSCREEN_DIALOG", "world map open: the Quest Guide stays above the map")
    MOCK.mapOpen = false; WorldMapFrame.hooks.OnHide(); settle()
    check(ns.Waypoint.overlay:IsShown(), "world map closed: the waypoint is back")
    check(ForeverGuideFrame:IsShown() and ForeverGuideFrame:GetFrameStrata() == "HIGH", "world map closed: guide returns to its normal layer")
    ns.UI:Hide()
    MOCK.mapOpen = true; WorldMapFrame.hooks.OnShow(); settle()
    MOCK.mapOpen = false; WorldMapFrame.hooks.OnHide(); settle()
    check(not ForeverGuideFrame:IsShown(), "opening and closing the map does not reopen a manually hidden guide")
    ns.UI:Show()
    do  -- Tick() falls back to BearingPosition when the engine pin is usable but has no screen
        -- position yet (stf:GetCenter() is nil); the mock cannot produce that state, so the
        -- projection is checked directly (1280x720 mock screen, character at 640,288)
        local W = ns.Waypoint
        local x, y, _, pinned = W:BearingPosition({ angle = 0, distance = 60 })
        check(x and math.abs(x - 640) < 1 and y > 288 and not pinned, string.format("60 yd straight ahead: above the character, centred (%.0f,%.0f)", x or 0, y or 0))
        local xr = W:BearingPosition({ angle = -math.rad(22), distance = 75 })
        check(xr and xr > 640 + 100, string.format("75 yd at 22 deg right lands well to the right (%.0f)", xr or 0))
        local xl, yl, _, pl = W:BearingPosition({ angle = math.rad(90), distance = 40 })
        check(pl and xl < 640 - 400 and math.abs(yl - 288) < 60, string.format("40 yd to the left pins to the left edge at the character's height (%.0f,%.0f)", xl or 0, yl or 0))
        local xb, yb, _, pb = W:BearingPosition({ angle = math.pi, distance = 30 })
        check(pb and math.abs(xb - 640) < 1 and yb < 288, string.format("30 yd behind pins to the bottom edge below the character (%.0f,%.0f)", xb or 0, yb or 0))
        local _, yf = W:BearingPosition({ angle = 0, distance = 800 })
    end
    -- back to the default (engine off): the chevron leads, no smoothing to feel sluggish
    ns.Commands:Run("waypoint engine off"); ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow:IsShown() and not ns.Arrow.suppressedByWaypoint, "engine off: back to the plain chevron by default")
    ns.Commands:Run("route off")
    ns.Commands:Run("route on")
    ns.Navigation:Clear()
    G:SetStep(5); settle()
end)

-- ---- level-gated quests: skipped until the level is reached, then revisited ---------------
section("level-gated quests: skipped until the level is reached, then revisited", function()
    -- a small synthetic chapter: The Lost Tools (125, req low) then Blackrock Menace (20, req 18)
    ns.RegisterGuide({ id = "TEST_GATE", name = "gate test", version = 1, faction = "Alliance", minLevel = 15, maxLevel = 20, map = 1433, zone = "Redridge Mountains",
        steps = {
            { type = "ACCEPT", quest = 125, questName = "The Lost Tools", map = 1433, x = 32.1, y = 48.6 },
            { type = "ACCEPT", quest = 20, questName = "Blackrock Menace", map = 1433, x = 33.5, y = 49 },
            { type = "KILL", quest = 20, questName = "Blackrock Menace", target = "Blackrock Champion", map = 1433, x = 60, y = 60 },
            { type = "COLLECT", quest = 125, questName = "The Lost Tools", target = "Oslow's Toolbox", map = 1433, x = 41.5, y = 54.7 },
            { type = "TURNIN", quest = 20, questName = "Blackrock Menace", map = 1433, x = 33.5, y = 49 },
            { type = "TURNIN", quest = 125, questName = "The Lost Tools", map = 1433, x = 32.1, y = 48.6 },
        } })
    MOCK_LEVEL(17); settle()
    G:Activate("TEST_GATE", true); settle()
    MOCK_ACCEPT(125, "The Lost Tools", { { text = "Oslow's Toolbox: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } }); settle()
    check(G.current == 4, "the level-18 accept and its objective are passed over at 17 (current " .. tostring(G.current) .. ")")
    check((G.note or ""):find("needs level 18") ~= nil, "the note says why: " .. tostring(G.note))
    ns.UI:Refresh(); settle()
    local blockedRow = false
    for _, e in ipairs(ForeverGuideFrame.list.entries) do if e.state == "blocked" and e.questID == 20 then blockedRow = true end end
    check(blockedRow, "deferred quest rows show as blocked with the level needed")
    MOCK_LEVEL(18); settle()
    check(G.current == 2, "reaching the level goes back to the deferred accept (" .. tostring(G.current) .. ")")
    MOCK.log[125] = nil
    for i, id in ipairs(MOCK.logOrder) do if id == 125 then table.remove(MOCK.logOrder, i) break end end
    MOCK_LEVEL(5); settle()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
end)

-- ---- the player's own order: Later / Do now, and skipped steps that come back ------------
section("the player's own order: Later / Do now, and skipped steps that come back", function()
    local function obj() return { { text = "Test mob slain: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } } end
    local function acc(q) return { type = "ACCEPT", quest = q, questName = "Order " .. q, map = 1429, x = 40, y = 40 } end
    ns.RegisterGuide({ id = "TEST_ORDER", name = "order test", version = 1, faction = "Alliance", minLevel = 1, maxLevel = 60, map = 1429, zone = "Elwynn Forest",
        steps = {
            acc(990701), acc(990702), acc(990703),
            { type = "KILL", quest = 990701, questName = "Order 990701", target = "Test mob", map = 1429, x = 41, y = 41 },
            acc(990704), acc(990705), acc(990706),
            { type = "TURNIN", quest = 990701, questName = "Order 990701", map = 1429, x = 40, y = 40 },
            acc(990707),
        } })
    G:Activate("TEST_ORDER", true); settle()
    local function seqString() return table.concat(G:Order(), ",") end
    check(G.current == 1 and seqString() == "1,2,3,4,5,6,7,8,9", "nothing moved: the guide's own order (" .. seqString() .. ")")

    -- Later on the current accept: it comes back after the next five open steps, and the quest's own
    -- objective in between goes with it; the turn-in further on stays where it is
    ns.Commands:Run("later")
    check(seqString() == "2,3,5,6,7,1,4,8,9", "/fg later moves the accept and its objective behind five open steps (" .. seqString() .. ")")
    check(G.current == 2, "the walk goes on at the next step (" .. tostring(G.current) .. ")")
    check(not G.progress.done[1], "a step put off is not done")
    ns.UI:Refresh(); settle()
    local first = ForeverGuideFrame.list.entries[1]
    check(first and first.index == 2 and first.number == 1, "the window lists the new order, numbered by place (" .. tostring(first and first.index) .. ")")

    MOCK_ACCEPT(990702, "Order 990702", obj()); settle()
    check(G.current == 3, "finishing a step moves on in the new order (" .. tostring(G.current) .. ")")
    MOCK_ACCEPT(990703, "Order 990703", obj()); settle()
    check(G.current == 5, "the walk passes over the moved steps' old places (" .. tostring(G.current) .. ")")

    -- Do now: a step further down becomes the current one, and the old current one follows it
    check(G:DoNow(1) == true and G.current == 1, "Do now makes that step current (" .. tostring(G.current) .. ")")
    check(G:PosOf(5) > G:PosOf(1) and not G.progress.done[5], "the old current step is still ahead, not done")
    check(G:PosOf(4) > G:PosOf(1) and G:PosOf(8) > G:PosOf(4), "the quest's objective and turn-in still come after its accept (" .. seqString() .. ")")

    -- Skip is no longer for good: the skipped step is listed and Do now brings its whole quest back
    G:Skip(); settle()
    check(G.progress.done[1] and G.progress.done[4] and G.progress.done[8], "skipping an accept skips its quest")
    local skipped = G:SkippedSteps()
    check(#skipped == 1 and skipped[1] == 1, "the skipped step is listed (" .. #skipped .. ")")
    ns.UI:Refresh(); settle()
    local byIdx = {}
    for _, e in ipairs(ForeverGuideFrame.list.entries) do byIdx[e.index] = e end
    check(byIdx[1] and byIdx[1].state == "skipped" and (byIdx[1].title or ""):find("Skipped", 1, true) ~= nil,
        "a skipped step stays in the list, marked skipped (" .. tostring(byIdx[1] and byIdx[1].state) .. ")")
    check(byIdx[8] and byIdx[8].state == "skipped", "so does the rest of the skipped quest")
    local labels = {}
    for _, item in ipairs(ns.QuestGuide:StepMenuItems(1)) do labels[#labels + 1] = item[1] end
    check(table.concat(labels, ",") == "Do now", "right click on a skipped row offers Do now (" .. table.concat(labels, ",") .. ")")
    check(G:DoNow(1) == true and G.current == 1, "Do now brings a skipped step back (" .. tostring(G.current) .. ")")
    check(not G.progress.done[4] and not G.progress.done[8] and #G:SkippedSteps() == 0, "...with the rest of its quest, and it is no longer listed")
    check(G:DoNow(99) == false, "Do now on a step that does not exist does nothing")


    -- the right-click menu on a row: Do now / Later / Skip
    ns.UI:Refresh(); settle()
    local row
    for _, r in ipairs(ForeverGuideFrame.list.rows) do
        if r:IsShown() and r.entry and r.entry.index == 5 then row = r end
    end
    need(row ~= nil, "step 5 has a row")
    if row then
        row:GetScript("OnClick")(row, "RightButton")
        local m = ForeverGuideRowMenu
        local labels = {}
        for _, b in ipairs(m.buttons) do if b:IsShown() then labels[#labels + 1] = b.label:GetText() end end
        check(m:IsShown() and table.concat(labels, ",") == "Do now,Later,Skip", "right click opens Do now / Later / Skip (" .. table.concat(labels, ",") .. ")")
        -- hovering a choice says what it does
        local function hover(b)
            GameTooltip.lines = nil
            b:GetScript("OnEnter")(b)
            local text = table.concat(GameTooltip.lines or {}, " ")
            b:GetScript("OnLeave")(b)
            return text
        end
        local laterTip, skipTip = hover(m.buttons[2]), hover(m.buttons[3])
        local nowTip = hover(m.buttons[1])
        -- the menu and the Details popup both open left of the window: they must not cover each other
        ns.QuestGuide:ToggleInfo()
        check(ForeverGuideInfo:IsShown() and not m:IsShown(), "opening Details closes the menu")
        row:GetScript("OnClick")(row, "RightButton")
        local besideInfo = false
        for _, pt in ipairs(m.points or {}) do if pt[2] == ForeverGuideInfo then besideInfo = true end end
        check(m:IsShown() and besideInfo, "with Details open, the menu opens beside it, not on top of it")
        ns.QuestGuide:ToggleInfo()
        local later = m.buttons[2]
        later:GetScript("OnClick")(later)
        check(not m:IsShown() and G:IsMoved(5), "Later from the menu moves the step and closes the menu")
    end

    -- reset: back to the guide's order; a new guide version drops the moves
    check(G:ResetOrder() == true and seqString() == "1,2,3,4,5,6,7,8,9", "/fg order reset restores the guide's order (" .. seqString() .. ")")
    G.progress.order = { { 3, 0 } }
    ns.Database:GuideProgress("TEST_ORDER", 2)
    check(G.progress.order == nil and G.progress.skipped == nil, "a new guide version drops the moves and the skipped list")

    for _, q in ipairs({ 990702, 990703 }) do MOCK_ABANDON(q) end
    settle()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
end)

-- ---- auto mode: Do first / Do last pins a quest over the distance order -------------------------
section("auto mode: Do first / Do last pins a quest over the distance order", function()
    MOCK_ACCEPT(990801, "Near Quest", { { text = "Near: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } })
    MOCK_ACCEPT(990802, "Far Quest", { { text = "Far: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } })
    settle()
    MOCK_MOVE(40, 40)
    MOCK.questPins = { [1429] = { { questID = 990801, x = 0.41, y = 0.40 }, { questID = 990802, x = 0.80, y = 0.80 } } }
    ns.Tracker:SetMode("auto"); settle()
    local function pos(q) for i, c in ipairs(ns.Tracker.candidates) do if c.questID == q then return i end end return 99 end
    ns.Tracker:Rethink()
    check(pos(990801) < pos(990802), "nearest first (" .. pos(990801) .. " vs " .. pos(990802) .. ")")
    ns.Tracker:Pin(990802, "first")
    check(pos(990802) == 1 and ns.Tracker.current.questID == 990802, "Do first puts a far quest on top and the arrow on it")
    ns.Tracker:Pin(990801, "last")
    check(pos(990801) == #ns.Tracker.candidates, "Do last sends a quest to the bottom")
    ns.Tracker:Pin(990801, nil)
    MOCK_ABANDON(990802); settle()
    ns.Tracker:Rethink()
    check(ns.char.trackerPrio[990802] == nil, "a quest that left the log loses its pin")
    ns.Tracker:ResetPriority()
    MOCK_ABANDON(990801); settle()
    MOCK.questPins = nil
    ns.Tracker:SetMode("guide"); settle()
end)

-- ---- sweep: every command, every UI script, options, keybinds ------------------------
section("sweep: every command, every UI script, options, keybinds", function()
    local before = #reportedErrors
    local cmds = {
        "", "help", "show", "hide", "toggle", "show", "guides", "guide GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", "skip", "back", "next", "step 3",
        "quests", "mode auto", "track", "mode guide", "quest 783", "quest kobold", "avail", "avail 5", "pos", "target", "nav",
        "way 40 60", "lock", "unlock", "resetpos", "auto", "auto accept guide", "auto turnin off", "auto accept on", "auto turnin on",
        "minimap off", "minimap on", "arrow off", "arrow on", "scale 1.2", "scale 1", "share status", "share", "scan status",
        "harvest status", "bliz off", "bliz on", "wrong", "wrong test text", "reports", "options", "debug", "debug", "eval",
        "reports clear", "bogus", "later", "now 2", "now", "skipped", "order", "order reset", "reset",
    }
    for _, c in ipairs(cmds) do ns.Commands:Run(c) end
    -- UI window scripts
    local frames = {}
    for name, f in pairs(_G) do
        if type(name) == "string" and name:find("^ForeverGuide") and type(f) == "table" and type(rawget(f, "scripts")) == "table" then frames[#frames + 1] = name end
    end
    table.sort(frames)   -- pairs() order is not stable: a stable sweep fails the same way every run
    for _, name in ipairs(frames) do
        local f = _G[name]
        do
            local snames = {}
            for sname in pairs(f.scripts) do snames[#snames + 1] = sname end
            table.sort(snames)
            for _, sname in ipairs(snames) do
                local fn = f.scripts[sname]
                if sname == "OnUpdate" then fn(f, 0.5) fn(f, 0.5)
                elseif sname == "OnClick" then fn(f, "LeftButton") fn(f, "RightButton")
                elseif sname == "OnEnter" or sname == "OnLeave" or sname == "OnShow" or sname == "OnHide" then fn(f)
                elseif sname == "OnDragStart" or sname == "OnDragStop" then fn(f)
                end
            end
            f.moving, f.sizing = false, false   -- OnDragStop may have run before OnDragStart: leave no drag open
        end
    end
    -- options panel: flip every checkbox both ways
    local panel = rawget(_G, "ForeverGuideOptionsPanel")
    check(panel ~= nil and MOCK.settingsCategory ~= nil, "options panel registered with the Settings API")
    if panel then
        panel.scripts.OnShow(panel)
        ns.Options:Refresh()
    end
    for _, fname in ipairs({ "ForeverGuide_ToggleWindow", "ForeverGuide_TogglePicker", "ForeverGuide_ToggleArrow", "ForeverGuide_Skip",
        "ForeverGuide_Back", "ForeverGuide_ToggleMode", "ForeverGuide_ReportWrong", "ForeverGuide_ToggleWindow", "ForeverGuide_TogglePicker",
        "ForeverGuide_ToggleArrow", "ForeverGuide_ToggleMode" }) do _G[fname]() end
    -- hide in combat
    ns.db.ui.hideInCombat = true
    ns.UI:Show()
    MOCK_FIRE("PLAYER_REGEN_DISABLED")
    check(not ForeverGuideFrame:IsShown(), "window hidden when combat starts")
    MOCK_FIRE("PLAYER_REGEN_ENABLED")
    check(ForeverGuideFrame:IsShown(), "window restored after combat")
    ns.db.ui.hideInCombat = false
    -- minimap tooltip / clicks
    local mb = rawget(_G, "ForeverGuideMinimapButton")
    if mb then mb.scripts.OnEnter(mb) mb.scripts.OnLeave(mb) mb.scripts.OnClick(mb, "LeftButton") mb.scripts.OnClick(mb, "RightButton") mb.scripts.OnClick(mb, "LeftButton") end
    ns.UI:RefreshPicker()
    ns.Tracker:SetMode("auto") ns.Tracker:Rethink() ns.UI:Refresh() ns.Tracker:SetMode("guide")
    local unexpected = 0
    for i = before + 1, #reportedErrors do
        local e = reportedErrors[i]
        if not e:find("unknown command", 1, true) then unexpected = unexpected + 1 end
    end
    check(unexpected == 0, "command / UI sweep produced no errors (" .. unexpected .. ")")
end)

-- ---- saved data lives only in the SavedVariables: no ForeverGuide cvars ----
section("saved data lives only in the SavedVariables: no ForeverGuide cvars", function()
    check(ns.Persist == nil, "the beta cvar mirror is gone")
    local touched = {}
    for _, name in ipairs(MOCK.cvarCalls) do if name:find("^ForeverGuide") then touched[#touched + 1] = name end end
    check(#touched == 0, "the addon never reads or writes a ForeverGuide cvar (" .. table.concat(touched, ", ") .. ")")
    -- a new character starts clean, whatever another character left in the cvars of an older build
    local was = ForeverGuideCharDB
    MOCK.cvars.ForeverGuideCchar0 = "v=1;g=GEN_ALLIANCE_DWARF_01_DUN_MOROGH;s=9;r=TUGSDWARF"
    ForeverGuideCharDB = nil
    ns.Database:Init()
    check(ns.char.activeGuide == nil and ns.char.route == nil and next(ns.char.guides) == nil,
        "a new character's empty SavedVariables stay empty: no other character's guide, route or positions")
    MOCK.cvars.ForeverGuideCchar0 = nil
    ForeverGuideCharDB = was
    ns.char = was
end)

-- ---- arriving in the zone finishes the chapter's travel step; resync moves forward ----
-- (Ilya, 2026-09-21: level 18 in Westfall with the Westfall chapter open, the guide sat on
--  "Travel to Westfall - 640 yd" forever and every /fg resync answered "now at step 1")
section("arriving in the zone finishes the chapter's travel step; resync moves forward", function()
    local savedMap, savedZone = MOCK.mapID, MOCK.zone
    -- a chapter that opens by travelling into its zone (the Westfall chapter as generated before
    -- quests were added to it; live chapters change, the rule under test does not)
    ns.RegisterGuide({ id = "TEST_ZONE_ENTRY", name = "zone entry", version = 1, faction = "Alliance", minLevel = 14, maxLevel = 17, map = 1436, zone = "Westfall",
        steps = {
            { type = "TRAVEL", map = 1436, zone = "Westfall", x = 56.2, y = 43.9, radius = 60, note = "travel to Westfall (Westfall)" },
            { type = "NOTE", map = 1436, zone = "Westfall", x = 56.2, y = 43.9, text = "set your hearthstone at the inn in Westfall (if there is one)" },
            { type = "ACCEPT", quest = 6181, questName = "A Swift Message", npc = 491, npcName = "Quartermaster Lewis", map = 1436, zone = "Westfall", x = 57, y = 47.2 },
            { type = "ACCEPT", quest = 12, questName = "The People's Militia", npc = 234, npcName = "Gryan Stoutmantle", map = 1436, zone = "Westfall", x = 56.3, y = 47.5 },
            { type = "ACCEPT", quest = 102, questName = "Patrolling Westfall", npc = 821, npcName = "Captain Danuvin", map = 1436, zone = "Westfall", x = 56.4, y = 47.6 },
            { type = "ACCEPT", quest = 65, questName = "The Defias Brotherhood", npc = 234, npcName = "Gryan Stoutmantle", map = 1436, zone = "Westfall", x = 56.3, y = 47.5 },
        } })
    local savedLevel = ns.Player:GetLevel()
    MOCK_LEVEL(14); settle()
    G:Activate("TEST_ZONE_ENTRY", true); settle()
    local steps = G.active.steps
    check(cur() == 1, "outside Westfall the guide holds the travel step (" .. tostring(cur()) .. ")")
    -- walk in, but nowhere near the coordinates the step carries (Moonbrook, not Sentinel Hill)
    MOCK_ZONE(1436, "Westfall", 45.5, 66.1); settle()
    check(G:IsStepDone(steps[1], 1) == true and cur() == 2,
        "in Westfall the travel step is done -> the hearthstone note (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(6181, "A Swift Message"); settle()
    check(cur() > 2 and steps[cur()].type ~= "TRAVEL", "and the note gives way once a quest is taken (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(6181); settle()
    -- an in-zone travel step is NOT ticked off just for being in the zone
    check(G:IsZoneEntry(steps[1], 1) == true, "step 1 is a zone entry")
    local inZone = { type = "TRAVEL", map = 1436, zone = "Westfall", x = 20, y = 20 }
    check(G:IsZoneEntry(inZone, 5) == false, "a travel step later in the same zone is not a zone entry")

    -- resync with quests already taken out of order: it must move forward, not back to step 1
    G:SetStep(1); settle()
    MOCK_ACCEPT(12, "The People's Militia", { { text = "Defias Trapper slain", finished = false, numFulfilled = 0, numRequired = 15 } }); settle()
    MOCK_ACCEPT(102, "Patrolling Westfall"); settle()
    local landed = G:Resync() and cur()
    check(landed and landed > 1, "resync moves forward past the stale travel step (" .. tostring(landed) .. ")")
    check(G.progress.done[1] == true, "the travel step is marked done by the resync")
    MOCK_ABANDON(12) MOCK_ABANDON(102)
    MOCK_ZONE(savedMap, savedZone, 48, 43); settle()
    MOCK_LEVEL(savedLevel); settle()
    G:Activate("HUMAN_NORTHSHIRE_1_6", true); G:Reset(); settle()
end)

-- ---- a quest this character's race can never take is not part of the route ----
-- (Ilya, 2026-09-21: the Dwarf chapter offered 6181 "A Swift Message", a Human-only quest, and the
--  guide sat on it at Quartermaster Lewis - who has nothing to say to a dwarf)
section("a quest this character's race can never take is not part of the route", function()
    -- A Swift Message (6181) is Human-only (race mask 1) and was on the Dwarf route, seen 2026-09-21
    ns.QuestDB[990811] = { n = "Human Only", races = 1 }
    ns.QuestDB[990812] = { n = "For Everyone" }
    local mine = MOCK.race
    MOCK.race = { "Dwarf", "Dwarf" }
    ns.Player.cache = {}
    ns.RegisterGuide({ id = "AUDIT_RACE", name = "race", steps = {
        { type = "ACCEPT", quest = 990811 },
        { type = "TURNIN", quest = 990811 },
        { type = "ACCEPT", quest = 990812 } } })
    G:Activate("AUDIT_RACE", true); settle()
    check(ns.DB:RaceClassOK(990811) == false, "a dwarf cannot take a human-only quest")
    check(cur() == 3, "its accept and turn-in are not part of the route for a dwarf (" .. tostring(cur()) .. ")")
    MOCK.race = { "Human", "Human" }
    ns.Player.cache = {}
    check(ns.DB:RaceClassOK(990811) == true, "a human can")
    MOCK.race = mine
    ns.Player.cache = {}
    ns.QuestDB[990811], ns.QuestDB[990812] = nil, nil
end)

-- a quest the client no longer has (vanilla data, no Forever id) is walked past like a race-only one
section("a quest gone from Forever is not part of the route", function()
    ns.QuestDB[990701] = { n = "Gone Quest", removed = true }
    ns.QuestDB[990702] = { n = "Still Here" }
    ns.RegisterGuide({ id = "TEST_REMOVED", name = "removed test", version = 1, faction = "Alliance", minLevel = 1, maxLevel = 10, map = 1429, zone = "Elwynn Forest",
        steps = {
            { type = "ACCEPT", quest = 990701, questName = "Gone Quest", map = 1429, x = 40, y = 40 },
            { type = "TURNIN", quest = 990701, questName = "Gone Quest", map = 1429, x = 40, y = 40 },
            { type = "ACCEPT", quest = 990702, questName = "Still Here", map = 1429, x = 41, y = 41 },
        } })
    G:Activate("TEST_REMOVED", true); settle()
    check(cur() == 3 and step().quest == 990702, "a removed quest's accept and turn-in are passed over (" .. tostring(cur()) .. ")")
    check(G:StepApplies({ type = "ACCEPT", quest = 990702 }) == true, "a quest the client still has applies")
    ns.QuestDB[990701], ns.QuestDB[990702] = nil, nil
    G:Activate("HUMAN_NORTHSHIRE_1_6", true); settle()
end)

-- a breadcrumb is passed once its quest is taken: Rejold's New Brew (415) leads to Shimmer Stout (413)
section("a breadcrumb is passed once its quest is taken", function()
    -- Rejold's New Brew (415) leads to Shimmer Stout (413): with Shimmer Stout taken at Rejold's first, 415 is never offered
    ns.QuestDB[990816] = { n = "Breadcrumb", breadcrumb = 990817 }
    ns.QuestDB[990817] = { n = "Where It Leads" }
    local bread = { type = "ACCEPT", quest = 990816 }
    check(G:IsStepDone(bread, 9999) == false, "a breadcrumb's accept waits while its quest is not taken")
    MOCK_ACCEPT(990817, "Where It Leads"); settle()
    local done, why = G:IsStepDone(bread, 9999)
    check(done == true and why == "breadcrumb passed", "...and is passed once the quest it leads to is in the log (" .. tostring(why) .. ")")
    MOCK_ABANDON(990817); settle()
    ns.QuestDB[990816], ns.QuestDB[990817] = nil, nil
end)

-- class-limited WoW Forever quests: the second Stalk With The Earthmother is for shamans (the first
-- is open to Tauren, Orc and Troll warriors, shamans and druids, so it cannot stand for it)
section("class-limited WoW Forever quests", function()
    -- the second Stalk With The Earthmother (76160) is for shamans only (class mask 64)
    ns.QuestDB[990813] = { n = "Shaman Only", classes = 64 }
    local class, race, faction = MOCK.class, MOCK.race, MOCK.faction
    MOCK.race, MOCK.faction = { "Tauren", "Tauren" }, "Horde"
    MOCK.class = { "Warrior", "WARRIOR", 1 }; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(990813) == false, "a warrior cannot take the shaman quest")
    check(G:StepApplies({ type = "ACCEPT", quest = 990813 }) == false, "...so its step is not in a warrior's route")
    MOCK.class = { "Shaman", "SHAMAN", 7 }; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(990813) == true and G:StepApplies({ type = "ACCEPT", quest = 990813 }) == true, "a shaman gets it")
    ns.QuestDB[990813] = nil
    MOCK.class = { "Mage", "MAGE", 8 }; ns.Player.cache = {}
    check(G:StepApplies({ type = "ACCEPT", quest = 7, class = { "WARRIOR" } }) == false, "a warrior-only guide step is not a mage's")
    MOCK.class, MOCK.race, MOCK.faction = class, race, faction; ns.Player.cache = {}
end)

-- Skyborne (WoW Forever's race, file name "Skyborne", on both factions) has no bit in the Classic
-- race masks: it takes what every race of its faction can take, and nothing race-specific
section("race masks: it takes what every race of its faction can take, and nothing race-specific", function()
    -- Classic race masks: Human 1, the four Alliance races 77, the four Horde races 178
    ns.QuestDB[990811] = { n = "Human Only", races = 1 }
    ns.QuestDB[990814] = { n = "All Alliance", races = 77 }
    ns.QuestDB[990815] = { n = "All Horde", races = 178 }
    local mine, faction = MOCK.race, MOCK.faction
    MOCK.race, MOCK.faction = { "Skyborne", "Skyborne" }, "Alliance"; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(990811) == false, "a Skyborne cannot take a Human-only quest")
    check(ns.DB:RaceClassOK(990814) == true, "an Alliance Skyborne takes an all-Alliance quest")
    check(ns.DB:RaceClassOK(990815) == false, "an Alliance Skyborne cannot take a Horde quest")
    MOCK.faction = "Horde"; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(990815) == true and ns.DB:RaceClassOK(990814) == false, "a Horde Skyborne: the Horde quest yes, the Alliance one no")
    MOCK.race, MOCK.faction = mine, faction; ns.Player.cache = {}
    ns.QuestDB[990811], ns.QuestDB[990814], ns.QuestDB[990815] = nil, nil, nil
end)

-- Skyborne's own bits (65536 Alliance, 131072 Horde): a quest Forever opened to Skyborne says so,
-- as The Principal Source (6122) is open to Night Elf and Alliance Skyborne druids
section("Skyborne's own race bits", function()
    local race, faction, class = MOCK.race, MOCK.faction, MOCK.class
    local nightElfAndSkyborne, skyborneOnly, humanOnly = 999901, 999902, 999903
    ns.QuestDB[nightElfAndSkyborne] = { n = "Night Elf and Alliance Skyborne druids", races = 8 + 65536, classes = 1024 }
    ns.QuestDB[skyborneOnly] = { n = "Alliance Skyborne only", races = 65536 }
    ns.QuestDB[humanOnly] = { n = "Human only", races = 1 }
    MOCK.class = { "Druid", "DRUID", 11 }
    MOCK.race, MOCK.faction = { "Skyborne", "Skyborne" }, "Alliance"; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(nightElfAndSkyborne) == true, "an Alliance Skyborne druid takes a quest that names Alliance Skyborne")
    check(ns.DB:RaceClassOK(skyborneOnly) == true and ns.DB:RaceClassOK(humanOnly) == false, "...and still nothing race-specific of another race")
    MOCK.faction = "Horde"; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(nightElfAndSkyborne) == false, "a Horde Skyborne does not: the bit is per faction")
    MOCK.race, MOCK.faction = { "Human", "Human" }, "Alliance"; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(nightElfAndSkyborne) == false, "a Human druid does not")
    MOCK.race = { "NightElf", "NightElf" }; ns.Player.cache = {}
    check(ns.DB:RaceClassOK(nightElfAndSkyborne) == true, "a Night Elf druid does")
    check(ns.DB:QuestFaction(skyborneOnly) == "Alliance", "a quest only Alliance Skyborne may take is an Alliance quest")
    ns.QuestDB[nightElfAndSkyborne], ns.QuestDB[skyborneOnly], ns.QuestDB[humanOnly] = nil, nil, nil
    MOCK.race, MOCK.faction, MOCK.class = race, faction, class; ns.Player.cache = {}
end)

-- ---- level-up announcement ------------------------------------------------------------------
-- (Ilya, 2026-09-21: "when we level up there should be a party message/emote message ...")
section("level-up announcement", function()
    local D = ns.Ding
    check(D.FormatTime(42) == "42 sec" and D.FormatTime(1080) == "18 min"
        and D.FormatTime(5040) == "1h 24m" and D.FormatTime(183600) == "2d 3h",
        "time played reads naturally (" .. D.FormatTime(5040) .. ")")
    check(D.Message(18, 5040) == "ForeverGuide: I leveled up to 18 in 1h 24m", "the line is what was asked for: " .. D.Message(18, 5040))
    check(D.Message(18, nil) == "ForeverGuide: I leveled up to 18", "an unknown time is left out")

    -- the server answer is the baseline; time keeps running from it
    MOCK.playedTotal, MOCK.playedLevel = 360000, 5000
    D:Request()
    check(D.played ~= nil and math.abs(D:Elapsed() - 5000) < 2, "time played at this level comes from the server (" .. tostring(D:Elapsed()) .. ")")
    MOCK_ADVANCE(40)
    check(math.abs(D:Elapsed() - 5040) < 2, "and keeps running while online (" .. tostring(D:Elapsed()) .. ")")

    -- the client's own "Total time played" answer to OUR request is swallowed, a /played is not
    D:Request()
    check(MOCK_SYSTEM("Total time played: 1 day, 3 hours") == nil, "our own time-played answer is not printed")
    check(MOCK_SYSTEM("Whatever else the server says") ~= nil, "other system messages are untouched")
    check(MOCK_CHATFRAME("Total time played: 1 day, 3 hours") == nil, "and neither is it when the client prints it straight into the frame")
    check(MOCK_CHATFRAME("Sniff Yahbooty says hello") ~= nil, "ordinary chat lines still print")
    MOCK_ADVANCE(10)
    check(MOCK_SYSTEM("Total time played: 1 day, 3 hours") ~= nil, "a /played the player types still prints")

    -- Opt into announcements for their behavior tests; normal default is off.
    ns.Commands:Run("ding on")
    -- solo: an emote
    MOCK.chat = {}
    MOCK.group, MOCK.raid = false, false
    local was = ns.Player:GetLevel()
    local expected = D.FormatTime(D:Elapsed())
    MOCK_LEVEL(was + 1); settle()
    local sent = MOCK.chat[1]
    check(sent ~= nil and sent.channel == "EMOTE", "solo, the ding goes out as an emote (" .. tostring(sent and sent.channel) .. ")")
    check(sent and sent.message == string.format("ForeverGuide: I leveled up to %d in %s", was + 1, expected),
        "with the level and the time played at the level before it: " .. tostring(sent and sent.message))
    check((MOCK.playedRequests or 0) >= 2, "and the baseline is asked for again after the ding")

    -- in a party: the party
    MOCK.chat = {}
    MOCK.group = true
    MOCK_LEVEL(was + 2); settle()
    check(MOCK.chat[1] and MOCK.chat[1].channel == "PARTY", "grouped, it goes to the party (" .. tostring(MOCK.chat[1] and MOCK.chat[1].channel) .. ")")

    -- a chosen channel wins, and off means off
    MOCK.chat = {}
    ns.Commands:Run("ding guild")
    MOCK_LEVEL(was + 3); settle()
    check(MOCK.chat[1] and MOCK.chat[1].channel == "GUILD", "a chosen channel is used (" .. tostring(MOCK.chat[1] and MOCK.chat[1].channel) .. ")")
    MOCK.chat = {}
    ns.Commands:Run("ding off")
    MOCK_LEVEL(was + 4); settle()
    check(#MOCK.chat == 0, "/fg ding off stops it (" .. #MOCK.chat .. " sent)")

    -- a client that refuses the message says so instead of erroring
    ns.Commands:Run("ding on")
    ns.Commands:Run("ding auto")
    MOCK.chatBlocked = true
    MOCK.chat = {}
    MOCK_LEVEL(was + 5); settle()
    MOCK.chatBlocked = nil
    MOCK.group, MOCK.raid = false, false

end)

-- ---- a quest about to stop paying is flagged where the tracker lists it ----
section("a quest about to stop paying is flagged in the tracker", function()
    local was = ns.Player:GetLevel()
    local function cand(q) for _, c in ipairs(ns.Tracker.candidates or {}) do if c.questID == q then return c end end end
    MOCK_LEVEL(1); settle()
    MOCK_ACCEPT(783, "A Threat Within"); settle()
    ns.Tracker:SetMode("auto"); ns.Tracker:Rethink()
    need(cand(783) ~= nil, "the level-1 quest is a tracker candidate")
    check(cand(783).grey == nil, "at level 1 it carries no warning (" .. tostring(cand(783).grey) .. ")")
    MOCK_LEVEL(12); settle()
    ns.Tracker:Rethink()
    check(cand(783) and cand(783).grey and cand(783).grey:find("xp", 1, true) ~= nil, "at level 12 the tracker says the quest is out-levelled (" .. tostring(cand(783) and cand(783).grey) .. ")")
    MOCK_ABANDON(783); settle()
    ns.Tracker:SetMode("guide")
    MOCK_LEVEL(was); settle()
end)

-- ---- the options panel fits in the settings canvas -------------------------------------------
-- (Ilya, 2026-09-21: "the text is overflowing" - the checkbox list ran off the bottom of the
--  Options window and drew over the game)
section("the options panel fits in the settings canvas", function()
    local p = ns.Options:Create()
    local wheel = p.scroll:GetScript("OnMouseWheel")
    if wheel then
        p.scroll:SetHeight(300)
        wheel(p.scroll, -1)
        check(p.scroll:GetVerticalScroll() > 0, "wheeling down moves the list (" .. tostring(p.scroll:GetVerticalScroll()) .. ")")
        wheel(p.scroll, 1) wheel(p.scroll, 1)
        check(p.scroll:GetVerticalScroll() == 0, "and it stops at the top (" .. tostring(p.scroll:GetVerticalScroll()) .. ")")
        local bar = p.scroll.bar
        need(bar ~= nil, "the list has a scroll bar")
        p.scroll.UpdateBar()
        local _, max = bar:GetMinMaxValues()
        check(bar:IsShown() and max > 0, "the bar shows while the list is longer than the window (" .. tostring(max) .. ")")
        bar:SetValue(max)
        check(p.scroll:GetVerticalScroll() == max, "dragging it to the bottom scrolls the list there")
        wheel(p.scroll, 1)
        check(bar:GetValue() == p.scroll:GetVerticalScroll(), "and the wheel moves the bar with the list")
        bar:SetValue(0)
    end
    local ding = ns.Options:GetWidget("qg_ding")
    need(ding ~= nil, "the level-up announcement has a switch in the panel")
    if ding then
        local was = ns.db.ding.enabled
        ding:SetChecked(not was); ding:GetScript("OnClick")(ding)
        check(ns.db.ding.enabled == not was, "clicking the switch flips the announcement")
        ding:SetChecked(was); ding:GetScript("OnClick")(ding)
    end
end)

-- ---- levelling pace ---------------------------------------------------------------------------
section("levelling pace", function()
    local P = ns.Pace
    check(P.Number(19600) == "19 600" and P.Number(940) == "940", "numbers are grouped for reading (" .. P.Number(19600) .. ")")

    -- a chapter's model comes from the planner, through the notes of the guides already generated
    local g = ns.Guide.registry[chapterId("GEN_ALLIANCE_HUMAN_02_")]
    local minutes, xph = P.Model(g)
    check(minutes == 136 and xph == 17747, "the model minutes / xp-h are read off a generated chapter's notes (" .. tostring(minutes) .. ", " .. tostring(xph) .. ")")
    check(P.Model({ notes = "a hand-written guide" }) == nil and P.Model({}) == nil, "a guide without a model has none")

    -- earn xp over measured play and the rate follows
    P.samples, P.earned, P.played = {}, 0, 0
    P.lastXP, P.lastMax, P.lastLevel = nil, nil, nil
    P:Sample("reset")
    MOCK_XP(100, 1000)
    P:Sample("base")
    local earnedBefore = P.earned
    for _ = 1, 10 do MOCK_ADVANCE(60) end     -- ten minutes of play, in steps a session would take
    MOCK_XP(600, 1000)
    check(P.earned - earnedBefore == 500, "xp earned since the last look (" .. tostring(P.earned - earnedBefore) .. ")")
    local perHour = P:PerHour()
    check(perHour and math.abs(perHour - 3000) < 60, "500 xp in ten minutes reads as 3000 xp/h (" .. tostring(perHour and math.floor(perHour)) .. ")")

    local s = P:Stats()
    check(s.remaining == 400 and math.abs((s.percent or 0) - 60) < 1, "what is left of the level (" .. tostring(s.remaining) .. ", " .. tostring(math.floor(s.percent or 0)) .. "%)")
    check(s.secondsToLevel and math.abs(s.secondsToLevel - 480) < 30, "400 xp at 3000/h is about 8 minutes (" .. tostring(s.secondsToLevel and math.floor(s.secondsToLevel)) .. ")")
    check(P:Tag() ~= nil and P:Tag():find("in ", 1, true) ~= nil, "the header tag reads like '19 in 8 min' (" .. tostring(P:Tag()) .. ")")

    -- a level-up counts the rest of the old level plus what is on the new one
    MOCK_XP(900, 1000)
    local before = P.earned
    MOCK.level = MOCK.level + 1
    MOCK_XP(50, 1200)
    check(P.earned - before == 150, "a level-up counts the rest of the old bar plus the new (" .. tostring(P.earned - before) .. ")")

    -- the route model knows what is left
    ns.Guide:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
    local left, chapters = P:RouteRemaining()
    check(left and left > 0 and chapters and chapters > 1, "minutes left on the route, over the remaining chapters (" .. tostring(left and math.floor(left)) .. " min, " .. tostring(chapters) .. ")")
    local lines = P:Lines()
    local allText = #lines >= 3
    for _, line in ipairs(lines) do if type(line) ~= "string" or #line == 0 then allText = false end end
    check(allText, "/fg xp has something to say, one line of text each (" .. #lines .. " lines)")
end)

-- ---- a chapter of another race's route ---------------------------------------------------------
-- (seen live 2026-09-22: a level-20 dwarf in Duskwood was following "6. Ashenvale 19-22 (Night Elf)"
--  while /fg path said the Dwarf route; the race-only quests in it are skipped, so say so)
section("a chapter of another race's route", function()
    local mineBefore = ns.char.route
    ns.char.route = nil
    MOCK.level = 20
    ns.Player.cache.level = 20
    local mine, route = ns.Guide:RouteChapterForLevel(20)
    need(route ~= nil and mine ~= nil, "the followed route has a chapter for level 20 (" .. tostring(mine and mine.id) .. ")")
    need(ns.Guide:ForMyRace(mine) == true, "and it is one for this character's race")

    local said, realPrint = {}, ns.Print
    ns.Print = function(msg) said[#said + 1] = tostring(msg) end
    ns.Guide:Activate(chapterId("GEN_ALLIANCE_NIGHTELF_06_"), true); settle()
    local race, instead = ns.Guide:OffRouteChapter()
    check(race == "NIGHTELF" and instead ~= nil, "a night elf chapter is spotted as off-route (" .. tostring(race) .. " -> " .. tostring(instead and instead.id) .. ")")
    check(#said == 1 and said[1]:find("your own route has", 1, true) ~= nil, "and the player is told once, with the way back (" .. #said .. ": " .. tostring(said[1]) .. ")")
    ns.Guide:WarnOffRoute()
    check(#said == 1, "the warning is not repeated for the same chapter")
    ns.Print = realPrint

    ns.Guide:Activate(mine.id, true); settle()
    check(ns.Guide:OffRouteChapter() == nil, "our own chapter raises nothing")

    -- asking for another route by hand is not second-guessed
    ns.char.route = "GEN_ALLIANCE_NIGHTELF"
    ns.Guide:Activate(chapterId("GEN_ALLIANCE_NIGHTELF_06_"), true); settle()
    check(ns.Guide:OffRouteChapter() == nil, "a route the player chose is left alone")
    ns.char.route = mineBefore
    ns.Guide:Activate("HUMAN_NORTHSHIRE_1_6", true); ns.Guide:Reset(); settle()
end)

-- ---- flight points and the trainer nudge -------------------------------------------------------
section("flight points and the trainer nudge", function()
    local R = ns.Reminders
    local map = 1415          -- taxi nodes are listed per continent (Eastern Kingdoms here)
    MOCK_TAXI(map, {})
    check(#R:FlightPoints() == 0, "no taxi nodes: nothing to take")

    -- the client lists the whole continent; ours is what counts, minus the ones we already have
    MOCK_MOVE(48, 43)
    ns.char.flightpoints = { ["Sentinel Hill"] = true }
    MOCK_TAXI(map, {
        { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, isUndiscovered = false, faction = 2 },
        { nodeID = 2, name = "Sentinel Hill", x = 20, y = 20, isUndiscovered = false, faction = 2 },
        { nodeID = 3, name = "Grom'gol", x = 49, y = 44, isUndiscovered = false, faction = 1 },
    })
    local list = R:FlightPoints()
    check(#list == 1 and list[1].name == "Darkshire", "one we do not have, of our faction (" .. #list .. ")")
    check(list[1].distance and list[1].distance < 100, "with a distance (" .. tostring(list[1].distance and math.floor(list[1].distance)) .. " yd)")
    MOCK_TAXI(map, {
        { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, faction = 2 },
        { nodeID = 9, name = "zzOLDPowderfuse Port, Riverglades", x = 48.6, y = 43.3, faction = 2 },
    })
    check(#R:FlightPoints() == 1, "the client's retired zzOLD nodes are not flight masters")

    R.said = {}
    local said = R:CheckFlight("tick")
    check(said ~= nil and said.name == "Darkshire", "standing next to it, the addon says so")
    check(R:CheckFlight("tick") == nil, "and does not say it twice")

    -- /fg fp points the arrow at it and hands the marker back on arrival
    ns.Commands:Run("fp")
    check(ns.Navigation.override == "flightpoint" and ns.Navigation.target.owner == "fp",
        "/fg fp takes the marker (" .. tostring(ns.Navigation.target and ns.Navigation.target.label) .. ")")
    ns.Commands:Run("fp off")
    check(ns.Navigation.override == nil, "/fg fp off gives it back")

    -- standing at a flight master teaches us what we already have
    MOCK_TAXIMAP({ { name = "Darkshire", state = 0 }, { name = "Menethil Harbor", state = 1 }, { name = "Grom'gol", state = 2 } })
    check(ns.char.flightpoints["Darkshire"] == true and ns.char.flightpoints["Menethil Harbor"] == true,
        "the open flight map says which ones are ours")
    check(ns.char.flightpoints["Grom'gol"] == nil, "and an unreachable one is not")
    check(#R:FlightPoints() == 0, "so once taken it is gone from the list")

    -- switched off, nothing is said
    ns.Commands:Run("remind flight off")
    ns.char.flightpoints = {}
    MOCK_TAXI(map, { { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, isUndiscovered = false, faction = 2 } })
    R.said = {}
    check(R:CheckFlight("tick") == nil, "/fg remind flight off keeps it quiet")
    ns.Commands:Run("remind flight on")

    -- "New flight path discovered!" marks the one we just took
    ns.char.flightpoints = {}
    MOCK_TAXI(map, { { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, faction = 2 } })
    MOCK_FIRE("UI_INFO_MESSAGE", 1, "New flight path discovered!")
    check(ns.char.flightpoints["Darkshire"] == true, "taking one on foot is noticed too")
    check(#R:FlightPoints() == 0, "and it leaves the list")
    ns.char.flightpoints = {}

    -- the trainer: a visit is remembered, and two levels later it nudges
    ns.char.lastTrained = nil
    MOCK.level = 20
    ns.Player.cache.level = 20
    MOCK_TRAINER(5165, "Bink")
    check(ns.char.lastTrained == 20, "training is noted at the level it happened (" .. tostring(ns.char.lastTrained) .. ")")
    local t = R:KnownTrainer()
    check(t and t.name == "Bink" and t.map ~= nil, "and so is where the trainer was (" .. tostring(t and t.name) .. ")")
    check(R:TrainerDue(21) == nil, "one level later there is nothing to say")
    local due = R:TrainerDue(22)
    check(due == 2, "two levels later there is (" .. tostring(due) .. ")")
    MOCK.level = 22
    ns.Player.cache.level = 22
    local line = R:TrainerNudge(22)
    check(line and line:find("last trained at 20", 1, true) and line:find("Bink", 1, true), "the nudge names both: " .. tostring(line))
    ns.Commands:Run("remind trainer off")
    check(R:TrainerNudge(24) == nil, "/fg remind trainer off keeps it quiet too")
    ns.Commands:Run("remind trainer on")

    ns.char.lastTrained = nil
end)

-- ---- dungeons: the guide steps aside -----------------------------------------------------------
-- (Ilya, 2026-09-22: "when in a dungeon, we need to disable the quest guide, so it doesnt interfere")
section("dungeons: the guide steps aside", function()
    local I = ns.Instance
    ns.UI:Show()

    MOCK_INSTANCE("party")
    check(I:Inside() == true, "the addon knows it is in a dungeon")
    check(ns.UI:AllHidden() == true and ns.UI:IsSuspended("dungeon"), "so everything is put away")
    check(ns.db.ui.hiddenAll ~= true, "without touching the hide-everything setting")
    check(not ns.UI:Create():IsShown(), "the guide window stays down inside")

    MOCK_INSTANCE(nil)
    check(ns.UI:AllHidden() == false, "walking out brings it back")
    check(ns.UI:Create():IsShown(), "the guide window returns outside")

    -- a battleground counts, a city does not
    MOCK_INSTANCE("pvp")
    check(ns.UI:AllHidden() == true, "a battleground is no place for a levelling guide either")
    MOCK_INSTANCE("none")
    check(ns.UI:AllHidden() == false, "out again")

    -- and the player can keep it up if they want
    ns.Commands:Run("dungeon off")
    MOCK_INSTANCE("party")
    check(ns.UI:AllHidden() == false, "/fg dungeon off keeps the guide up inside (" .. tostring(ns.UI:AllHidden()) .. ")")
    ns.Commands:Run("dungeon on")
    check(ns.UI:AllHidden() == true, "and turning it back on puts it away again")
    MOCK_INSTANCE(nil)

end)

-- ---- an alternate route: listed under its own name, never the default, followed once chosen ----
-- (forever-codex ships TUGs' route beside ours as kind = "alternate"; a player must choose it)
section("an alternate route: listed under its own name, never the default, followed once chosen", function()
    local KEY = "GEN_ALLIANCE_TUGSHUMAN"
    local routeBefore, activeBefore, levelBefore = ns.char.route, G.active and G.active.id, MOCK.level
    ns.char.route = nil
    -- a level our own route has a chapter for, so leaving it has somewhere to go back to
    MOCK.level = 20
    ns.Player.cache.level = 20
    for n, name in ipairs({ "01_ELWYNN_FOREST", "02_WESTFALL" }) do
        ns.RegisterGuide({ id = KEY .. "_" .. name, name = n .. ". Alternate " .. name, version = 1, kind = "alternate", routeLabel = "Human (TUGs)",
            faction = "Alliance", race = { "Human" }, minLevel = 1, maxLevel = 60, map = 1429, zone = "Elwynn Forest",
            steps = { { type = "NOTE", text = "Kill 8 boars now." } } })
    end

    local alt
    for _, r in ipairs(G:Routes()) do if r.key == KEY then alt = r end end
    need(alt ~= nil, "the alternate route is listed")
    check(alt.label == "Human (TUGs)", "it is listed under its routeLabel (" .. tostring(alt.label) .. ")")
    check(not alt.mine, "it is not the race's own route, though its chapters are for the race")
    local current = G:CurrentRoute()
    check(current ~= nil and current.key ~= KEY, "the race's own route stays the default (" .. tostring(current and current.key) .. ")")
    local pick = G:AutoPick()
    check(pick ~= nil and G:RouteOf(pick) ~= KEY, "auto-pick never lands on it, though it fits the level and the zone better (" .. tostring(pick and pick.id) .. ")")
    G:Activate(KEY .. "_01_ELWYNN_FOREST", true); settle()
    check(G:OffRouteChapter() ~= nil, "opening one of its chapters without choosing the route is off-route")

    local r = G:ChooseRoute("Human (TUGs)")
    check(r ~= nil and ns.char.route == KEY and G:CurrentRoute().key == KEY, "choosing it by its label follows it (" .. tostring(ns.char.route) .. ")")
    local chosen = G:AutoPick()
    check(chosen ~= nil and G:RouteOf(chosen) == KEY, "once chosen, auto-pick stays on it (" .. tostring(chosen and chosen.id) .. ")")
    check(G:OffRouteChapter() == nil, "and its chapters are no longer off-route")
    ns.Commands:Run("path race")
    check(ns.char.route == nil and G:CurrentRoute().key ~= KEY, "/fg path race goes back to the race's own route")

    ns.char.route = routeBefore
    MOCK.level = levelBefore
    ns.Player.cache.level = levelBefore
    if activeBefore then G:Activate(activeBefore, true) end
    G:Reset(); settle()
end)

-- ---- a saved route or chapter the addon no longer ships ----------------------------------------
-- (2026-10-04: the addon ships TUGs' routes in place of ours; a character saved on one of ours logs in)
section("a saved chapter whose route is gone: the route the character follows now, at its level", function()
    local before = { route = ns.char.route, active = ns.char.activeGuide, auto = ns.char.autoPickGuide, level = MOCK.level }
    MOCK.level = 20
    ns.Player.cache.level = 20
    ns.char.route = "GEN_ALLIANCE_RETIRED"
    ns.char.activeGuide = "GEN_ALLIANCE_RETIRED_05_WETLANDS"
    ns.char.autoPickGuide = false
    need(G.registry[ns.char.activeGuide] == nil, "the saved chapter is not registered")

    G:OnEnable(); settle()
    check(ns.char.route == nil, "the saved route no longer shipped is forgotten (" .. tostring(ns.char.route) .. ")")
    local want = G:RouteChapterForLevel()
    need(want ~= nil, "the race's own route has a chapter for level 20")
    check(G.active ~= nil and G.active.id == want.id, "the character is on its route's chapter for its level, not left without a guide ("
        .. tostring(G.active and G.active.id) .. ", want " .. tostring(want.id) .. ")")
    check(G:CurrentRoute().mine, "and that route is its race's own")

    -- a saved route that still ships is kept
    ns.char.route = G:CurrentRoute().key
    G:OnEnable(); settle()
    check(ns.char.route == G:CurrentRoute().key, "a saved route the addon still ships is kept")

    ns.char.route, ns.char.autoPickGuide = before.route, before.auto
    MOCK.level = before.level
    ns.Player.cache.level = before.level
    if before.active and G.registry[before.active] then G:Activate(before.active) end
    G:Reset(); settle()
end)

-- ---- a dungeon's own guide: listed apart, never auto-picked, back to the chapter afterwards ----
section("a dungeon's own guide: listed apart, never auto-picked, back to the chapter afterwards", function()
    local CHAPTER = "GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST"
    local function dungeon(id, quest)
        ns.RegisterGuide({ id = id, name = id, version = 1, kind = "dungeon", faction = "Alliance", minLevel = 1, maxLevel = 60, map = 1429, zone = "Elwynn Forest",
            steps = {
                { type = "ACCEPT", quest = quest, questName = "Into the Hold", map = 1429, x = 40, y = 40 },
                { type = "TURNIN", quest = quest, questName = "Into the Hold", map = 1429, x = 40, y = 40 },
            } })
    end
    dungeon("DUNGEON_ALLIANCE_TEST_HOLD", 99901)
    dungeon("DUNGEON_ALLIANCE_TEST_DEEPS", 99902)

    check(G:IsDungeon(G:Get("DUNGEON_ALLIANCE_TEST_HOLD")), "a guide of kind dungeon is a dungeon guide")
    check(not G:IsDungeon(G:Get(CHAPTER)), "a levelling chapter is not")
    local listed = {}
    for _, g in ipairs(G:Dungeons()) do listed[g.id] = true end
    check(listed.DUNGEON_ALLIANCE_TEST_HOLD and not listed[CHAPTER], "the Dungeons list holds dungeon guides only")
    local pick = G:AutoPick()
    check(pick ~= nil and not G:IsDungeon(pick), "auto-pick never lands on a dungeon guide, even one covering every level (" .. tostring(pick and pick.id) .. ")")

    -- finishing the dungeon guide goes back to the chapter it was opened from
    G:Activate(CHAPTER, true); settle()
    G:Activate("DUNGEON_ALLIANCE_TEST_HOLD", true); settle()
    MOCK_ACCEPT(99901, "Into the Hold", {}); settle()
    MOCK_TURNIN(99901); settle()
    check(G.active and G.active.id == CHAPTER, "finishing the dungeon guide returns to the chapter left (" .. tostring(G.active and G.active.id) .. ")")

    -- /fg resume goes back before the run is done
    G:Activate("DUNGEON_ALLIANCE_TEST_DEEPS", true); settle()
    ns.Commands:Run("resume")
    check(G.active and G.active.id == CHAPTER, "/fg resume returns to the chapter (" .. tostring(G.active and G.active.id) .. ")")

    -- opening another chapter by hand forgets the way back
    G:Activate("DUNGEON_ALLIANCE_TEST_DEEPS", true); settle()
    G:Activate(chapterId("GEN_ALLIANCE_HUMAN_03_"), true); settle()
    check(ns.char.returnGuide == nil, "choosing a chapter by hand clears the chapter to return to")
    G:Activate(CHAPTER, true); settle()
end)

-- ---- dungeon status and the Dungeon Quests panel: each dungeon, its quests, and where they stand ----
section("dungeon status and the Dungeon Quests panel: each dungeon, its quests, and where they stand", function()
    local D = ns.Dungeons
    local levelBefore = ns.Player:GetLevel()
    ns.RegisterGuide({ id = "DUNGEON_ALLIANCE_TEST_BADGE", name = "Test Badge 15-22", version = 1, kind = "dungeon", faction = "Alliance", minLevel = 15, maxLevel = 22, map = 1436, zone = "Westfall",
        steps = {
            { type = "ACCEPT", quest = 99911, questName = "Badge One", npcName = "Gryan Stoutmantle", map = 1436, zone = "Westfall", x = 56.2, y = 47.6 },
            { type = "ACCEPT", quest = 99912, questName = "Badge Two", npcName = "Wilder Thistlenettle", map = 1453, zone = "Stormwind City", x = 65.2, y = 21.2 },
            { type = "NOTE", text = "Find a group for Test Badge", map = 1436, zone = "Westfall", x = 42.5, y = 71.7 },
            { type = "ACCEPT", quest = 99913, questName = "Given Inside", map = 1436, zone = "Westfall", x = 42.5, y = 71.7 },
            { type = "TURNIN", quest = 99911, questName = "Badge One", map = 1436, x = 56.2, y = 47.6 },
            { type = "TURNIN", quest = 99912, questName = "Badge Two", map = 1453, x = 65.2, y = 21.2 },
            { type = "TURNIN", quest = 99913, questName = "Given Inside", map = 1436, x = 56.2, y = 47.6 },
        } })
    local g = G:Get("DUNGEON_ALLIANCE_TEST_BADGE")

    MOCK_LEVEL(10); settle()
    check(D:Status(g).state == "later", "five levels short: not on the radar yet (" .. D:Status(g).state .. ")")
    MOCK_LEVEL(14); settle()
    local st = D:Status(g)
    check(st.total == 2 and st.have == 0 and st.state == "upcoming", "a level short: upcoming, the two quests given outside counted (" .. st.have .. "/" .. st.total .. " " .. st.state .. ")")

    MOCK_LEVEL(15); settle()
    MOCK_ACCEPT(99911, "Badge One", {}); settle()
    check(D:Status(g).have == 1 and D:Status(g).state == "gathering", "one picked up: gathering")
    MOCK_ACCEPT(99912, "Badge Two", {}); settle()
    check(D:Status(g).state == "ready", "all picked up at the level: ready (" .. D:Status(g).state .. ")")

    ns.QuestGuide:Refresh()

    -- the Dungeon Quests button opens a panel under the guide: pick a dungeon, see its quests,
    -- and the guide stays on the step it was on
    local f = ns.QuestGuide.frame
    local activeBefore, stepBefore = G.active, G.current
    f.unknownBtn:GetScript("OnClick")(f.unknownBtn)
    f.dungeonsBtn:GetScript("OnClick")(f.dungeonsBtn)
    local drawer = f.dungeons
    check(drawer and drawer:IsShown() and not f.extra:IsShown(), "Dungeon Quests opens its panel and closes Unknown Quests")
    local function dungeonRow()
        for i, e in ipairs(drawer.list.entries) do if e.guideID == g.id then return drawer.list.rows[i] end end
    end
    local row = dungeonRow()
    check(row ~= nil and (row.entry.subtitle or ""):find("2/2 quests  ·  ready", 1, true), "the panel lists the dungeons with their quest count and readiness")
    row:GetScript("OnClick")(row, "LeftButton")
    local lines = {}
    for _, e in ipairs(drawer.list.entries) do lines[#lines + 1] = (e.title or "") .. " - " .. (e.subtitle or "") end
    local body = table.concat(lines, "\n")
    check(body:find("Badge One - in your log", 1, true), "picking a dungeon lists its quests and where they stand (" .. body .. ")")
    check(body:find("Given Inside - given inside", 1, true), "and the quests given inside the dungeon")
    check(G.active == activeBefore and G.current == stepBefore, "picking a dungeon leaves the guide where it was")
    drawer.waypoint:GetScript("OnClick")(drawer.waypoint)
    local t = ns.Navigation.target
    check(t and t.owner == "dungeon" and math.abs(t.x - 42.5) < 0.01 and math.abs(t.y - 71.7) < 0.01, "Waypoint points at the entrance")
    drawer.back:GetScript("OnClick")(drawer.back)
    check(drawer.guide == nil and drawer.list.entries[1] and drawer.list.entries[1].guideID ~= nil, "Back returns to the dungeon list")
    MOCK_LEVEL(22); settle()
    check(D:Status(g).state == "late" and (dungeonRow().entry.subtitle or ""):find("hand in by 22", 1, true),
        "at the full-XP limit the panel says to hand in (" .. tostring(dungeonRow().entry.subtitle) .. ")")
    MOCK_TURNIN(99911); MOCK_TURNIN(99912); MOCK_ACCEPT(99913, "Given Inside", {}); MOCK_TURNIN(99913); settle()
    check(D:Status(g).state == "done" and dungeonRow().entry.state == "done", "a finished dungeon shows as done in the panel")
    f.dungeonsBtn:GetScript("OnClick")(f.dungeonsBtn)
    check(not drawer:IsShown(), "the Dungeon Quests button closes its panel again")
    ns.UI:RefreshPicker()
    local pickerDungeon = false
    for _, r in ipairs(ForeverGuidePicker.rows) do if r:IsShown() and r.guideID and G:IsDungeon(G:Get(r.guideID)) then pickerDungeon = true end end
    check(not pickerDungeon, "the guide picker no longer switches to a dungeon guide")

    MOCK_LEVEL(levelBefore); settle()
end)

-- ---- flight path steps: learnt at the flight master, skipped when already known ----------------
section("flight path steps: learnt at the flight master, skipped when already known", function()
    local R = ns.Reminders
    local known = ns.char.flightpoints
    local function flightGuide(id, npc, name, x, y)
        ns.RegisterGuide({ id = id, name = id, version = 1, faction = "Alliance", minLevel = 1, maxLevel = 60, map = 1436, zone = "Westfall",
            steps = {
                { type = "FLIGHTPATH", npc = npc, npcName = name, map = 1436, zone = "Westfall", x = x, y = y },
                { type = "ACCEPT", quest = 99921, questName = "After the flight", map = 1436, x = 56, y = 47 },
            } })
    end
    flightGuide("TEST_FLIGHTPATH_THOR", 523, "Thor", 56.55, 52.64)
    flightGuide("TEST_FLIGHTPATH_AGAIN", 523, "Thor", 56.55, 52.64)
    flightGuide("TEST_FLIGHTPATH_MESSAGE", 1571, "Shellei Brondir", 9.49, 59.69)
    ns.char.flightpoints = {}
    MOCK_TAXI(1436, { { nodeID = 4, name = "Sentinel Hill", x = 56.5, y = 52.6, faction = 2 } })

    G:Activate("TEST_FLIGHTPATH_THOR", true); settle()
    check(cur() == 1 and G:GetStepText(step()) == "Get the flight path at Thor", "a flight path step asks for it by the master's name (" .. G:GetStepText(step()) .. ")")
    -- talking to him opens his flight map, which learns the path
    MOCK.npc = { npcID = 523, name = "Thor", level = 55 }
    MOCK_TAXIMAP({ { name = "Sentinel Hill", state = 0 } }); settle()
    check(cur() == 2, "opening his flight map finishes the step (" .. tostring(cur()) .. ")")
    MOCK.npc = nil

    -- the same flight master later on: the path is known, the step is passed over
    check(R:NodeAt(1436, 56.55, 52.64) == "Sentinel Hill", "the flight master's spot names its flight node")
    G:Activate("TEST_FLIGHTPATH_AGAIN", true); settle()
    check(cur() == 2, "a flight path already learnt is not asked for again (" .. tostring(cur()) .. ")")

    -- "New flight path discovered!" while the step is up finishes it too
    G:Activate("TEST_FLIGHTPATH_MESSAGE", true); settle()
    check(cur() == 1, "another master's path is still to learn")
    MOCK_FIRE("UI_INFO_MESSAGE", 0, "New flight path discovered!"); settle()
    check(cur() == 2, "the discovery message finishes the step (" .. tostring(cur()) .. ")")

    ns.char.flightpoints = known
    MOCK_TAXI(1436, {})
    G:Activate("HUMAN_NORTHSHIRE_1_6", true); G:Reset(); settle()
end)

-- ---- profession steps: shown only to characters with that profession (and the skill) ----------
section("profession steps: shown only to characters with that profession (and the skill)", function()
    ns.RegisterGuide({ id = "TEST_PROFESSION", name = "profession", version = 1, faction = "Alliance", minLevel = 1, maxLevel = 60, map = 1426, zone = "Dun Morogh",
        steps = {
            { type = "ACCEPT", quest = 384, questName = "Beer Basted Boar Ribs", profession = "Cooking", map = 1426, x = 46.8, y = 52.4 },
            { type = "ACCEPT", quest = 1578, questName = "Supplying the Front", profession = "Blacksmithing", skill = 30, map = 1455, x = 50, y = 50 },
            { type = "ACCEPT", quest = 99931, questName = "Everyone's quest", map = 1426, x = 46, y = 52 },
        } })
    local steps = G:Get("TEST_PROFESSION").steps
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[1]) == false and G:StepApplies(steps[2]) == false, "no professions: profession steps do not apply")
    check(G:StepApplies(steps[3]) == true, "an ordinary step still does")
    MOCK_SKILLS({ { name = "Cooking", rank = 1 }, { name = "Blacksmithing", rank = 12 } }); settle()
    check(G:StepApplies(steps[1]) == true, "a cook sees the cooking step")
    check(G:StepApplies(steps[2]) == false, "blacksmithing at 12 is short of the 30 the step needs")
    MOCK_SKILLS({ { name = "Blacksmithing", rank = 30 } }); settle()
    check(G:StepApplies(steps[2]) == true and G:StepApplies(steps[1]) == false, "at 30 it shows, and dropping cooking hides the cooking step")
    -- a client that lists no skills at all: show the step rather than hide what the player may have
    local num = _G.GetNumSkillLines
    _G.GetNumSkillLines = nil
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[1]) == true, "without a skill list the step shows")
    -- WoW Forever: C_SkillInfo, one table per skill line (Blizzard_UIPanels_Game/Camelot/SkillsFrame.lua)
    local lines = {}
    _G.C_SkillInfo = {
        GetNumSkillLines = function() return #lines end,
        GetSkillLineInfo = function(i) return lines[i] end,
    }
    local info = _G.GetSkillLineInfo
    _G.GetNumSkillLines, _G.GetSkillLineInfo = nil, nil
    lines = { { skillID = 0, name = "Professions", isHeader = true, isCollapsed = false, rank = 0, maxRank = 0 } }
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[1]) == false and G:StepApplies(steps[2]) == false, "Forever skill info, no professions: profession steps do not apply")
    lines[2] = { skillID = 185, name = "Kochkunst", isHeader = false, isCollapsed = false, rank = 15, maxRank = 75 }   -- Cooking, German client
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[1]) == true and G:StepApplies(steps[2]) == false, "Forever skill info: a cook sees the cooking step (matched by skill ID, whatever the name)")
    lines[3] = { skillID = 164, name = "Blacksmithing", isHeader = false, isCollapsed = false, rank = 29, maxRank = 75 }
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[2]) == false, "Forever skill info: blacksmithing at 29 is short of 30")
    lines[3].rank = 30
    MOCK_SKILLS({}); settle()
    check(G:StepApplies(steps[2]) == true, "Forever skill info: at 30 the step shows")
    _G.C_SkillInfo = nil
    _G.GetNumSkillLines, _G.GetSkillLineInfo = num, info
    MOCK_SKILLS({}); settle()
end)

-- ---- quest items you click: a button on the step's row, and the target key uses them ------------
section("quest items you click: a button on the step's row, and the target key uses them", function()
    MOCK_LEVEL(40); settle()
    MOCK.itemSpells = MOCK.itemSpells or {}
    ns.RegisterGuide({ id = "AUDIT_USEITEM", name = "use item", steps = {
        { type = "ACCEPT", quest = 992 },
        { type = "COMPLETE", quest = 992 },     -- Gadgetzan Water Survey: use the widget at the pool
        { type = "TURNIN", quest = 992 },
        { type = "ACCEPT", quest = 55 },
        { type = "KILL", quest = 55 },          -- Morbent Fel: use Morbent's Bane on him, then kill him
        { type = "TURNIN", quest = 55 },
        { type = "NOTE", text = "filler" },
        { type = "ACCEPT", quest = 123 },       -- The Collector: started by right-clicking the schedule
        { type = "TURNIN", quest = 123 },
        { type = "ACCEPT", quest = 99931 },     -- a Forever quest the database does not know
        { type = "COMPLETE", quest = 99931 } } })
    for _, q in ipairs({ 992, 55, 123, 99931 }) do if ns.Quest:IsOnQuest(q) then MOCK_ABANDON(q) end end
    settle()
    G:Activate("AUDIT_USEITEM", true); settle()
    local function macro() return ForeverGuideTargetButton:GetAttribute("macrotext") or "" end
    local function refresh() ns.MobMarker:Scan() ns.QuestGuide:Refresh() end
    local btn = function() return rawget(_G, "ForeverGuideItemButton") end
    local function activeEntry()
        for _, e in ipairs(ns.QuestGuide.frame.list.entries) do if e.state == "active" then return e end end
    end
    local function where() return " (" .. tostring(G.active and G.active.id) .. " step " .. tostring(cur()) .. " " .. tostring(step() and step().type) .. " note=" .. tostring(G.note) .. ")" end

    -- use it at a place: the widget at the pool
    MOCK_ACCEPT(992, "Gadgetzan Water Survey", { { text = "Tapped Dowsing Widget: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } }); settle()
    G:SetStep(2); settle(); refresh()
    need(step().type == "COMPLETE" and step().quest == 992, "use-item test: on the survey step" .. where())
    check(G:StepUseItem(step()) == nil, "the widget is not in the bags: nothing to click")
    check(not macro():find("/use", 1, true), "...and the target key uses nothing (" .. macro():gsub("\n", " | ") .. ")")
    check(not (btn() and btn():IsShown()), "...and no item button shows")

    MOCK.items[8584] = 1; MOCK.itemSpells[8584] = "Collect Sample"
    MOCK_FIRE("BAG_UPDATE_DELAYED"); settle(); refresh()
    check(G:StepUseItem(step()) == 8584, "the widget is in the bags and has a Use effect: it is the step's item (" .. tostring(G:StepUseItem(step())) .. ")")
    check(activeEntry() and activeEntry().useItem == 8584, "the step's row carries the item")
    check(btn() and btn():IsShown() and btn():GetAttribute("type") == "item" and btn():GetAttribute("item") == "item:8584",
        "a secure item button on the row uses the widget (" .. tostring(btn() and btn():GetAttribute("item")) .. ")")
    check(macro() == "/use item:8584", "no mobs to target: the target key just uses the item (" .. macro():gsub("\n", " | ") .. ")")

    -- the option: the key goes back to targeting only; the row button stays
    ns.QuestGuideConfig.SetToggle("skulluse", false); refresh()
    check(not macro():find("/use", 1, true), "with the option off the target key does not use the item")
    check(btn():IsShown(), "...the row button is still there")
    ns.QuestGuideConfig.SetToggle("skulluse", true); refresh()
    check(macro():find("/use item:8584", 1, true) ~= nil, "option back on: the key uses it again")

    -- combat locks secure buttons: nothing changes until it ends
    MOCK.inCombat = true
    MOCK_PROGRESS(992, 1, 1); settle(); refresh()
    check(btn():GetAttribute("item") == "item:8584" and btn():IsShown(), "in combat the item button is left alone")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle(); refresh()
    check(G:StepUseItem(G:Get("AUDIT_USEITEM").steps[2]) == nil, "the objective is done: the widget is no longer the step's item")
    check(not btn():IsShown(), "...and once combat ends the button goes away")
    check(not macro():find("/use", 1, true), "...and so does the /use in the target key")

    -- use it on a mob: target first, then use
    MOCK_TURNIN(992); settle()
    MOCK.items[7297] = 1; MOCK.itemSpells[7297] = "Morbent's Bane"
    MOCK_ACCEPT(55, "Morbent Fel", { { text = "Morbent Fel slain: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } }); settle()
    G:SetStep(5); settle(); refresh()
    need(step().type == "KILL" and step().quest == 55, "on the Morbent step" .. where())
    local m = macro()
    local t, u = m:find("/targetexact", 1, true), m:find("/use item:7297", 1, true)
    check(t and u and u > t and m:find("Morbent Fel", 1, true), "a use-on-mob item: the key targets the mob, then uses the item (" .. m:gsub("\n", " | ") .. ")")
    check(btn():IsShown() and btn():GetAttribute("item") == "item:7297", "the row button uses Morbent's Bane")

    -- the same item without a Use effect (a letter, a deed): nothing to click
    MOCK.itemSpells[7297] = nil
    MOCK_FIRE("BAG_UPDATE_DELAYED"); settle(); refresh()
    check(G:StepUseItem(step()) == nil and not btn():IsShown(), "an item with no Use effect gets no button")
    MOCK_TURNIN(55); settle()

    -- an item that starts a quest: clicking it offers the quest
    G:SetStep(8); settle(); refresh()
    check(step().type == "ACCEPT" and step().quest == 123 and G:StepUseItem(step()) == nil, "the schedule is not looted yet: nothing to click" .. where())
    MOCK.items[1307] = 1
    MOCK_FIRE("BAG_UPDATE_DELAYED"); settle(); refresh()
    check(G:StepUseItem(step()) == 1307 and btn():IsShown() and btn():GetAttribute("item") == "item:1307", "the schedule is in the bags: the accept step's button starts the quest")
    MOCK.items[1307] = nil

    -- a Forever quest: the client's own quest item is trusted
    MOCK_ACCEPT(99931, "Snowbound Test", { { text = "Snow gathered: 0/5", finished = false, numFulfilled = 0, numRequired = 5 } })
    MOCK.log[99931].specialItem = 99932
    MOCK.items[99932] = 1
    settle(); G:SetStep(11); settle(); refresh()
    need(step().quest == 99931, "on the Forever quest's step" .. where())
    check(G:StepUseItem(step()) == 99932, "the quest log's own item for a quest the database lacks (" .. tostring(G:StepUseItem(step())) .. ")")
    check(macro():find("/use item:99932", 1, true) ~= nil, "...is used by the target key too")
    MOCK_ABANDON(99931); settle(); refresh()
    check(not btn():IsShown(), "quest dropped: the button goes")
    MOCK.items[8584], MOCK.items[7297], MOCK.items[99932] = nil, nil, nil
end)

-- ---- combat: the window is not a protected frame --------------------------------------
-- The secure item and target buttons protect every frame they are parented under or anchored to.
-- The window must not be one of those, or the client blocks its every resize, show and hide in
-- combat (ADDON_ACTION_BLOCKED on ForeverGuideFrame:SetHeight() and :Hide(), from players' BugSack).
section("combat: the window is not a protected frame", function()
    ns.UI:Show(); settle()
    local f = ForeverGuideFrame
    local tb, ib = ForeverGuideTargetButton, ForeverGuideItemButton
    check(not MOCK_IS_PROTECTED(f), "the Quest Guide window is not a protected frame")
    check(tb:GetParent() ~= f and ib:GetParent() ~= f, "the secure buttons are not children of the window")
    check(tb:IsShown(), "the skull button shows with the window")

    local savedHeight = ns.db.ui.height
    local before = f:GetHeight()
    MOCK.blocked = {}
    MOCK.inCombat = true
    MOCK_FIRE("PLAYER_REGEN_DISABLED")
    MOCK_FIRE("BAG_UPDATE_DELAYED"); settle()          -- the debounced refresh from the report
    ns.db.ui.height = 420
    ns.QuestGuide:Layout()
    MOCK.mapOpen = true; WorldMapFrame.hooks.OnShow(); settle()
    MOCK.mapOpen = false; WorldMapFrame.hooks.OnHide(); settle()
    ns.UI:Suspend(true, "dungeon")
    check(not f:IsShown(), "in combat the window can still step aside for a dungeon")
    check(tb.alpha == 0, "...and the skull button it cannot hide goes invisible instead")
    ns.UI:Suspend(false, "dungeon")
    check(f:IsShown() and tb.alpha == 1, "...both come back in combat")
    ns.UI:Toggle()
    check(not f:IsShown(), "in combat the window's key still hides it")
    ns.UI:Toggle()
    check(f:IsShown(), "in combat the window's key still shows it")
    -- the skull button on the bottom edge cannot follow the window in combat, so it holds still
    check(f:GetHeight() == before, "in combat the window keeps its height (" .. tostring(f:GetHeight()) .. ", was " .. tostring(before) .. ")")
    f.scripts.OnDragStart(f)
    check(not f.moving, "in combat the window cannot be dragged")
    f.resizeGrip.scripts.OnMouseDown(f.resizeGrip)
    check(not f.sizing and not f.resizing, "...or resized")
    f.resizeGrip.scripts.OnMouseUp(f.resizeGrip)
    check(ns.db.ui.height == 420, "...and letting go of the grip saves nothing")
    check(#MOCK.blocked == 0, "no blocked actions in combat (" .. table.concat(MOCK.blocked, ", ") .. ")")

    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(f:GetHeight() == 420, "after combat the window takes its new height (" .. tostring(f:GetHeight()) .. ")")
    f.scripts.OnDragStart(f)
    check(f.moving, "...and can be dragged again")
    f.scripts.OnDragStop(f)

    MOCK.inCombat = true
    ns.UI:Hide()
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(not tb:IsShown() and tb.alpha == 1, "after combat the skull button is hidden with the window, not just invisible")
    ns.UI:Show(); settle()
    check(tb:IsShown(), "...and shows again with it")
    ns.db.ui.height = savedHeight
    ns.QuestGuide:Layout()
end)

-- ---- a long guide builds only the rows on screen -------------------------------------
-- WoW never frees a frame, so a row per step would keep a few hundred frames for the session.
section("a long guide builds only the rows on screen", function()
    local f = ns.QuestGuide.frame
    local before = G.active and G.active.id
    G:Activate(chapterId("GEN_ALLIANCE_HUMAN_01_"), true); ns.UI:Refresh(); settle()
    local l = f.list
    local n = #l.entries
    check(n > 100, "the Elwynn chapter lists its whole route (" .. n .. " rows)")
    check(#l.rows <= 30, "only the rows in view have a frame (" .. #l.rows .. " for " .. n .. " entries)")
    check(l.height > 100 * ns.QuestRow.HEIGHT_ONE, "the list still scrolls over the whole guide (" .. l.height .. ")")
    ns.QuestGuide:ScrollToFraction(1); settle()
    local last = l:RowFor(n)
    check(last ~= nil and last:IsShown() and last.entry == l.entries[n], "scrolled to the bottom, the last step has its row")
    check(l:RowFor(1) == nil, "...and the first step, far off screen, has none")
    local shown = 0
    for _, r in ipairs(l.rows) do if r:IsShown() then shown = shown + 1 end end
    check(#l.rows <= 30 and shown > 0, "scrolling reuses the rows (" .. #l.rows .. " frames)")
    ns.QuestGuide:ScrollToFraction(0); settle()
    check(l:RowFor(1) ~= nil and l:RowFor(1).entry == l.entries[1], "back at the top, the first step has its row again")
    if before then G:Activate(before, true) end
    ns.UI:Refresh(); settle()
end)

-- ---- the docs agree with the code ------------------------------------------------------------
-- The README ships in the release zip: every command it names must exist, every command must be in
-- it, and no doc may link a file or heading that is gone. Read as text, never run: several commands
-- change the guide's state.
-- ---- chat: only typed commands and things the player must act on ------------------------------
-- (2026-10-01: "I want to reduce the amount of bullshit sent to chat")
section("picking a guide opens that guide, whatever position is saved", function()
    local G = ns.Guide
    local wasActive, wasMode = G.active and G.active.id, ns.char.mode
    ns.RegisterGuide({ id = "PICK_A", name = "Pick A", next = "PICK_B", steps = {
        { type = "TRAVEL", map = 1429, x = 10, y = 80, text = "a1" }, { type = "TRAVEL", map = 1429, x = 11, y = 80, text = "a2" },
        { type = "TRAVEL", map = 1429, x = 12, y = 80, text = "a3" } } })
    ns.RegisterGuide({ id = "PICK_B", name = "Pick B", steps = { { type = "TRAVEL", map = 1429, x = 20, y = 80, text = "b1" } } })
    local function past() ns.char.guides.PICK_A = { step = 99, done = {}, version = 1 } end   -- another character's position

    -- the bug: activating a chapter whose saved position is past its end bounces to the next one
    past(); G:Activate("PICK_A")
    need(G.active and G.active.id == "PICK_B", "precondition: plain activation chains past a finished position (" .. tostring(G.active and G.active.id) .. ")")

    ns.char.guides.PICK_A = nil; G:Pick("PICK_A")
    local fresh = G.current
    need(G.active and G.active.id == "PICK_A" and fresh ~= nil, "precondition: with nothing saved the pick opens the guide")
    past(); G:Pick("PICK_A")
    check(G.active and G.active.id == "PICK_A" and G.current == fresh,
        "a picked guide opens where a fresh start would, not where another position left it (" .. tostring(G.active and G.active.id) .. " step " .. tostring(G.current) .. ")")
    past(); ns.Commands:Run("guide PICK_A")
    check(G.active and G.active.id == "PICK_A" and G.current == fresh, "/fg guide opens the guide named")

    ns.char.guides.PICK_A = { step = 3, done = { [1] = true, [2] = true }, version = 1 }
    G:Pick("PICK_A")
    check(G.active.id == "PICK_A" and G.current == 3, "steps marked done stay done: the pick opens at the first step still open (" .. tostring(G.current) .. ")")

    ns.char.guides.PICK_A = { step = 4, done = { [1] = true, [2] = true, [3] = true }, version = 1 }
    G:Pick("PICK_A")
    check(G.active and G.active.id == "PICK_A", "a guide picked when it is complete stays open (" .. tostring(G.active and G.active.id) .. ")")

    ns.char.guides.PICK_A = nil
    G:Pick("PICK_A")
    for i = 1, 3 do G:MarkDone(i, "skip") end
    check(G.active and G.active.id == "PICK_B", "finishing a picked guide in play still moves on to the next chapter")

    -- the guide list: clicking a chapter row picks it
    ns.UI:RefreshPicker()
    local picker = ns.UI:CreatePicker()
    local row
    for _, r in ipairs(picker.rows or {}) do
        if r:IsShown() and r.guideID and r.guideID ~= "__auto" and not r.onClick and ns.Guide.registry[r.guideID] then row = r break end
    end
    need(row ~= nil, "the guide list shows a chapter row")
    ns.char.guides[row.guideID] = { step = 9999, done = {}, version = ns.Guide.registry[row.guideID].version or 1 }
    row:GetScript("OnClick")(row)
    check(G.active and G.active.id == row.guideID, "clicking a chapter in the guide list opens that chapter (" .. tostring(G.active and G.active.id) .. " for " .. row.guideID .. ")")

    ns.char.guides.PICK_A, ns.char.guides.PICK_B = nil, nil
    if wasActive then G:Activate(wasActive) end
    ns.char.mode = wasMode
end)

section("chat stays quiet unless the player typed a command", function()
    local G, R = ns.Guide, ns.Run
    local lines = {}
    local realPrint = _G.print
    -- the addon's chat lines (ns.Print, Warn, Error, Debug); the test's own output passes through
    _G.print = function(msg, ...)
        local m = tostring(msg)
        if m:find("ForeverGuide", 1, true) or m:find("[FG]", 1, true) then lines[#lines + 1] = m else realPrint(msg, ...) end
    end
    local function said() local n = #lines lines = {} return n end
    local recordWas, announceWas = ns.db.recordRuns, ns.AutoQuest.Cfg().announce

    ns.RegisterGuide({ id = "QUIET_A", name = "Quiet A", next = "QUIET_B", steps = {
        { type = "TRAVEL", map = 1429, x = 40, y = 60, text = "one" }, { type = "TRAVEL", map = 1429, x = 41, y = 60, text = "two" },
        { type = "TRAVEL", map = 1429, x = 42, y = 60, text = "three" }, { type = "TRAVEL", map = 1429, x = 43, y = 60, text = "four" },
        { type = "TRAVEL", map = 1429, x = 44, y = 60, text = "five" }, { type = "TRAVEL", map = 1429, x = 45, y = 60, text = "six" },
        { type = "TRAVEL", map = 1429, x = 46, y = 60, text = "seven" } } })
    ns.RegisterGuide({ id = "QUIET_B", name = "Quiet B", steps = { { type = "TRAVEL", map = 1429, x = 50, y = 60, text = "b" } } })
    said()

    -- play: picking a guide, the window's Skip, Later and Do now, finishing a chapter
    G:Activate("QUIET_A")
    G:Skip()
    G:Later()
    G:DoNow(G.current and G:NextIdx(G.current) or 1)
    for _, item in ipairs(ns.QuestGuide:StepMenuItems(G.current)) do if item[1] == "Skip" then item[2]() end end
    G:Back()
    for i = 1, #G.active.steps do G:MarkDone(i, "skip") end
    check(G.active and G.active.id == "QUIET_B", "finishing a chapter moves on to the next")
    check(said() == 0, "guide play prints nothing: the window shows it")

    -- a dungeon, auto accept and turn-in, a run recorded to a full segment and sent
    MOCK_INSTANCE("party")
    MOCK_INSTANCE(nil)
    ns.AutoQuest.Cfg()
    check(ns.AutoQuest.Cfg().announce == false, "auto accept and turn-in announce nothing by default")
    ns.db.recordRuns = true
    ns.char.run = nil
    R:Start()
    while R:State() == "recording" do ns.Events:Fire("FG_OBJECTIVE_PROGRESS", 7104, 1, 1, 2, false, "x") end
    R:Send()
    rawget(_G, "ForeverGuideShare"):Hide()
    local notice = rawget(_G, "ForeverGuideRunNotice")
    if notice then notice:Hide() end
    check(said() == 0, "a dungeon, and a run filling its segment and being sent, print nothing: the dialogs and windows speak")

    -- a typed command answers
    ns.RegisterGuide({ id = "QUIET_C", name = "Quiet C", steps = {
        { type = "TRAVEL", map = 1429, x = 60, y = 60, text = "c1" }, { type = "TRAVEL", map = 1429, x = 61, y = 60, text = "c2" } } })
    ns.Commands:Run("guide QUIET_C")
    check(said() == 1, "/fg guide answers with one line")
    ns.Commands:Run("skip")
    check(said() == 1, "/fg skip answers with one line")

    _G.print = realPrint
    ns.char.run, ns.db.recordRuns = nil, recordWas
    ns.AutoQuest.Cfg().announce = announceWas
end)

section("XP buff indicators: each icon shows while its buff is missing", function()
    local XB = ns.XPBuffs
    need(XB ~= nil, "the XPBuffs module loads")
    local FOOD, BAG = 1243969, 429959
    local levelWas = MOCK.level
    local function refresh() MOCK_FIRE("UNIT_AURA", "player", {}) MOCK_ADVANCE(1) end
    local function shown(key) local f = XB.frames and XB.frames[key] return f ~= nil and f:IsShown() end
    MOCK.level, MOCK.auras = 12, {}
    XB.Cfg().food.enabled, XB.Cfg().bag.enabled = true, true

    local show, stacks, needed = XB:Missing("food")
    check(show == true and stacks == 0 and needed == 1, "no food buff: the food icon shows")
    show, stacks, needed = XB:Missing("bag")
    check(show == true and stacks == 0 and needed == 3, "no Well-Rested: the bag icon shows at 0 of 3")
    refresh()
    need(shown("food") and shown("bag"), "a UNIT_AURA for the player puts both icons on screen")
    check(XB.frames.bag.count:GetText() == "0/3" and XB.frames.food.count:GetText() == "", "the bag icon counts stacks, the food icon does not")

    MOCK.auras[1248422] = { applications = 0 }          -- Goretusk Liver Pie's Well Fed (Strength, +5% XP)
    refresh()
    check(not shown("food") and shown("bag"), "a Well Fed that carries the XP bonus hides only the food icon")
    MOCK.auras[1248422] = nil
    refresh()
    check(shown("food"), "the Well Fed buff gone: the food icon is back")
    MOCK.auras[1225778] = { applications = 0 }          -- Prowler Steak's Well Fed: no XP line
    refresh()
    check(shown("food"), "a Well Fed without the XP bonus does not count")
    MOCK.auras[1225778] = nil
    MOCK.auras[FOOD] = { applications = 0 }
    refresh()
    check(not shown("food") and shown("bag"), "Well Fed XP Boost itself counts too")

    MOCK.auras[BAG] = { applications = 2 }
    refresh()
    check(shown("bag") and XB.frames.bag.count:GetText() == "2/3", "two stacks of Well-Rested: the bag icon stays, at 2/3")
    MOCK.auras[BAG] = { applications = 3 }
    refresh()
    check(not shown("bag"), "three stacks of Well-Rested: the bag icon hides")
    -- in combat the client withholds auras: the icons keep their state, whether it says so or not
    MOCK.auras[FOOD] = { applications = 0 }
    refresh()
    need(not shown("food") and not shown("bag"), "both buffs up: no icons")
    MOCK.secretAuras = { [BAG] = true, [FOOD] = true }
    for _, id in ipairs(XB.BUFFS.food.spellIDs) do MOCK.secretAuras[id] = true end
    refresh()
    check(not shown("food") and not shown("bag"), "auras withheld (no values returned): the icons stay hidden")
    MOCK.secretAurasAnnounced = true
    refresh()
    check(not shown("food") and not shown("bag"), "auras the client calls secret: the icons stay hidden")
    MOCK.secretAuras, MOCK.secretAurasAnnounced = {}, nil
    MOCK.auras[FOOD] = nil
    refresh()
    check(shown("food") and not shown("bag"), "readable again: the food buff gone shows its icon, the bag still at 3 stays hidden")

    MOCK.auras = {}
    refresh()
    check(shown("food") and shown("bag"), "the buffs running out bring both icons back")
    ns.Commands:Run("remind food off")
    check(XB:Missing("food") == false and not shown("food") and shown("bag"), "/fg remind food off hides the food icon and keeps the bag's")
    ns.Commands:Run("remind food on")
    check(shown("food"), "/fg remind food on brings it back")

    MOCK.level = 60
    refresh()
    check(XB:Missing("food") == false and XB:Missing("bag") == false and not shown("food") and not shown("bag"),
        "at max level neither icon shows")
    MOCK.level, MOCK.xpDisabled = 30, true
    refresh()
    check(not shown("food") and not shown("bag"), "with XP turned off neither icon shows")

    -- both icons sit in one holder: dragging either moves the holder, and one position is saved
    local h = XB:Holder()
    check(XB.frames.food.parent == h and XB.frames.bag.parent == h, "both icons sit in the one holder")
    MOCK.shift = true
    XB.frames.bag:GetScript("OnDragStart")(XB.frames.bag)
    check(h.moving == true and not XB.frames.bag.moving, "shift-dragging the bag icon moves the holder, not the icon alone")
    XB.frames.bag:GetScript("OnDragStop")(XB.frames.bag)
    MOCK.shift = nil
    check(not h.moving and type(XB.Cfg().point) == "table" and XB.Cfg().food.point == nil and XB.Cfg().bag.point == nil,
        "dropping saves one position for both icons")
    ns.Commands:Run("remind buffs reset")
    check(XB.Cfg().point == nil, "/fg remind buffs reset clears it")

    MOCK.level, MOCK.xpDisabled, MOCK.auras, MOCK.secretAuras = levelWas, nil, {}, {}
    for _, f in pairs(XB.frames) do f:Hide() end
end)

-- (2026-10-06: quest 982's sunken lockboxes open only with the game's Interact Key, which Forever
--  ships for gamepads only)
section("the Interact Key: on by default, and ForeverGuide's own key for it, set in the options or the bindings menu", function()
    local MM = ns.MobMarker
    check(MOCK.cvars.softTargetInteract == "3", "at login the Interact Key is switched on for keyboard (" .. tostring(MOCK.cvars.softTargetInteract) .. ")")
    ns.Options:Create()
    local box, row = ns.Options:GetWidget("qg_interact"), ns.Options:GetWidget("qg_interactkey")
    need(box ~= nil and row ~= nil, "the options panel has the Interact Key switch and its key")
    ns.Options:Refresh()
    check(box:GetChecked() == true, "the switch shows the game's setting")

    box:SetChecked(false); box:GetScript("OnClick")(box)
    check(MOCK.cvars.softTargetInteract == "1", "switched off: the game's own default comes back (gamepads only)")
    MM:ApplyInteract()
    check(MOCK.cvars.softTargetInteract == "1", "and the next login leaves it off")
    MOCK.inCombat = true
    box:SetChecked(true); box:GetScript("OnClick")(box)
    check(MOCK.cvars.softTargetInteract == "1", "in combat the switch waits")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED")
    check(MOCK.cvars.softTargetInteract == "3", "...and lands once combat ends")

    -- (2026-10-06: "we need to use blizzards modern api that allows mouse and other key binds and displays it")
    local bindingsWas = MOCK.bindings
    MOCK.bindings = {}
    ns.Options:Refresh()
    check(row.label:GetText():find("not bound", 1, true) ~= nil, "no key yet: the row says so (" .. row.label:GetText() .. ")")
    check(row:GetScript("OnKeyDown") == nil and row.keyboard ~= true, "the row never takes the keyboard")
    MOCK.bindings = { ["SHIFT-F"] = "FOREVERGUIDE_INTERACT", BUTTON4 = "CLICK ForeverGuideTargetButton:LeftButton" }
    ns.Options:Refresh()
    check(row.label:GetText():find("Shift-F", 1, true) ~= nil, "the row shows the key as the bindings menu writes it (" .. row.label:GetText() .. ")")
    local target = ns.Options:GetWidget("qg_targetkey")
    need(target ~= nil, "the options panel shows the target key too")
    check(target.label:GetText():find("BUTTON4", 1, true) ~= nil, "a mouse button bound to the target key shows (" .. target.label:GetText() .. ")")

    local sub = MOCK.settingsSubcategories and MOCK.settingsSubcategories["Key Bindings"]
    need(sub ~= nil, "ForeverGuide has a Key Bindings page in the settings")
    check(sub.category.parent == MOCK.settingsCategory and sub.registeredBeforeParent, "under ForeverGuide, registered before ForeverGuide is")
    local listed = {}
    for i, r in ipairs(sub.layout.rows) do listed[i] = MOCK.bindingDefs[r.data.bindingIndex] end
    check(#listed == #MOCK.bindingDefs, "one of the game's binding rows per Bindings.xml entry (" .. #listed .. " of " .. #MOCK.bindingDefs .. ")")
    local seen = {}
    for _, a in ipairs(listed) do seen[a] = true end
    for _, a in ipairs(MOCK.bindingDefs) do check(seen[a], "listed: " .. a) end
    check(listed[1] == "CLICK ForeverGuideTargetButton:LeftButton" and listed[2] == "FOREVERGUIDE_INTERACT", "the target and quest object keys come first")
    check(sub.layout.rows[2].tags[1] == BINDING_NAME_FOREVERGUIDE_INTERACT, "a row is found by its name in the settings search")
    check(row:IsShown(), "with the page there, the row has its button")
    MOCK.settingsOpened = nil
    row:GetScript("OnClick")(row)
    check(MOCK.settingsOpened == sub.category:GetID(), "Key bindings... opens that page (" .. tostring(MOCK.settingsOpened) .. ")")

    -- bound in the game's Key Bindings > AddOns > ForeverGuide instead
    check(BINDING_NAME_FOREVERGUIDE_INTERACT ~= nil, "the entry has a name in Key Bindings > AddOns > ForeverGuide")
    MOCK.bindings = { T = "CLICK ForeverGuideTargetButton:LeftButton" }
    MOCK.bindings.H = "FOREVERGUIDE_INTERACT"
    MOCK_FIRE("UPDATE_BINDINGS")
    check(MOCK.overrides.H == "INTERACTTARGET" and MOCK.overrides.G == nil, "a key bound in the menu interacts (" .. tostring(MOCK.overrides.H) .. ")")
    check(MOCK.overrides.T == nil and MOCK.bindings.T == "CLICK ForeverGuideTargetButton:LeftButton", "the target key stays a key of its own")
    MOCK.inCombat = true
    MOCK.bindings.H, MOCK.bindings.J = nil, "FOREVERGUIDE_INTERACT"
    MOCK_FIRE("UPDATE_BINDINGS")
    check(MOCK.overrides.H == "INTERACTTARGET" and MOCK.overrides.J == nil, "rebound in combat: the change waits")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED")
    check(MOCK.overrides.J == "INTERACTTARGET" and MOCK.overrides.H == nil, "...and lands once combat ends")
    MOCK.bindings = bindingsWas
    MOCK_FIRE("UPDATE_BINDINGS")
    ns.Options:Refresh()
end)

-- ---- TUGs' guides as shipped: a group, Guidelime's start, links, and its step types ----------
-- (2026-10-04: "keep the tugs layout. and maintain that structure")
section("a guide group as TUGs ships it: listed in Guidelime's order, started and linked as Guidelime does", function()
    local before = { active = G.active and G.active.id, char = ns.char.activeGuide, level = MOCK.level, race = MOCK.race, route = ns.char.route }
    local GROUP = "TUGs Test Guides"
    local function reg(id, name, minL, maxL, faction, next, steps)
        ns.RegisterGuide({ id = id, name = name, group = GROUP, source = "TUGs/" .. id .. ".lua", minLevel = minL, maxLevel = maxL,
            faction = faction, next = next, author = "TUGs | The Unprofessional Gamer", steps = steps or { { type = "NOTE", text = name } } })
    end
    reg("TUGT_ELWYNN", "6-9 Elwynn Forest", 6, 9, "Alliance", nil)
    reg("TUGT_NORTHSHIRE", "1-6 Northshire", 1, 6, "Alliance", "TUGT_ELWYNN")
    reg("TUGT_COLDRIDGE", "1-6 Coldridge Valley", 1, 6, "Alliance", nil)
    reg("TUGT_COOKING", "Cooking", nil, nil, nil, nil)
    reg("TUGT_VALLEY", "1-6 Valley of Trials", 1, 6, "Horde", nil)

    local grp
    for _, gr in ipairs(G:Groups()) do if gr.name == GROUP then grp = gr end end
    need(grp ~= nil, "the group is listed")
    local names = {}
    for _, g in ipairs(grp.guides) do names[#names + 1] = g.name end
    check(table.concat(names, " | ") == "Cooking | 1-6 Coldridge Valley | 1-6 Northshire | 6-9 Elwynn Forest",
        "its guides for this faction, by min level (none first), max level, name: " .. table.concat(names, " | "))

    -- Guidelime's starting guide: Human has none in TUGs, Dwarf starts in Coldridge Valley
    MOCK.level = 1
    ns.Player.cache.level = 1
    local function asRace(race) MOCK.race = { race, race } ns.Player.cache.raceFile = nil end
    asRace("Human")
    local start = G:StartGuide()
    check(start == nil or start.group ~= GROUP, "a Human gets no starting guide from TUGs' titles (" .. tostring(start and start.name) .. ")")
    asRace("Dwarf")
    start = G:StartGuide()
    check(start ~= nil and start.id == "TUGT_COLDRIDGE", "a Dwarf starts in Coldridge Valley (" .. tostring(start and start.id) .. ")")
    asRace("Human")

    -- (2026-10-07: every login opened the list in the middle of the screen.) The list opens only
    -- when the player asks for it; otherwise the guide keeps the character on rails.
    local function listShown() local p = rawget(_G, "ForeverGuidePicker") return p ~= nil and p:IsShown() end
    local function setLevel(n) MOCK.level = n; ns.Player.cache.level = n end
    setLevel(1)
    G:Activate("TUGT_NORTHSHIRE"); settle()
    G:MarkDone(G.current, "test"); settle()
    check(G.active and G.active.id == "TUGT_ELWYNN", "finishing Northshire goes on to the guide it links to (" .. tostring(G.active and G.active.id) .. ")")

    -- a guide with no next: on to the guide for the level, never the list
    setLevel(7)
    G:Reset(); settle()
    G:Activate("TUGT_COLDRIDGE"); settle()
    G:MarkDone(G.current, "test"); settle()
    check(G.active and G.active.id == "TUGT_ELWYNN", "finishing a guide that links to none goes on to the guide for the level ("
        .. tostring(G.active and G.active.id) .. ")")
    check(not listShown(), "...and the guide list stays closed")
    G:MarkDone(G.current, "test"); settle()
    check(G.active and G.active.id == "TUGT_ELWYNN" and tostring(G.note):find("Guides", 1, true) and not listShown(),
        "no other guide for the level: the finished guide stays, its note points to Guides, the list stays closed (" .. tostring(G.note) .. ")")

    -- logging in on that finished guide: no list either
    ns.char.activeGuide = "TUGT_ELWYNN"
    G:OnEnable(); settle()
    check(not listShown() and G.active and G.active.id == "TUGT_ELWYNN", "logging in on a finished guide does not open the list")

    -- a saved guide that is gone: the guide for the level, said once in chat
    ns.char.route = nil
    ns.char.activeGuide = "GEN_ALLIANCE_HUMAN_05_GONE"
    if not G:RouteChapterForLevel() then
        local said, realPrint = {}, ns.Print
        ns.Print = function(msg) said[#said + 1] = tostring(msg) end
        G:OnEnable(); settle()
        ns.Print = realPrint
        check(not listShown(), "logging in on a guide that is gone does not open the list")
        check(G.active and G.active.id == "TUGT_ELWYNN", "...the character is on the guide for its level (" .. tostring(G.active and G.active.id) .. ")")
        check(table.concat(said, "\n"):find("no longer in the addon", 1, true), "...and is told why (" .. table.concat(said, " / ") .. ")")
    end

    -- the player asks: the list opens
    ns.UI:TogglePicker()
    check(listShown(), "the Guides button still opens the list")
    ns.UI:TogglePicker()

    -- zone names as TUGs writes them
    check(ns.DB:MapForZoneName("The Barrens") == 1413 and ns.DB:MapForZoneName("Un'Goro Crater") ~= nil and ns.DB:MapForZoneName("Nowhere") == nil,
        "TUGs' zone names find their maps")

    MOCK.level, MOCK.race, ns.char.route = before.level, before.race, before.route
    ns.Player.cache.level, ns.Player.cache.raceFile = before.level, nil
    ns.char.activeGuide = before.char
    if before.active and G.registry[before.active] then G:Activate(before.active) end
    G:Reset(); settle()
end)

-- (2026-10-06: the list showed only TUGs' 1-22: a group lists every guide of the faction, 1-60)
section("the guide list shows a group's every guide, and scrolls rather than run off the screen", function()
    local before = { level = MOCK.level }
    local GROUP = "TUGs Long Test Guides"
    for k = 1, 20 do
        local lo = (k - 1) * 3
        ns.RegisterGuide({ id = "TUGL_" .. k, name = string.format("%d-%d Part", lo, lo + 3), group = GROUP, source = "TUGs/L" .. k .. ".lua",
            minLevel = lo, maxLevel = lo + 3, faction = "Alliance", steps = { { type = "NOTE", text = "part " .. k } } })
    end
    MOCK.level = 1
    ns.Player.cache.level = 1
    ns.UI:RefreshPicker()
    local picker = ns.UI:CreatePicker()
    local listed = {}
    for _, r in ipairs(picker.rows) do if r:IsShown() and r.guideID then listed[r.guideID] = true end end
    local missing = {}
    for k = 1, 20 do if not listed["TUGL_" .. k] then missing[#missing + 1] = k end end
    check(#missing == 0, "a level-1 character sees the group's guides through 57-60 (missing parts: " .. table.concat(missing, ",") .. ")")

    local screen = UIParent:GetHeight() > 0 and UIParent:GetHeight() or 768
    check(picker:GetHeight() <= screen and picker.scroll ~= nil and picker.scroll:GetScrollChild() == picker.body,
        "the list is no taller than the screen and scrolls (" .. picker:GetHeight() .. " of " .. screen .. ")")
    check(picker.body:GetHeight() > picker.scroll:GetHeight(), "a list longer than the screen scrolls inside it")

    for k = 1, 20 do G.registry["TUGL_" .. k] = nil end
    for k = #G.list, 1, -1 do if G.list[k]:find("^TUGL_") then table.remove(G.list, k) end end
    MOCK.level = before.level
    ns.Player.cache.level = before.level
end)

-- (2026-10-06: "Guide complete! Next chapter: TUGS_ALLIANCE_..." showed an internal id in game)
section("a finished guide names the next chapter by its name, not its id", function()
    local before = { active = G.active and G.active.id, mode = ns.char.mode, char = ns.char.activeGuide, current = G.current }
    ns.RegisterGuide({ id = "NEXTNAME_A", name = "1-6 First Place", next = "NEXTNAME_B", steps = { { type = "NOTE", text = "only step" } } })
    ns.RegisterGuide({ id = "NEXTNAME_B", name = "6-9 Next Place", steps = { { type = "NOTE", text = "b" } } })
    ns.char.guides.NEXTNAME_A = nil
    G:Pick("NEXTNAME_A")
    need(G.active and G.active.id == "NEXTNAME_A", "precondition: the first guide is open")
    G.current = 2
    ns.UI:Show()
    ns.QuestGuide:Refresh()
    local shown = ns.QuestGuide.frame.list.empty:GetText() or ""
    check(shown:find("Next chapter: 6-9 Next Place", 1, true) ~= nil and not shown:find("NEXTNAME_B", 1, true), "the next chapter by name (" .. shown .. ")")

    for _, id in ipairs({ "NEXTNAME_A", "NEXTNAME_B" }) do G.registry[id] = nil ns.char.guides[id] = nil end
    for k = #G.list, 1, -1 do if G.list[k]:find("^NEXTNAME_") then table.remove(G.list, k) end end
    ns.char.mode, ns.char.activeGuide = before.mode, before.char
    if before.active and G.registry[before.active] then G:Activate(before.active) else G.active, G.current = nil, before.current end
    G:Reset(); settle()
end)

section("TUGs' step types complete as Guidelime's do", function()
    local before = { active = G.active and G.active.id, level = MOCK.level, xp = MOCK.xp, xpMax = MOCK.xpMax, skills = MOCK.skills }
    local n = 0
    local function at(steps)
        n = n + 1
        local id = "TUGT_STEPS_" .. n          -- a fresh guide each time: no progress carried over
        ns.RegisterGuide({ id = id, name = "steps", group = "TUGs Test Guides", source = "TUGs/" .. id .. ".lua", steps = steps })
        G:Activate(id); settle()
        return G:GetCurrentStep()
    end
    MOCK.level, MOCK.xp, MOCK.xpMax = 10, 1000, 2000
    ns.Player.cache.level = 10

    -- GRIND with xp: into the level, short of it, a fraction of it
    check(G:IsStepDone({ type = "GRIND", level = 10, xp = 900, xpKind = "plus" }, 1) == true, "[XP10+900] is done 1000 xp into 10")
    check(G:IsStepDone({ type = "GRIND", level = 10, xp = 1100, xpKind = "plus" }, 1) == false, "[XP10+1100] is not")
    check(G:IsStepDone({ type = "GRIND", level = 11, xp = 1000, xpKind = "remaining" }, 1) == true, "[XP11-1000] is done 1000 xp short of 11")
    check(G:IsStepDone({ type = "GRIND", level = 11, xp = 500, xpKind = "remaining" }, 1) == false, "[XP11-500] is not")
    check(G:IsStepDone({ type = "GRIND", level = 10, xp = 0.5, xpKind = "percent" }, 1) == true, "[XP10.5] is done halfway into 10")

    -- SKILL, TRAIN without a spell, the hearthstone, a flight by place
    MOCK_SKILLS({ { name = "First Aid", rank = 19 } })
    check(G:IsStepDone({ type = "SKILL", profession = "First Aid", skill = 20 }, 1) == false, "First Aid 19 is short of [SK First Aid 20]")
    MOCK_SKILLS({ { name = "First Aid", rank = 20 } })
    check(G:IsStepDone({ type = "SKILL", profession = "First Aid", skill = 20 }, 1) == true, "and 20 reaches it")

    local step = at({ { type = "TRAIN" }, { type = "NOTE", text = "after" } })
    MOCK_FIRE("TRAINER_SHOW"); settle()
    check(G:GetCurrentStep() ~= step, "[T] is done when a trainer's window opens")

    MOCK.items[6948] = nil
    step = at({ { type = "USEHEARTH" }, { type = "NOTE", text = "after" } })
    check(G:StepUseItem(step) == nil, "no hearthstone in the bags: the [H] step has nothing to click")
    MOCK.items[6948] = 1
    ns.MobMarker:Scan() ns.QuestGuide:Refresh()
    check(G:StepUseItem(step) == 6948, "the [H] step's item is the player's hearthstone")
    local row
    for _, e in ipairs(ns.QuestGuide.frame.list.entries) do if e.state == "active" then row = e end end
    check(row and row.useItem == 6948, "and its row carries the hearthstone button")
    check(not (ForeverGuideTargetButton:GetAttribute("macrotext") or ""):find("6948", 1, true), "the target key never uses the hearthstone")
    MOCK_FIRE("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 8690); settle()
    check(G:GetCurrentStep() ~= step, "[H] is done when the hearthstone is cast")
    MOCK.items[6948] = nil

    step = at({ { type = "FLY", place = "Stormwind City" }, { type = "NOTE", text = "after" } })
    MOCK.onTaxi = true
    MOCK_FIRE("PLAYER_CONTROL_LOST"); settle()
    MOCK.onTaxi = false
    check(G:GetCurrentStep() ~= step, "[F Place] is done when the flight takes off")
    step = at({ { type = "FLY", place = "Ironforge" }, { type = "NOTE", text = "after" } })
    MOCK_FIRE("PLAYER_CONTROL_LOST")
    check(G:GetCurrentStep() == step, "control lost without a taxi yet: the step waits")
    MOCK.onTaxi = true
    settle()
    MOCK.onTaxi = false
    check(G:GetCurrentStep() ~= step, "...and is done once the client reports the flight a moment later")

    -- [C]: done when the next step is
    step = at({ { type = "NOTE", text = "loot the note", completeWithNext = true }, { type = "GRIND", level = 5 }, { type = "GRIND", level = 99 } })
    check(G:GetCurrentStep() and G:GetCurrentStep().level == 99, "a step marked complete-with-next is passed once the next step is done")

    MOCK.level, MOCK.xp, MOCK.xpMax = before.level, before.xp, before.xpMax
    ns.Player.cache.level = before.level
    MOCK_SKILLS(before.skills)
    if before.active and G.registry[before.active] then G:Activate(before.active) end
    G:Reset(); settle()
end)

-- Every guide that ships is TUGs' as codex writes it (forever-codex docs/TUGS.md): each step type it
-- uses is one the engine documents and completes, and each field one the engine reads.
section("the shipped guides use only step types and fields the engine knows", function()
    local function read(path)
        local f = io.open(root .. path)
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local engine = read("Guide.lua") or ""
    local known = {}
    for t in engine:match("Step types and how they complete:(.-)\n%-%-\n"):gmatch("\n%-%-   (%u+) ") do known[t] = true end
    need(known.ACCEPT and known.TURNIN, "Guide.lua lists its step types")
    local code = ""
    for _, f in ipairs({ "Guide.lua", "Navigation.lua", "UI.lua", "DB.lua", "UI/QuestGuideFrame.lua", "UI/MobMarker.lua", "Editor.lua" }) do code = code .. (read(f) or "") end
    local types, fields, files = {}, {}, 0
    local list = io.popen('find "' .. root .. 'Guides" -type f -name "*.lua" 2>/dev/null')
    for path in list:lines() do
        files = files + 1
        local f = io.open(path)
        local text = f:read("*a")
        f:close()
        local steps = text:match("steps = %[(=*)%[") and text:match("steps = %[=*%[(.*)%]=*%]") or ""
        for t in steps:gmatch('type="(%u+)"') do types[t] = path end
        for k in steps:gmatch("[{,](%a+)=") do fields[k] = path end
    end
    list:close()
    need(files > 0, "the shipped guides are found under Guides/")
    local unknownTypes, unreadFields = {}, {}
    for t, path in pairs(types) do if not known[t] then unknownTypes[#unknownTypes + 1] = t .. " (" .. path:gsub("^.*Guides/", "") .. ")" end end
    for k, path in pairs(fields) do
        if k ~= "type" and not code:find("%." .. k .. "%f[^%w_]") then unreadFields[#unreadFields + 1] = k .. " (" .. path:gsub("^.*Guides/", "") .. ")" end
    end
    table.sort(unknownTypes) table.sort(unreadFields)
    check(#unknownTypes == 0, "every step type in the shipped guides is one Guide.lua completes (" .. table.concat(unknownTypes, ", ") .. ")")
    check(#unreadFields == 0, "every step field in the shipped guides is read by the engine (" .. table.concat(unreadFields, ", ") .. ")")
end)

section("docs agree with the code", function()
    local function read(path)
        local f = io.open(root .. path)
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local source = read("Commands.lua") or ""
    local handlers = {}
    for name in source:gmatch("\nfunction handlers%.([%w_]+)") do handlers[name] = true end
    for name in source:gmatch("\nhandlers%.([%w_]+)%s*=") do handlers[name] = true end
    need(handlers.status and handlers.help and handlers.run, "Commands.lua's handlers are readable as text")

    local commands = (read("README.md") or ""):match("\n## Commands\n(.-)\n## ")
    need(commands ~= nil, "the README has a Commands section")
    -- `/fg show` `hide` names two commands; `/fg` alone is the status readout
    local documented = { status = commands:find("`/fg`", 1, true) ~= nil }
    for chunk in commands:gmatch("`([^`]+)`") do
        local word = chunk:match("^/fg%s+([%w_]+)") or chunk:match("^([%a_]+)")
        if word and word ~= "fg" then documented[word] = true end
    end
    local unknown, missing = {}, {}
    for word in pairs(documented) do if not handlers[word] then unknown[#unknown + 1] = word end end
    for name in pairs(handlers) do if not documented[name] then missing[#missing + 1] = name end end
    table.sort(unknown) table.sort(missing)
    check(#unknown == 0, "every command the README names exists (unknown: " .. table.concat(unknown, ", ") .. ")")
    check(#missing == 0, "every command is in the README (missing: " .. table.concat(missing, ", ") .. ")")

    local help, stale = source:match("\nlocal HELP = {(.-)\n}") or "", {}
    for word in help:gmatch("/fg%s+([%a_]+)") do if not handlers[word] then stale[#stale + 1] = word end end
    check(help ~= "" and #stale == 0, "every command /fg help names exists (unknown: " .. table.concat(stale, ", ") .. ")")

    -- relative links in the docs point at files and headings that exist
    local function anchors(text)
        local out = {}
        for heading in (text .. "\n"):gmatch("\n#+%s+([^\n]+)") do
            out[heading:lower():gsub("[^%w%s%-]", ""):gsub("%s", "-")] = true
        end
        return out
    end
    local list = io.popen("git -C '" .. root .. "' ls-files '*.md'")
    local files = {}
    for line in list:lines() do if not line:match("^docs/history/") then files[#files + 1] = line end end
    list:close()
    need(#files > 3, "the docs are listed by git (" .. #files .. ")")
    local broken = {}
    for _, file in ipairs(files) do
        local text = (read(file) or ""):gsub("```.-```", "")
        local dir = file:match("^(.*/)") or ""
        for target in text:gmatch("%]%(([^)%s]+)%)") do
            if not target:match("^%a+:") then
                local path, anchor = target:match("^([^#]*)#?(.*)$")
                local resolved = path == "" and file or dir .. path
                local body = read(resolved)
                if not body then
                    broken[#broken + 1] = file .. " -> " .. target
                elseif anchor ~= "" and resolved:match("%.md$") and not anchors(body)[anchor] then
                    broken[#broken + 1] = file .. " -> " .. target .. " (no such heading)"
                end
            end
        end
    end
    check(#broken == 0, "every relative link in the docs resolves (" .. table.concat(broken, "; ") .. ")")
end)

-- ---- a step's text never says "nil" ------------------------------------------------
section("a step's text names what it is about from what the step has, and never prints nil", function()
    MOCK_SPELL_NAME(2580, "Find Minerals")
    MOCK_SPELL_NAME(465, "Devotion Aura")
    local cases = {
        -- TUGs' "[T] Train "Arcane Shot"." names no spell: the step's own words say what to train
        { { type = "TRAIN", class = { "HUNTER" }, note = 'Train "Arcane Shot".' }, 'Train "Arcane Shot".' },
        { { type = "TRAIN" }, "Train at your trainer" },
        { { type = "TRAIN", spell = 465 }, "Train Devotion Aura" },
        { { type = "TRAIN", spell = 999999, note = "Get your skills." }, "Get your skills." },
        { { type = "TRAIN", spell = 465, spellName = "Devotion" }, "Train Devotion" },
        -- "Use: [SP2580]" as codex fixes it: a note with the spell to use
        { { type = "NOTE", text = "Use:", spell = 2580 }, "Use: Find Minerals" },
        { { type = "NOTE", text = "Use:", spell = 999999 }, "Use:" },
        { { type = "FLIGHTPATH", zone = "Redridge Mountains", x = 25.5, y = 59.4, note = "Get the flightpath at:" }, "Get the flight path in Redridge Mountains" },
        { { type = "FLIGHTPATH" }, "Get the flight path" },
        { { type = "FLY", place = "Duskwood", note = "Fly to" }, "Fly to Duskwood" },
        { { type = "FLY" }, "Fly to destination" },
        { { type = "TALK", note = "Learn Skinning at" }, "Learn Skinning at" },
        { { type = "TALK" }, "Talk to someone here" },
        { { type = "GRIND", note = "Farm till level 9" }, "Farm till level 9" },
        { { type = "GRIND" }, "Grind" },
        { { type = "BUY", count = 2 }, "Buy 2 x the item" },
        { { type = "USEHEARTH" }, "Use your hearthstone" },
        { { type = "SKILL", profession = "Mining", skill = 1 }, "Learn Mining" },
    }
    for _, c in ipairs(cases) do
        local text = G:GetStepText(c[1])
        check(text == c[2], c[1].type .. " reads \"" .. c[2] .. "\" (" .. tostring(text) .. ")")
    end
    -- every type, with nothing but its type, says something and never "nil"
    for _, t in ipairs({ "ACCEPT", "TURNIN", "COMPLETE", "KILL", "COLLECT", "GRIND", "BUY", "TRAIN", "HEARTH", "USEHEARTH", "TRAVEL", "FLY", "TALK", "FLIGHTPATH", "NOTE", "SKILL" }) do
        local text = G:GetStepText({ type = t })
        check(type(text) == "string" and text ~= "" and not text:find("nil", 1, true), t .. " with no fields reads without nil (" .. tostring(text) .. ")")
    end
end)

-- ---- no swallowed errors anywhere -------------------------------------------------
section("no swallowed errors anywhere", function()
    local expected = 0
    for _, e in ipairs(reportedErrors) do
        if e:find("command failed", 1, true) and e:find("expected", 1, true) then expected = expected + 1 end
    end
    check(#reportedErrors == expected, "no errors were reported by any module (" .. #reportedErrors .. ")")
    for _, e in ipairs(reportedErrors) do print("   reported: " .. e) end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
