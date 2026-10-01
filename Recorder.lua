-- ============================================================
-- ForeverGuide / Recorder.lua
-- Opt-in data contribution (Options -> Data collection, or /fg share on). While on, it keeps
-- the facts a guide database needs, merged as you play - not an event log:
--   quests[id]  title, level, the creatures that give / end it, the item that starts it,
--               the player levels it was offered at, a `shared` flag, and per objective its
--               text, where it progressed (per map) and votes for the mobs targeted when it did
--   npcs[id]    creature name, level and where it stands
--   order       quest ids accepted (+id) and turned in (-id) this session: prerequisites
--   maps[id]    uiMapID name, parent and world bounds
--   errors      ForeverGuide Lua errors with the guide step and map
-- Never kept: other players (a quest shared by one is only flagged `shared`), your name,
-- realm or account, GUIDs, chat, or the time. Spots are rounded to half a map unit.
-- Everything lives in ForeverGuideDB.contrib; /fg share (Share.lua) turns it into a string
-- to paste into the feedback form. Nothing is sent anywhere by the addon.
-- ============================================================

local _, ns = ...
local Recorder = ns:NewModule("Recorder")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

-- caps keep the store (and the share string) small; see docs/SHARE-FORMAT.md
local MAX_QUESTS, MAX_NPCS, MAX_ORDER, MAX_ERRORS = 2000, 2000, 1000, 50
local MAX_NPC_CELLS, MAX_OBJ_CELLS, MAX_IDS = 12, 24, 50
local TARGET_WINDOW = 20           -- seconds a mob counts as "just targeted" for objective votes
local REMIND_AT = { 50, 200 }      -- facts collected: remind to share before logging out

local lastTarget = nil             -- { npcID, name, level, seen } the last hostile creature targeted
local reminded = {}

local function Enabled()
    return ns.db and ns.db.contribute == true
end

local function Store() return ns.db.contrib end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function AddUnique(list, v)
    for _, e in ipairs(list) do if e == v then return end end
    if #list < MAX_IDS then list[#list + 1] = v end
end

-- a spot on the player's map, rounded to half a map unit
local function Cell()
    local mapID, x, y = ns.Player:GetMapPosition()
    if not (mapID and x and y) then return nil end
    return mapID, math.floor(x * 2 + 0.5) / 2, math.floor(y * 2 + 0.5) / 2
end

local function AddCell(list, x, y, max)
    for _, c in ipairs(list) do if c[1] == x and c[2] == y then return end end
    if #list < max then list[#list + 1] = { x, y } end
end

local function Remind()
    local facts = Count(Store().quests) + Count(Store().npcs)
    for _, at in ipairs(REMIND_AT) do
        if facts >= at and not reminded[at] then
            reminded[at] = true
            ns.Debug("contribute:", facts, "quest and NPC facts collected")
        end
    end
end

local function Quest(questID, title)
    questID = PlainNumber(questID)
    if not questID or questID <= 0 then return nil end
    local quests = Store().quests
    local q = quests[questID]
    if not q then
        if Count(quests) >= MAX_QUESTS then return nil end
        q = {}
        quests[questID] = q
        Remind()
    end
    title = PlainString(title)
    if title and title ~= "" then q.name = title end
    local entry = ns.Quest and ns.Quest:GetEntry(questID)
    if entry and PlainNumber(entry.level) then q.level = PlainNumber(entry.level) end
    return q
end

-- A creature (never a player) and, when it is beside the player, its spot.
local function Npc(info, here)
    if not info or info.isPlayer or not info.npcID then return nil end
    local npcs = Store().npcs
    local n = npcs[info.npcID]
    if not n then
        if Count(npcs) >= MAX_NPCS then return nil end
        n = { cells = {} }
        npcs[info.npcID] = n
        Remind()
    end
    if info.name and info.name ~= "?" then n.name = info.name end
    if info.level and info.level > 0 then n.level = info.level end
    if here then
        local mapID, x, y = Cell()
        if mapID then
            n.cells[mapID] = n.cells[mapID] or {}
            AddCell(n.cells[mapID], x, y, MAX_NPC_CELLS)
        end
    end
    return info.npcID
end

-- The quest window's NPC ("questnpc"). A player there shared the quest: say so, never who.
-- Without an "npc" unit the fallback is the target - a mob that did not give the quest.
local function QuestWindowNpc()
    local UnitIsPlayer = rawget(_G, "UnitIsPlayer")
    if PlainBool(ns.Safe(UnitIsPlayer, "questnpc")) == true or PlainBool(ns.Safe(UnitIsPlayer, "npc")) == true then
        return nil, true
    end
    local info = ns.Player:GetUnitInfo("questnpc") or ns.Player:GetUnitInfo("npc")
    return Npc(info, true), false
end

local function Order(v)
    local order = Store().order
    if #order < MAX_ORDER then order[#order + 1] = v end
end

-- Which creatures to credit with an objective's progress: the hostile or dead creature
-- targeted now, else the last one targeted within TARGET_WINDOW seconds.
local function ObjectiveTargets()
    local now = ns.Player:GetTargetInfo()
    if now and not now.isPlayer and now.npcID and (now.reaction == "hostile" or now.isDead) then
        return { now }
    end
    if lastTarget and ns.Now() - lastTarget.seen <= TARGET_WINDOW then return { lastTarget } end
    return {}
end

--- A uiMapID's name, parent and world bounds (the bounds let the tools convert world
--- coordinates offline). Run.lua's segments name their maps with it too.
function Recorder:MapInfo(mapID)
    local name, _, parent = ns.Player:GetMapName(mapID)
    local entry = { name = name, parent = parent }
    local inst0, x0, y0 = ns.Navigation:MapToWorld(mapID, 0, 0)
    local inst1, x1, y1 = ns.Navigation:MapToWorld(mapID, 100, 100)
    if inst0 and x0 and x1 and inst0 == inst1 then entry.bounds = { inst0, x0, y0, x1, y1 } end
    return entry
end

function Recorder:NoteMap()
    if not Enabled() then return end
    local mapID = ns.Player:GetMapID()
    if not mapID then return end
    Store().maps[mapID] = self:MapInfo(mapID)
end

--- A ForeverGuide Lua error (called by ns.ReportOnce, once per key per session).
function Recorder:NoteError(key, message)
    if not Enabled() then return end
    local errors = Store().errors
    if #errors >= MAX_ERRORS then return end
    local G = ns.Guide
    errors[#errors + 1] = {
        key = tostring(key), message = tostring(message):sub(1, 300),
        guide = G and G.active and G.active.id, step = G and G.current, map = ns.Player:GetMapID(),
    }
end

function Recorder:SetEnabled(on)
    ns.db.contribute = on and true or false
    if on then self:NoteMap() end
    if ns.Harvest then ns.Harvest:OnContributeChanged(ns.db.contribute) end
end

function Recorder:OnInit()
    local E = ns.Events

    -- quest offer window: this NPC (or the item) starts that quest, at this player level
    E:Register("QUEST_DETAIL", function(_, questStartItemID)
        if not Enabled() then return end
        local q = Quest(ns.Safe(rawget(_G, "GetQuestID")), ns.Safe(rawget(_G, "GetTitleText")))
        if not q then return end
        local npcID, shared = QuestWindowNpc()
        if shared then q.shared = true end
        if npcID then
            q.givers = q.givers or {}
            AddUnique(q.givers, npcID)
        end
        local item = PlainNumber(questStartItemID)
        if item and item > 0 then q.startItem = item end
        local level = ns.Player:GetLevel()
        if level then
            q.offeredAt = q.offeredAt or { level, level }
            q.offeredAt[1] = math.min(q.offeredAt[1], level)
            q.offeredAt[2] = math.max(q.offeredAt[2], level)
        end
    end)

    -- turn-in windows: this NPC ends that quest
    E:RegisterMany({ "QUEST_PROGRESS", "QUEST_COMPLETE" }, function()
        if not Enabled() then return end
        local q = Quest(ns.Safe(rawget(_G, "GetQuestID")), ns.Safe(rawget(_G, "GetTitleText")))
        local npcID = q and QuestWindowNpc()
        if npcID then
            q.enders = q.enders or {}
            AddUnique(q.enders, npcID)
        end
    end)

    E:Register("FG_QUEST_ACCEPTED", function(_, questID, title)
        if not Enabled() then return end
        if Quest(questID, title) then Order(PlainNumber(questID)) end
    end)

    E:Register("FG_QUEST_TURNED_IN", function(_, questID, title)
        if not Enabled() then return end
        if Quest(questID, title) then Order(-PlainNumber(questID)) end
    end)

    -- gossip: the NPC offers its available quests and ends its active ones
    E:Register("GOSSIP_SHOW", function()
        if not Enabled() then return end
        local npcID = Npc(ns.Player:GetUnitInfo("npc"), true)
        if not npcID then return end
        for fn, field in pairs({ ["C_GossipInfo.GetAvailableQuests"] = "givers", ["C_GossipInfo.GetActiveQuests"] = "enders" }) do
            local list = ns.Call(fn)
            if type(list) == "table" then
                for _, g in ipairs(list) do
                    local q = type(g) == "table" and Quest(g.questID, g.title)
                    if q then
                        q[field] = q[field] or {}
                        AddUnique(q[field], npcID)
                    end
                end
            end
        end
    end)

    -- vendors and trainers: where they stand
    E:RegisterMany({ "MERCHANT_SHOW", "TRAINER_SHOW" }, function()
        if not Enabled() then return end
        Npc(ns.Player:GetUnitInfo("npc"), true)
    end)

    E:Register("FG_TARGET_CHANGED", function(_, info)
        -- the previous target stopped being targeted now
        if lastTarget then lastTarget.seen = ns.Now() end
        if info and not info.isPlayer and info.npcID and info.reaction == "hostile" then
            lastTarget = { npcID = info.npcID, name = info.name, level = info.level, seen = ns.Now() }
        end
    end)

    E:Register("FG_OBJECTIVE_PROGRESS", function(_, questID, idx, _, _, _, text)
        if not Enabled() then return end
        idx = PlainNumber(idx)
        local q = Quest(questID)
        if not (q and idx) then return end
        q.objectives = q.objectives or {}
        local o = q.objectives[idx] or { cells = {}, targets = {} }
        q.objectives[idx] = o
        text = PlainString(text)
        if text and text ~= "" then o.text = text end
        local mapID, x, y = Cell()
        if mapID then
            o.cells[mapID] = o.cells[mapID] or {}
            AddCell(o.cells[mapID], x, y, MAX_OBJ_CELLS)
        end
        for _, t in ipairs(ObjectiveTargets()) do
            local npcID = Npc(t, true)
            if npcID then o.targets[npcID] = (o.targets[npcID] or 0) + 1 end
        end
    end)

    E:Register("FG_ZONE_CHANGED", function()
        Recorder:NoteMap()
    end)
end

function Recorder:OnEnterWorld()
    self:NoteMap()
end

--- How much is collected: quests, npcs, errors.
function Recorder:Counts()
    local s = Store()
    return Count(s.quests), Count(s.npcs), #s.errors
end

--- Forget the collected facts (after they were shared).
function Recorder:Clear()
    for _, t in pairs(Store()) do
        for k in pairs(t) do t[k] = nil end
    end
    reminded = {}
end
