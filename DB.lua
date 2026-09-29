-- ============================================================
-- ForeverGuide / DB.lua
-- Access to the bundled quest database (Data/*.lua, packed by tools/pack_data.lua
-- from data-src/tables, which tools/build_questdb.lua builds from Questie's Classic
-- Era data and the Forever tools extend). Each record is stored as a string and
-- decoded the first time it is read; the tables below are what DB:Get* returns.
--
--   ns.QuestDB[id]  = { n, lvl, req, maxlvl, races, classes, zone, text,
--                       snpc/sobj/sitem, enpc/eobj, kill/obj/item/credit/spell,
--                       trig, srcitem, reqitems, pre, pregroup, next, excl,
--                       parent, children, group, skill, flags, special, hidden }
--   ns.NpcDB[id]    = { n, min, max, rank, zone, sp = { [areaID] = { {x,y}, ..., n = total } }, f, sub, starts, ends }
--   ns.ObjectDB[id] = { n, zone, sp, starts, ends }
--   ns.ItemDB[id]   = { n, npc = {npcIDs}, obj = {objectIDs}, startq, vendors, quests }
--   ns.ZoneDB       = { areaToMap = { [areaID] = uiMapID }, names = { [areaID] = name }, parent = { [areaID] = areaID },
--                       mapNames = { [uiMapID] = name } }
--   WoW Forever additions are merged in by tools/pack_data.lua: new quests/npcs have `forever = true`,
--   quests the client lacks `removed = true`; recorded points live in `spm` (map coords per uiMapID)
--   / `spw` (world coords), objective evidence in `fobj`.
--   ns.QuestIndex   = { byZone = { [top-level areaID] = { questIDs } }, byItem = { [itemID] = { questIDs } } }
--
-- Coordinates are 0-100 on the Classic Era uiMapID of the area (confirmed
-- identical on WoW Forever 1.60.1).
--
-- A "location" as returned by this module: { map, x, y, kind, id, name, count }
-- ============================================================

local _, ns = ...
local DB = ns:NewModule("DB")

-- WoW Forever's Skyborne plays on both factions and has no Classic race bit; it gets one bit per
-- faction, well above the Classic races: 65536 for Alliance Skyborne, 131072 for Horde Skyborne.
local SKYBORNE_BIT = { Alliance = 65536, Horde = 131072 }
local RACE_ALLIANCE = { 1, 4, 8, 64, SKYBORNE_BIT.Alliance }   -- Human, Dwarf, Night Elf, Gnome, Skyborne
local RACE_HORDE = { 2, 16, 32, 128, SKYBORNE_BIT.Horde }      -- Orc, Undead, Tauren, Troll, Skyborne
local RACE_BIT = { Human = 1, Orc = 2, Dwarf = 4, NightElf = 8, Scourge = 16, Tauren = 32, Gnome = 64, Troll = 128 }
local CLASS_BIT = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128, WARLOCK = 256, DRUID = 1024 }

local function band(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
end

-- ------------------------------------------------------------
-- Raw access
-- ------------------------------------------------------------
-- A decoded record stays while anything holds it (weak cache) and while it is among the last
-- RECENT decoded, so a record read every tick is not decoded every tick. Records are read-only.
local RECENT = 256
local decoded = {}
for _, name in ipairs({ "QuestDB", "NpcDB", "ObjectDB", "ItemDB" }) do decoded[name] = setmetatable({}, { __mode = "v" }) end
local recent, recentAt = {}, 0     -- luacheck: ignore (holds the recent records strongly)

--- The record `id` of table `name`; `keep` false decodes it without caching (a scan over all).
local function Record(name, id, keep)
    local db = id and ns[name]
    local v = db and db[id]
    if type(v) ~= "string" then return v end
    local value = decoded[name][id]
    if value then return value end
    local err
    value, err = ns.DecodeRecord(v)
    if not value then
        ns.ReportOnce("DB:" .. name, "record " .. tostring(id) .. " does not decode: " .. tostring(err))
        return nil
    end
    if keep ~= false then
        decoded[name][id] = value
        recentAt = recentAt % RECENT + 1
        recent[recentAt] = value
    end
    return value
end

function DB:GetQuest(id) return Record("QuestDB", id) end
function DB:GetNPC(id) return Record("NpcDB", id) end
function DB:GetObject(id) return Record("ObjectDB", id) end
function DB:GetItem(id) return Record("ItemDB", id) end

--- Every quest as (id, record), decoded for this pass only.
function DB:EachQuest()
    local db, id = ns.QuestDB or {}, nil
    return function()
        id = next(db, id)
        if id ~= nil then return id, Record("QuestDB", id, false) end
    end
end

--- The quests whose objectives name an item (built by tools/pack_data.lua).
function DB:QuestsForItem(itemID)
    local index = ns.QuestIndex and ns.QuestIndex.byItem
    return index and index[itemID] or {}
end

function DB:IsLoaded()
    return ns.QuestDB ~= nil and next(ns.QuestDB) ~= nil
end

function DB:QuestName(id)
    local q = self:GetQuest(id)
    return q and q.n or nil
end

function DB:NPCName(id)
    local n = self:GetNPC(id)
    return n and n.n or nil
end

function DB:ObjectName(id)
    local o = self:GetObject(id)
    return o and o.n or nil
end

function DB:ItemName(id)
    local i = self:GetItem(id)
    return i and i.n or nil
end

function DB:MapForArea(areaID)
    return ns.ZoneDB and ns.ZoneDB.areaToMap[areaID] or nil
end

function DB:ZoneName(areaID)
    return ns.ZoneDB and ns.ZoneDB.names[areaID] or nil
end

--- The top-level zone (areaID) a sub-zone belongs to (Northshire Valley -> Elwynn Forest).
function DB:ParentZone(areaID)
    local parent = ns.ZoneDB and ns.ZoneDB.parent
    local guard = 0
    while parent and parent[areaID] and guard < 8 do
        areaID = parent[areaID]
        guard = guard + 1
    end
    return areaID
end

--- The zone a quest belongs to (parent zone of its zoneOrSort, nil for sort categories).
function DB:QuestZone(questID)
    local q = self:GetQuest(questID)
    if not q or not q.zone or q.zone <= 0 then return nil end
    return self:ParentZone(q.zone)
end

-- ------------------------------------------------------------
-- Locations
-- ------------------------------------------------------------
-- world -> map conversion for Forever points stored as world coordinates (spw),
-- cached because C_Map.GetMapPosFromWorldPos is not free.
local mapPosCache = {}
local objCache = {}   -- questID -> objective list; the database is static
local function WorldToMap(map, inst, wx, wy)
    if type(map) ~= "number" or type(inst) ~= "number" or type(wx) ~= "number" or type(wy) ~= "number" then return nil end
    local key = map .. ":" .. inst .. ":" .. wx .. ":" .. wy
    local c = mapPosCache[key]
    if c == nil then
        c = false
        local C_Map = rawget(_G, "C_Map")
        if C_Map and C_Map.GetMapPosFromWorldPos and rawget(_G, "CreateVector2D") then
            local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, inst, CreateVector2D(wx, wy), map)
            local x, y = type(pos) == "table" and ns.PlainNumber(pos.x), type(pos) == "table" and ns.PlainNumber(pos.y)
            if ok and x and y then c = { x = x * 100, y = y * 100 } end
        end
        mapPosCache[key] = c
    end
    return c or nil
end

--- Locations from a record's spawn tables:
---   rec.sp  = { [areaID]  = { {x,y}, ... } }          (vanilla, Questie)
---   rec.spm = { [uiMapID] = { {x,y}, ... } }          (Forever, recorded in-game)
---   rec.spw = { [uiMapID] = { {inst,wx,wy}, ... } }   (Forever, client POI tables; world coords)
local function SpawnLocations(kind, id, rec, out, name)
    if not rec then return out end
    name = name or rec.n
    -- Forever evidence (recorded in-game, or RestedXP's Forever positions) beats the
    -- vanilla tables: Forever moved NPCs and the vanilla point would send you to the old spot
    local hasForever = (rec.spm and next(rec.spm) ~= nil) or (rec.spw and next(rec.spw) ~= nil)
    local before = #out
    local function vanilla()
        if not rec.sp then return end
        for areaID, pts in pairs(rec.sp) do
            local map = DB:MapForArea(areaID)
            if map then
                for _, p in ipairs(pts) do
                    out[#out + 1] = { map = map, x = p[1], y = p[2], kind = kind, id = id, name = name, count = pts.n or #pts, area = areaID }
                end
            end
        end
    end
    if not hasForever then vanilla() end
    if rec.spm then
        for map, pts in pairs(rec.spm) do
            for _, p in ipairs(pts) do
                out[#out + 1] = { map = map, x = p[1], y = p[2], kind = kind, id = id, name = name, count = #pts, forever = true }
            end
        end
    end
    if rec.spw then
        for map, pts in pairs(rec.spw) do
            for _, p in ipairs(pts) do
                local m = WorldToMap(map, p[1], p[2], p[3])
                if m then
                    out[#out + 1] = { map = map, x = m.x, y = m.y, kind = kind, id = id, name = name, count = #pts, forever = true }
                end
            end
        end
    end
    if hasForever and #out == before then vanilla() end   -- world points the client could not convert: vanilla spot
    return out
end

--- A vanilla quest the Forever client no longer has (later-phase content, battlegrounds, ...).
function DB:IsRemoved(id)
    local q = self:GetQuest(id)
    return q and q.removed or false
end

--- Does the Forever overlay know this quest / npc (i.e. it is not in the vanilla data)?
function DB:IsForeverQuest(id)
    local q = self:GetQuest(id)
    return q and q.forever or false
end

function DB:NPCLocations(npcID, out)
    return SpawnLocations("npc", npcID, self:GetNPC(npcID), out or {})
end

function DB:ObjectLocations(objectID, out)
    return SpawnLocations("object", objectID, self:GetObject(objectID), out or {})
end

--- Where an item can be obtained: drop sources (NPCs/objects) and vendors.
function DB:ItemLocations(itemID, out)
    out = out or {}
    local it = self:GetItem(itemID)
    if not it then return out end
    for _, npc in ipairs(it.npc or {}) do self:NPCLocations(npc, out) end
    for _, obj in ipairs(it.obj or {}) do self:ObjectLocations(obj, out) end
    for _, v in ipairs(it.vendors or {}) do self:NPCLocations(v, out) end
    for _, loc in ipairs(out) do loc.item = itemID loc.itemName = it.n end
    return out
end

--- Locations where a quest can be accepted.
function DB:QuestStarts(questID)
    local q = self:GetQuest(questID)
    local out = {}
    if not q then return out end
    for _, npc in ipairs(q.snpc or {}) do self:NPCLocations(npc, out) end
    for _, obj in ipairs(q.sobj or {}) do self:ObjectLocations(obj, out) end
    for _, item in ipairs(q.sitem or {}) do self:ItemLocations(item, out) end
    if #out == 0 and q.fstart then SpawnLocations("start", nil, q.fstart, out, q.fstart.n or q.n) end
    return out
end

--- Locations where a quest is turned in.
function DB:QuestEnds(questID)
    local q = self:GetQuest(questID)
    local out = {}
    if not q then return out end
    for _, npc in ipairs(q.enpc or {}) do self:NPCLocations(npc, out) end
    for _, obj in ipairs(q.eobj or {}) do self:ObjectLocations(obj, out) end
    if #out == 0 and q.ffin then SpawnLocations("end", nil, q.ffin, out, q.ffin.n or q.n) end
    return out
end

--- The quest's objectives as the database knows them, in Questie order:
--- { { kind = "kill"|"object"|"item"|"event"|"credit", id, name, text, locations = {...} }, ... }
function DB:QuestObjectives(questID)
    local cached = objCache[questID]
    if cached then return cached end
    local q = self:GetQuest(questID)
    local out = {}
    if not q then return out end
    for _, e in ipairs(q.kill or {}) do
        local id = e[1]
        out[#out + 1] = { kind = "kill", id = id, name = self:NPCName(id), text = e[2], locations = self:NPCLocations(id) }
    end
    for _, e in ipairs(q.obj or {}) do
        local id = e[1]
        out[#out + 1] = { kind = "object", id = id, name = self:ObjectName(id), text = e[2], locations = self:ObjectLocations(id) }
    end
    for _, e in ipairs(q.item or {}) do
        local id = e[1]
        out[#out + 1] = { kind = "item", id = id, name = self:ItemName(id), text = e[2], locations = self:ItemLocations(id) }
    end
    if q.credit and q.credit[1] then
        local locs = {}
        for _, id in ipairs(q.credit[1]) do self:NPCLocations(id, locs) end
        out[#out + 1] = { kind = "credit", id = q.credit[2], name = q.credit[3] or self:NPCName(q.credit[2]), locations = locs }
    end
    if q.trig and q.trig[2] then
        local locs = {}
        for areaID, pts in pairs(q.trig[2]) do
            local map = self:MapForArea(areaID)
            if map then
                for _, p in ipairs(pts) do
                    locs[#locs + 1] = { map = map, x = p[1], y = p[2], kind = "event", name = q.trig[1], area = areaID }
                end
            end
        end
        out[#out + 1] = { kind = "event", name = q.trig[1], text = q.trig[1], locations = locs }
    end
    -- Forever evidence (recorded in-game / client POI tables): fills objectives
    -- the vanilla data has no locations for, and adds the ones it does not know
    for i, fo in ipairs(q.fobj or {}) do
        local existing = out[i]
        if not existing or #existing.locations == 0 then
            local locs = existing and existing.locations or {}
            local name = fo.name or (fo.kind == "kill" and fo.id and self:NPCName(fo.id)) or fo.text
            if fo.kind == "kill" and fo.id then self:NPCLocations(fo.id, locs) end
            if fo.kind == "object" and fo.id then self:ObjectLocations(fo.id, locs) end
            if fo.kind == "item" and fo.id then self:ItemLocations(fo.id, locs) end
            SpawnLocations(fo.kind or "event", fo.id, fo, locs, name)
            if not existing then
                out[#out + 1] = { kind = fo.kind or "event", id = fo.id, name = name, text = fo.text, locations = locs, forever = true }
            end
        end
    end
    objCache[questID] = out
    return out
end

--- Match a live quest-log objective (text like "Kobold Vermin slain: 3/10")
--- to a database objective; falls back to the same position.
function DB:MatchObjective(questID, index, text)
    local objs = self:QuestObjectives(questID)
    if text then
        local lower = string.lower(text)
        -- the objective at the same position wins when its name appears in the text
        local pos = index and objs[index]
        if pos and pos.name and pos.name ~= "" and string.find(lower, string.lower(pos.name), 1, true) then return pos end
        for _, o in ipairs(objs) do
            local name = o.name or o.text
            if name and name ~= "" and string.find(lower, string.lower(name), 1, true) then return o end
        end
    end
    return objs[index]
end

-- ------------------------------------------------------------
-- Choosing the nearest location
-- ------------------------------------------------------------
local worldCache = {}   -- "map:x:y" -> { inst, wx, wy } or false

local function WorldOf(loc)
    local key = loc.map .. ":" .. loc.x .. ":" .. loc.y
    local w = worldCache[key]
    if w == nil then
        local inst, wx, wy = ns.Navigation:MapToWorld(loc.map, loc.x, loc.y)
        w = inst and { inst = inst, wx = wx, wy = wy } or false
        worldCache[key] = w
    end
    return w or nil
end

--- Distance in yards from the player to a location (nil if unknown / other continent).
function DB:DistanceTo(loc)
    local px, py, pInst = ns.Player:GetWorldPosition()
    local w = WorldOf(loc)
    if not px or not w then return nil end
    if pInst and w.inst and pInst ~= w.inst then return nil end
    local dx, dy = w.wx - px, w.wy - py
    return math.sqrt(dx * dx + dy * dy)
end

--- The location nearest to the player; same-map locations win when the
--- player's world position is unavailable. Returns loc, distance.
function DB:Nearest(locations)
    if not locations or #locations == 0 then return nil end
    local best, bestD = nil, nil
    local curMap = ns.Player:GetMapID()
    for _, loc in ipairs(locations) do
        local d = self:DistanceTo(loc)
        if d == nil then
            d = (loc.map == curMap) and 1e6 or 1e7   -- unknown distance: prefer the current map
        end
        if not bestD or d < bestD then best, bestD = loc, d end
    end
    return best, bestD and bestD < 1e6 and bestD or nil
end

-- ------------------------------------------------------------
-- Availability
-- ------------------------------------------------------------
function DB:QuestFaction(questID)
    local q = self:GetQuest(questID)
    if not q or not q.races or q.races == 0 then return nil end
    local a, h = false, false
    for _, bit in ipairs(RACE_ALLIANCE) do if band(q.races, bit) ~= 0 then a = true end end
    for _, bit in ipairs(RACE_HORDE) do if band(q.races, bit) ~= 0 then h = true end end
    if a and not h then return "Alliance" end
    if h and not a then return "Horde" end
    return nil
end

local FACTION_RACES = { Alliance = 77, Horde = 178 }

--- May this race take a quest with this race mask? A Skyborne takes a quest that names its
--- faction's Skyborne bit, and what every Classic race of its faction can take (a faction-wide
--- quest). Unknown race and faction: not ours to judge.
local function RaceAllowed(races, raceFile)
    if not races or races == 0 or not raceFile then return true end
    local rbit = RACE_BIT[raceFile]
    if rbit then return band(races, rbit) ~= 0 end
    local faction = ns.Player:GetFaction() or ""
    local all = FACTION_RACES[faction]
    if not all then return true end
    local sky = raceFile == "Skyborne" and SKYBORNE_BIT[faction]
    if sky and band(races, sky) ~= 0 then return true end
    return band(races, all) == all
end

--- The part of availability that can never change for this character: its race and class.
--- (Level, prerequisites and completion all change with play; race and class do not, so a step
--- whose quest fails this one is not for this character at all - the Dwarf route carrying the
--- Human-only "A Swift Message" 6181, seen 2026-09-21.) Returns ok, reason.
local raceClassCache, raceClassWhy, raceClassFor = {}, {}, nil
function DB:RaceClassOK(questID)
    local _, raceFile = ns.Player:GetRace()
    local _, classFile = ns.Player:GetClass()
    local who = tostring(raceFile) .. "/" .. tostring(classFile) .. "/" .. tostring(ns.Player:GetFaction())
    if who ~= raceClassFor then raceClassCache, raceClassWhy, raceClassFor = {}, {}, who end
    local cached = raceClassCache[questID]
    if cached ~= nil then return cached, raceClassWhy[questID] end
    local q = self:GetQuest(questID)
    if not q then return true end        -- unknown quest: not ours to judge
    local ok, why = true, nil
    if not RaceAllowed(q.races, raceFile) then ok, why = false, "wrong race/faction" end
    if ok then
        local cbit = classFile and CLASS_BIT[classFile]
        if q.classes and q.classes ~= 0 and cbit and band(q.classes, cbit) == 0 then ok, why = false, "wrong class" end
    end
    if raceFile then                     -- only cache once the character is known
        raceClassCache[questID], raceClassWhy[questID] = ok, why
    end
    return ok, why
end

--- Can this character take the quest (level, race, class, prerequisites)?
--- Returns ok, reason.
function DB:IsAvailable(questID)
    local q = self:GetQuest(questID)
    if not q then return false, "unknown quest" end
    if q.hidden then return false, "not obtainable" end
    if q.removed then return false, "not in WoW Forever" end
    local level = ns.Player:GetLevel()
    if q.req and level < q.req then return false, "requires level " .. q.req end
    if q.maxlvl and level > q.maxlvl then return false, "too high level" end
    local _, raceFile = ns.Player:GetRace()
    if not RaceAllowed(q.races, raceFile) then return false, "wrong race/faction" end
    local _, classFile = ns.Player:GetClass()
    local cbit = classFile and CLASS_BIT[classFile]
    if q.classes and q.classes ~= 0 and cbit and band(q.classes, cbit) == 0 then return false, "wrong class" end
    local Q = ns.Quest
    if Q:IsCompleted(questID) then return false, "already completed" end
    if Q:IsOnQuest(questID) then return false, "already in log" end
    for _, pre in ipairs(q.pregroup or {}) do
        if not Q:IsCompleted(pre) then return false, "requires " .. (self:QuestName(pre) or pre) end
    end
    if q.pre and #q.pre > 0 then
        local any = false
        for _, pre in ipairs(q.pre) do if Q:IsCompleted(pre) then any = true break end end
        if not any then return false, "requires " .. (self:QuestName(q.pre[1]) or q.pre[1]) end
    end
    for _, ex in ipairs(q.excl or {}) do
        if Q:IsCompleted(ex) or Q:IsOnQuest(ex) then return false, "excluded by " .. (self:QuestName(ex) or ex) end
    end
    if q.next and (Q:IsCompleted(q.next) or Q:IsOnQuest(q.next)) then return false, "chain already advanced" end
    return true
end

--- Quests by (partial) name.
function DB:Search(text, limit)
    local out = {}
    if not text or text == "" or not ns.QuestDB then return out end
    local lower = string.lower(text)
    local asNumber = tonumber(text)
    if asNumber and ns.QuestDB[asNumber] then out[#out + 1] = asNumber return out end
    for id, q in self:EachQuest() do
        if q.n and string.find(string.lower(q.n), lower, 1, true) then
            out[#out + 1] = id
            if limit and #out >= limit then break end
        end
    end
    table.sort(out)
    return out
end

--- Quests in the database that this character could pick up in a zone (areaID),
--- sorted by level.
function DB:AvailableInZone(areaID, limit)
    local out = {}
    local index = ns.QuestIndex and ns.QuestIndex.byZone
    for _, id in ipairs(index and index[areaID] or {}) do
        if self:IsAvailable(id) then out[#out + 1] = id end
    end
    table.sort(out, function(a, b)
        local qa, qb = self:GetQuest(a), self:GetQuest(b)
        if (qa.lvl or 0) ~= (qb.lvl or 0) then return (qa.lvl or 0) < (qb.lvl or 0) end
        return a < b
    end)
    if limit then while #out > limit do table.remove(out) end end
    return out
end

--- Human readable one-liner for a location.
function DB:DescribeLocation(loc)
    if not loc then return "unknown location" end
    local zone = self:ZoneName(loc.area) or (ns.ZoneDB and ns.ZoneDB.mapNames and ns.ZoneDB.mapNames[loc.map]) or ns.Player:GetMapName(loc.map) or ("map " .. loc.map)
    return string.format("%s%s @ %s %.1f, %.1f", loc.name or "?", loc.count and loc.count > 1 and (" (" .. loc.count .. " spawns)") or "", zone, loc.x, loc.y)
end

function DB:OnEnable()
    if not self:IsLoaded() then
        ns.Warn("quest database not loaded (Data/QuestDB.lua missing?) - guide steps need explicit coordinates.")
    else
        local n = 0
        for _ in pairs(ns.QuestDB) do n = n + 1 end
        ns.Debug("quest database:", n, "quests")
    end
end
