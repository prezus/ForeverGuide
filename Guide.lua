-- ============================================================
-- ForeverGuide / Guide.lua
-- Guide registry and the step engine (the "interpreter").
--
-- A guide is data (see docs/GUIDE-SCHEMA.md). The engine answers one
-- question from live game state: "what is the player doing now?"
--
-- Step types and how they complete:
--   ACCEPT   quest           on quest (or already completed)
--   TURNIN   quest           quest flagged completed
--   COMPLETE quest [objective] objective(s) finished / ready to turn in
--   KILL     quest [objective] same as COMPLETE (display only)
--   COLLECT  quest [objective] same as COMPLETE (display only)
--   GRIND    level           player level >= level
--   BUY      item count      bag count >= count
--   TRAIN    spell           spell known
--   HEARTH   npc [zone]      hearthstone bound (HEARTHSTONE_BOUND) while talking to that innkeeper;
--                            bind location == zone (GetBindLocation) for a bind made earlier; else manual
--   TRAVEL   map x y [radius] arriving within radius (Navigation) — auto
--   FLY      map x y         same as TRAVEL (flight path hint)
--   TALK     npc             interacting with that NPC (gossip/quest/vendor/trainer windows)
--   NOTE     text            manual: /fg skip (or auto when a later step is done)
--
-- Recovery rules:
--   * a step whose quest is already completed is done, whatever its type
--   * an objective/turn-in step whose quest is missing from the log jumps
--     back to that quest's ACCEPT step (unless the player skipped it)
--   * manual steps are auto-completed once the next automatic step is done
--   * steps filtered by class/race/faction are skipped
-- ============================================================

local _, ns = ...
local Guide = ns:NewModule("Guide")

local PlainNumber, Plain = ns.PlainNumber, ns.Plain

Guide.registry = {}      -- id -> guide
Guide.list = {}          -- ordered ids (registration order)
Guide.active = nil       -- guide table
Guide.progress = nil     -- ns.char.guides[id]
Guide.current = nil      -- current step index
Guide.note = nil         -- recovery note shown in UI
Guide.blocked = nil      -- current step is blocked (quest missing, no accept step)

local MANUAL = { TRAVEL = true, FLY = true, TALK = true, FLIGHTPATH = true, NOTE = true }
local LOOKAHEAD = 6      -- automatic steps checked past a manual one before calling it stale
local OBJECTIVE = { COMPLETE = true, KILL = true, COLLECT = true }
Guide.MANUAL, Guide.OBJECTIVE = MANUAL, OBJECTIVE

-- ------------------------------------------------------------
-- Registry (called by compiled guide files)
-- ------------------------------------------------------------
---@class FGStep
---@field type? string
---@field index? integer       Assigned during registration (1-based).
---@field quest? integer
---@field faction? string
---@field class? string[]
---@field race? string[]
---@field map? integer
---@field x? number
---@field y? number
---@field zone? string
---@field npc? integer
---@field npcName? string
---@field note? string
---@field radius? number
---@field hasEdit? boolean
---@field edited? boolean

---@param steps FGStep[]
local function prepare(steps)
    for i, step in ipairs(steps) do
        step.index = i
        step.type = string.upper(tostring(step.type or "NOTE"))
    end
    return steps
end

function ns.RegisterGuide(guide)
    if type(guide) ~= "table" or type(guide.id) ~= "string" then
        ns.Error("RegisterGuide: guide needs a string id")
        return
    end
    guide.version = guide.version or 1
    if type(guide.steps) == "string" then
        -- published guides hand over their steps as packed text, decoded on first read
        local text, id = guide.steps, guide.id
        guide.steps = function()
            local steps, err = ns.DecodeRecord(text)
            if not steps then ns.ReportOnce("guide " .. id, "steps do not decode: " .. tostring(err)) end
            return steps
        end
    end
    if type(guide.steps) == "function" then
        -- a loader: the step tables are built the first time a guide's
        -- steps are read (activation, AutoQuest, the info popup), never for the 400 guides that are
        -- only ever listed in the picker
        local loader = guide.steps
        guide.steps = nil
        setmetatable(guide, { loader = loader, __index = function(t, k)
            if k ~= "steps" then return nil end
            local steps = prepare(loader() or {})
            rawset(t, "steps", steps)
            rawset(t, "stepCount", #steps)
            return steps
        end })
    else
        guide.steps = prepare(guide.steps or {})
        guide.stepCount = #guide.steps
    end
    if not Guide.registry[guide.id] then
        Guide.list[#Guide.list + 1] = guide.id
    end
    Guide.registry[guide.id] = guide
end

--- A guide's steps for a read-only pass (which quests it has): a guide not built yet is built for
--- this call only, not kept, so scanning the route's chapters does not hold all of their steps.
---@return FGStep[]
function Guide:ScanSteps(g)
    if not g then return {} end
    local steps = rawget(g, "steps")
    if steps then return steps end
    local mt = getmetatable(g)
    if mt and mt.loader then return prepare(mt.loader() or {}) end
    return g.steps or {}
end

function Guide:Get(id)
    return self.registry[id]
end

function Guide:Find(text)
    if not text or text == "" then return nil end
    if self.registry[text] then return self.registry[text] end
    local lower = string.lower(text)
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if string.lower(id) == lower or string.lower(g.name or "") == lower then return g end
    end
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if string.find(string.lower(id), lower, 1, true) or string.find(string.lower(g.name or ""), lower, 1, true) then
            return g
        end
    end
    return nil
end

--- Guides usable by this character (faction / class filters). A guide's race is a
--- preference, not a lock: any Alliance character may follow the Dwarf route.
function Guide:Applicable(guide)
    local faction = ns.Player:GetFaction()
    if guide.faction and faction and string.upper(guide.faction) ~= string.upper(faction) then return false end
    local _, classFile = ns.Player:GetClass()
    if guide.class and classFile and not ns.Contains(guide.class, classFile) then return false end
    return true
end

--- A dungeon's own guide (`kind = "dungeon"`): opened when a group forms, never auto-picked.
function Guide:IsDungeon(guide)
    return type(guide) == "table" and guide.kind == "dungeon"
end

--- A chapter of an alternate route (`kind = "alternate"`, e.g. TUGs' route beside ours): listed in
--- the route list under its `routeLabel`, followed only once the player chooses it, never the
--- race's default and never auto-picked otherwise.
function Guide:IsAlternate(guide)
    return type(guide) == "table" and guide.kind == "alternate"
end

--- The dungeon guides this character may follow, by level then name.
function Guide:Dungeons()
    local out = {}
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if self:IsDungeon(g) and self:Applicable(g) then out[#out + 1] = g end
    end
    table.sort(out, function(a, b)
        if (a.minLevel or 1) ~= (b.minLevel or 1) then return (a.minLevel or 1) < (b.minLevel or 1) end
        return (a.name or a.id) < (b.name or b.id)
    end)
    return out
end

--- The quests some guide will take this character through: every chapter of the route it
--- follows, every dungeon guide, and the open guide. Cached until one of those changes.
local coveredCache, coveredKey
function Guide:CoveredQuests()
    local route = self:CurrentRoute()
    local key = (route and route.key or "") .. "|" .. (self.active and self.active.id or "") .. "|" .. #self.list
    if coveredKey == key then return coveredCache end
    local covered = {}
    local function add(g)
        for _, step in ipairs(self:ScanSteps(g)) do
            if step.quest then covered[step.quest] = true end
        end
    end
    for _, g in ipairs(route and route.chapters or {}) do add(g) end
    for _, g in ipairs(self:Dungeons()) do add(g) end
    add(self.active)
    coveredCache, coveredKey = covered, key
    return covered
end

--- Leave a dungeon guide for the chapter it was opened from (else the route's chapter for the
--- level). Returns the guide activated, or nil when there is nowhere to go.
function Guide:Resume()
    local back = ns.char.returnGuide and self.registry[ns.char.returnGuide]
    if not back then back = self:RouteChapterForLevel() end
    if not back then return nil end
    self:Activate(back.id)
    return back
end

--- Does the guide's race list include this character?
function Guide:ForMyRace(guide)
    local _, raceFile = ns.Player:GetRace()
    return not guide.race or not raceFile or ns.Contains(guide.race, raceFile)
end

-- ---- routes: a route is a chain of chapters GEN_<FACTION>_<KEY>_nn_<ZONE> --------------------
local ROUTE_LABEL = { HUMAN = "Human", DWARF = "Dwarf / Gnome", NIGHTELF = "Night Elf", ORC = "Orc / Troll", TAUREN = "Tauren",
                      SCOURGE = "Undead", SKYBORNE = "Skyborne" }
function Guide:RouteOf(guide)
    local id = type(guide) == "table" and guide.id or guide
    if type(id) ~= "string" then return nil end
    local faction, key = id:match("^GEN_(%u+)_([%u_]-)_%d%d_")
    if not faction then return nil end
    return "GEN_" .. faction .. "_" .. key, key
end

--- The routes this character's faction can follow: { key, label, chapters = {guide...}, mine = bool, alternate = bool, chosen = bool }
function Guide:Routes()
    local byKey, order = {}, {}
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        local key, race = self:RouteOf(g)
        if key and self:Applicable(g) then
            local r = byKey[key]
            if not r then
                local alternate = self:IsAlternate(g)
                r = { key = key, race = race, label = g.routeLabel or ROUTE_LABEL[race] or race, chapters = {},
                      mine = self:ForMyRace(g) and not alternate, alternate = alternate }
                byKey[key] = r
                order[#order + 1] = r
            end
            r.chapters[#r.chapters + 1] = g
        end
    end
    for _, r in ipairs(order) do
        table.sort(r.chapters, function(a, b) return a.id < b.id end)
        r.chosen = (ns.char.route == r.key)
    end
    table.sort(order, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        return a.label < b.label
    end)
    return order
end

--- The route the character follows: the chosen one, else the race's own, else nil.
function Guide:CurrentRoute()
    local routes = self:Routes()
    for _, r in ipairs(routes) do if r.chosen then return r end end
    for _, r in ipairs(routes) do if r.mine then return r end end
    for _, r in ipairs(routes) do if not r.alternate then return r end end
    return nil
end

--- Choose a route (key or label); activates the chapter that fits the level.
function Guide:ChooseRoute(which)
    local target
    for _, r in ipairs(self:Routes()) do
        if r.key == which or r.label:lower() == tostring(which):lower() or r.race:lower() == tostring(which):lower() then target = r break end
    end
    if not target then return nil end
    ns.char.route = target.key
    local level = ns.Player:GetLevel()
    local pick = target.chapters[1]
    for _, g in ipairs(target.chapters) do
        if (g.maxLevel or 60) >= level and (g.minLevel or 1) <= level + 2 then pick = g break end
        if (g.minLevel or 1) <= level then pick = g end
    end
    if pick then self:Activate(pick.id) end
    if ns.Tracker then ns.Tracker:SetMode("guide") end
    return target, pick
end

--- Pick the guide that fits this character best: level range first, then
--- the zone the player is standing in, then the same continent, then the
--- guide's own starting-zone chain (a dwarf gets Loch Modan, not Darkshore).
--- The chapter of the route this character follows that fits its level (nil when none does).
function Guide:RouteChapterForLevel(level)
    level = level or ns.Player:GetLevel()
    local route = self:CurrentRoute()
    if not route then return nil end
    local best
    for _, g in ipairs(route.chapters) do
        local lo, hi = g.minLevel or 1, g.maxLevel or 60
        if level >= lo and level <= hi then
            if not best or (g.minLevel or 1) > (best.minLevel or 1) then best = g end
        end
    end
    return best, route
end

--- The active guide belongs to ANOTHER race's route (not a zone guide, not the followed route):
--- a dwarf sent to Ashenvale by a zone switch or a hand-picked chapter. Returns that route's label
--- and the chapter of the character's own route that would fit instead.
function Guide:OffRouteChapter()
    local g = self.active
    if not g then return nil end
    local key, race = self:RouteOf(g)
    if not key then return nil end                        -- GEN_ZONE_* / hand-written guides: fine
    if self:ForMyRace(g) and not self:IsAlternate(g) then return nil end   -- our own route
    if ns.char.route == key then return nil end           -- the player asked for this one
    local mine = self:RouteChapterForLevel()
    if not mine or mine.id == g.id then return nil end
    return race, mine
end

function Guide:AutoPick()
    local level = ns.Player:GetLevel()
    local curMap = ns.Player:GetMapID()
    local curName = curMap and ns.Player:GetMapName(curMap)
    local _, _, curInst = ns.Player:GetWorldPosition()
    -- the chapters of the route the character follows (chosen, else the race's own)
    local chain = {}
    local route = self:CurrentRoute()
    if route then for _, g in ipairs(route.chapters) do chain[g.id] = true end end
    local best, bestScore = nil, nil
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        -- an alternate route's chapter only once the player has chosen that route
        if self:Applicable(g) and not self:IsDungeon(g) and (chain[g.id] or not self:IsAlternate(g)) then
            local minL, maxL = g.minLevel or 1, g.maxLevel or 60
            local score = 0
            if level < minL or level > maxL then
                score = 10 * math.min(math.abs(level - minL), math.abs(level - maxL))
            end
            if g.map and curMap and g.map == curMap then
                score = score - 5                           -- standing in it
            elseif g.zone and curName and g.zone == curName then
                score = score - 5
            elseif g.map and curInst and ns.Navigation then
                local inst = ns.Navigation:MapToWorld(g.map, 50, 50)
                if inst and inst ~= curInst then score = score + 4 end   -- other continent
            end
            if not chain[g.id] then
                -- off the route we follow: a zone guide is a fair stand-in, another race's chapter is not
                local key = self:RouteOf(g)
                score = score + ((key and not self:ForMyRace(g)) and 12 or (ns.char.route and 8 or 2))
            end
            if not bestScore or score < bestScore then best, bestScore = g, score end
        end
    end
    return best
end

-- ------------------------------------------------------------
-- Step evaluation
-- ------------------------------------------------------------
---@param step FGStep
function Guide:StepApplies(step)
    if step.quest and ns.DB and ns.DB:IsRemoved(step.quest) then return false end   -- quest gone from Forever
    -- a quest this character can never take (a race- or class-only quest the route planner offered
    -- to the whole faction): the giver has nothing to say, so the step and its turn-in are not ours
    if step.quest and ns.DB and ns.DB:IsLoaded() and not ns.DB:RaceClassOK(step.quest) then return false end
    if step.faction then
        local f = ns.Player:GetFaction()
        if f and string.upper(step.faction) ~= string.upper(f) then return false end
    end
    if step.class then
        local _, classFile = ns.Player:GetClass()
        if classFile and not ns.Contains(step.class, classFile) then return false end
    end
    if step.race then
        local _, raceFile = ns.Player:GetRace()
        if raceFile and not ns.Contains(step.race, raceFile) then return false end
    end
    if step.profession then
        local rank = ns.Player:ProfessionRank(step.profession)
        if rank and rank < (step.skill or 1) then return false end
    end
    return true
end

local function ItemCount(itemID)
    return PlainNumber(ns.Call("C_Item.GetItemCount", itemID, true)) or 0
end

local function SpellKnown(spellID)
    local known = Plain(ns.Call("C_SpellBook.IsSpellKnown", spellID))
    if known == nil then known = Plain(ns.Safe(rawget(_G, "IsSpellKnown"), spellID)) end
    if known == nil then known = Plain(ns.Safe(rawget(_G, "IsPlayerSpell"), spellID)) end
    return known == true
end

--- Is a step done according to game state (or manual completion)?
--- Is the step done? `gameOnly` ignores steps marked done or skipped by hand.
function Guide:IsStepDone(step, idx, gameOnly)
    local p = self.progress
    if p and p.done[idx] and not gameOnly then return true, "manual" end
    if not self:StepApplies(step) then return true, "n/a" end

    local Q = ns.Quest
    local t = step.type
    if step.quest and Q:IsCompleted(step.quest) then
        -- The completion flag cannot be right while the quest still sits in the log: on the
        -- Forever client it has come back true for a ready-to-turn-in quest right after a
        -- /reload (Hilary's Necklace, 2026-09-20) and the guide walked past the turn-in.
        -- The log is the better witness; an ACCEPT step is done either way.
        if t == "ACCEPT" or not Q:IsOnQuest(step.quest) then return true, "quest completed" end
        ns.Debug(string.format("completion flag set for %s (%d) although it is still in the log - ignoring it", ns.Quest:GetTitle(step.quest) or "?", step.quest))
    end

    -- A breadcrumb whose quest the player already has, or has done, is never offered again:
    -- Rejold's New Brew (415) after Shimmer Stout (413) was taken at Rejold's first. Its steps
    -- are passed, not waited on (seen live, 2026-09-27).
    if step.quest and (t == "ACCEPT" or t == "TURNIN") and not Q:IsOnQuest(step.quest) and ns.DB and ns.DB:IsLoaded() then
        local q = ns.DB:GetQuest(step.quest)
        local target = q and q.breadcrumb
        if target and (Q:IsOnQuest(target) or Q:IsCompleted(target)) then return true, "breadcrumb passed" end
    end

    if t == "ACCEPT" then
        return Q:IsOnQuest(step.quest), nil
    elseif t == "TURNIN" then
        return false, nil                       -- only via the flag check above
    elseif OBJECTIVE[t] then
        if not Q:IsOnQuest(step.quest) then return false, nil end
        if Q:IsReadyForTurnIn(step.quest) then return true, "ready" end
        local objIdx = self:StepObjectiveIndex(step)
        if objIdx then
            -- every objective this step covers must be finished
            local allCovered, matched = true, false
            local objs = Q:GetObjectives(step.quest) or {}
            local keys = step.target and string.gmatch(step.target, "[^/]+")
            if keys then
                for part in keys do
                    local lower = string.lower(ns.Trim(part))
                    for _, o in ipairs(objs) do
                        if o.text and string.find(string.lower(o.text), lower, 1, true) then
                            matched = true
                            if not o.finished then allCovered = false end
                        end
                    end
                end
            end
            if not matched then
                -- the guide's wording matches no live objective text (the index came from the DB's
                -- npc/item name): judge the objective the index points at, never "done by default"
                local o = Q:GetObjective(step.quest, objIdx)
                allCovered = o ~= nil and o.finished == true
            end
            return allCovered, nil
        end
        local _, _, allDone = Q:GetProgress(step.quest)
        return allDone == true, nil
    elseif t == "GRIND" then
        return ns.Player:GetLevel() >= (step.level or 0), nil
    elseif t == "BUY" then
        return ItemCount(step.item) >= (step.count or 1), nil
    elseif t == "TRAIN" then
        return SpellKnown(step.spell), nil
    elseif t == "HEARTH" then
        local bind = ns.PlainString(ns.Safe(rawget(_G, "GetBindLocation")))
        if bind and step.zone then return bind == step.zone, nil end
        return false, nil
    elseif t == "FLIGHTPATH" then
        -- a path learnt before (this guide, another guide, or on the character's own) is not asked for again
        local R = ns.Reminders
        local node = R and R:NodeAt(step.map, step.x, step.y)
        return node ~= nil and R.Known()[node] == true, nil
    elseif t == "TRAVEL" or t == "FLY" then
        -- "travel to Westfall" is done the moment you are in Westfall: its coordinates are only
        -- the hub the route wants next, and the step after it points there anyway. A travel step
        -- INSIDE the zone you are already in ("follow the road south") still needs the arrival
        -- (FG_NAV_ARRIVED), or it would tick itself off where you stand.
        if self:IsZoneEntry(step, idx) then return self:OnStepMap(step), nil end
        return false, nil
    end
    return false, nil   -- manual types
end

--- A TRAVEL/FLY step that crosses into another zone (the first mapped step of a chapter,
--- or one whose map differs from the step before it) - as opposed to moving around inside
--- the zone you are already in.
function Guide:IsZoneEntry(step, idx)
    if not step or not step.map or not idx then return false end
    local steps = self.active and self.active.steps
    if not steps then return false end
    local k = self:PrevIdx(idx)
    while k do
        local s = steps[k]
        if s and s.map then return s.map ~= step.map end
        k = self:PrevIdx(k)
    end
    return true      -- nothing mapped before it: the chapter starts by going there
end

--- Is the player on the step's map / in its zone? Walks the map's parents, so a
--- sub-zone map (a cave, a city inside the zone) still counts as the zone.
function Guide:OnStepMap(step)
    if not step then return false end
    local zone = ns.PlainString(ns.Safe(rawget(_G, "GetZoneText")))
    if step.zone and zone and zone ~= "" and zone == step.zone then return true end
    if not step.map then return false end
    local mapID, tries = ns.Player:GetMapID(), 0
    while mapID and tries < 5 do
        if mapID == step.map then return true end
        local info = ns.Call("C_Map.GetMapInfo", mapID)
        mapID = type(info) == "table" and ns.PlainNumber(info.parentMapID) or nil
        tries = tries + 1
    end
    return false
end

--- Which live objective a KILL/COLLECT/COMPLETE step refers to: the explicit
--- `objective` index, else the objective whose text names the step's target
--- (guides generated from the database emit one step per objective).
function Guide:StepObjectiveIndex(step)
    if step.objective then return step.objective end
    if not step.quest then return nil end
    local objs = ns.Quest:GetObjectives(step.quest)
    if not objs or #objs <= 1 then return nil end
    local keys = {}
    if step.target then
        for part in string.gmatch(step.target, "[^/]+") do keys[#keys + 1] = ns.Trim(part) end
    end
    if ns.DB and ns.DB:IsLoaded() then
        if step.npc then keys[#keys + 1] = ns.DB:NPCName(step.npc) end
        if step.item then keys[#keys + 1] = ns.DB:ItemName(step.item) end
    end
    if #keys == 0 then return nil end
    -- several targets merged into one step ("A / B"): the first unfinished one wins
    local firstMatch
    for _, key in ipairs(keys) do
        if key and key ~= "" then
            local lower = string.lower(key)
            for idx, o in ipairs(objs) do
                if o.text and o.text ~= "" and string.find(string.lower(o.text), lower, 1, true) then
                    if not o.finished then return idx end
                    firstMatch = firstMatch or idx
                end
            end
        end
    end
    return firstMatch
end

--- A quest step that cannot progress because the quest is not in the log.
function Guide:IsStepBlocked(step)
    if not step.quest then return false end
    if step.type == "TURNIN" or OBJECTIVE[step.type] then
        local Q = ns.Quest
        return not Q:IsOnQuest(step.quest) and not Q:IsCompleted(step.quest)
    end
    return false
end

--- The quest's ACCEPT step at or before `before` in the walking order (anywhere when nil).
function Guide:FindAcceptStep(questID, before)
    local steps = self.active.steps
    local seq = self:Order()
    local limit = before and self:PosOf(before) or #seq
    for k = 1, math.min(limit, #seq) do
        local s = steps[seq[k]]
        if s.type == "ACCEPT" and s.quest == questID then return seq[k] end
    end
    return nil
end

-- ------------------------------------------------------------
-- Step order: the player's own order on top of the guide's
-- ------------------------------------------------------------
-- A step offered at a bad moment can be put off (Later) or pulled forward (Do now) instead of
-- skipped for good. progress.order lists the moves in the order they were made, { idx, after }:
-- step idx goes right after step `after` (0 = first); every other step keeps its file order. A
-- step's index never changes, so done, deferred, edits and the nav target keep working; only the
-- walk (next / previous / before) goes through Order().

local LATER = 5          -- open steps a "Later" step is put behind

--- seq[pos] = step index and pos[step index] = position, for the active guide.
function Guide:Order()
    local g, p = self.active, self.progress
    if not g then return {}, {} end
    local steps = g.steps
    local n = #steps
    local c = self.orderCache
    local moves = p and p.order
    if c and c.g == g and c.p == p and c.n == n and c.moves == moves and c.count == (moves and #moves or 0) then
        return c.seq, c.pos
    end
    local moved = {}
    for _, m in ipairs(moves or {}) do
        if steps[m[1]] and (m[2] == 0 or steps[m[2]]) and m[1] ~= m[2] then moved[m[1]] = m end
    end
    local seq, placed = {}, {}
    for i = 1, n do
        if not moved[i] then seq[#seq + 1] = i placed[i] = true end
    end
    -- each move right after its anchor, in the order the moves were made (the latest move sits
    -- closest to the anchor); a move whose anchor is itself moved waits until the anchor is placed
    local pending = {}
    for _, m in ipairs(moves or {}) do if moved[m[1]] == m then pending[#pending + 1] = m end end
    local progressed = true
    while #pending > 0 and progressed do
        progressed = false
        local rest = {}
        for _, m in ipairs(pending) do
            local idx, after = m[1], m[2]
            if after == 0 or placed[after] then
                local at = 1
                if after ~= 0 then
                    for k, v in ipairs(seq) do if v == after then at = k + 1 break end end
                end
                table.insert(seq, at, idx)
                placed[idx] = true
                progressed = true
            else
                rest[#rest + 1] = m
            end
        end
        pending = rest
    end
    -- anchors that never resolve (moves that point at each other): back to the file order
    for _, m in ipairs(pending) do
        local at = #seq + 1
        for k, v in ipairs(seq) do if v > m[1] then at = k break end end
        table.insert(seq, at, m[1])
    end
    local pos = {}
    for k, idx in ipairs(seq) do pos[idx] = k end
    self.orderCache = { g = g, p = p, n = n, moves = moves, count = moves and #moves or 0, seq = seq, pos = pos }
    return seq, pos
end

--- Position of a step in the walking order; past the end (#steps + 1) is the "finished" slot.
function Guide:PosOf(idx)
    local seq, pos = self:Order()
    return pos[idx] or (#seq + 1)
end

--- The step after `idx` in the walking order, or #steps + 1 past the last one.
function Guide:NextIdx(idx)
    local seq, pos = self:Order()
    local k = pos[idx]
    if not k then return #seq + 1 end
    return seq[k + 1] or (#seq + 1)
end

--- The step before `idx` in the walking order, or nil at the first one.
function Guide:PrevIdx(idx)
    local seq, pos = self:Order()
    local k = pos[idx] or (#seq + 1)
    return seq[k - 1]
end

--- The first step in the walking order.
function Guide:FirstIdx()
    local seq = self:Order()
    return seq[1] or 1
end

--- Step indices from `idx` (included) to the end, in the walking order.
function Guide:OrderFrom(idx)
    local seq, pos = self:Order()
    local out = {}
    for k = pos[idx] or 1, #seq do out[#out + 1] = seq[k] end
    return out
end

--- The player moved this step (Later / Do now).
function Guide:IsMoved(idx)
    for _, m in ipairs(self.progress and self.progress.order or {}) do if m[1] == idx then return true end end
    return false
end

--- A step the walk would still stop at: applies to this character and is not done.
function Guide:IsOpen(idx)
    local s = self.active and self.active.steps[idx]
    if not s or not self:StepApplies(s) then return false end
    return not (self.progress.done[idx] or self:IsStepDone(s, idx))
end

--- Put the steps of `block` right after `after`, in that order.
function Guide:PlaceAfter(block, after)
    local p = self.progress
    p.order = p.order or {}
    local inBlock = {}
    for _, idx in ipairs(block) do inBlock[idx] = true end
    local kept = {}
    for _, m in ipairs(p.order) do if not inBlock[m[1]] then kept[#kept + 1] = m end end
    -- the anchor is the step before the block's new place, so it must not be in the block itself
    for i, idx in ipairs(block) do kept[#kept + 1] = { idx, i == 1 and after or block[i - 1] } end
    p.order = kept
    self.orderCache = nil
end

--- Put a step off: it comes back after the next few open steps. The same quest's later steps in
--- between (its objective and turn-in behind a postponed accept) go with it, so they stay in order.
function Guide:Later(idx)
    local g, p = self.active, self.progress
    if not g or not p then return false end
    idx = idx or self.current
    local step = idx and g.steps[idx]
    if not step then return false end
    if not self:IsOpen(idx) then ns.Print("that step is already done.") return false end
    local anchor, seen, k = nil, 0, self:NextIdx(idx)
    local block = { idx }
    while g.steps[k] do
        local s = g.steps[k]
        if step.quest and s.quest == step.quest then
            block[#block + 1] = k
        elseif self:IsOpen(k) then
            seen = seen + 1
            anchor = k
            if seen >= LATER then break end
        end
        k = self:NextIdx(k)
    end
    if not anchor then ns.Print("that is already the last step.") return false end
    -- steps of the quest past the anchor stay where they are
    local within = { idx }
    for i = 2, #block do
        if self:PosOf(block[i]) < self:PosOf(anchor) then within[#within + 1] = block[i] end
    end
    -- putting off the current step: the walk goes on at the first step that stays where it is
    local moving = {}
    for _, b in ipairs(within) do moving[b] = true end
    local cur = self.current
    if cur and moving[cur] then
        local start = cur
        while moving[start] do start = self:NextIdx(start) end
        p.step = start
    end
    self:PlaceAfter(within, anchor)
    self.hold, self.current = nil, nil
    ns.Printf("Later: %s", self:GetStepText(step))
    self:Evaluate("later")
    return true
end

--- Do this step next: it becomes the current step and the old current step follows it. A skipped
--- step comes back (a skipped accept brings its whole quest back); the same quest's open steps
--- that belong before it (its accept, before a turn-in) come along.
function Guide:DoNow(idx)
    local g, p = self.active, self.progress
    if not g or not p then return false end
    local step = idx and g.steps[idx]
    if not step then return false end
    if not self:StepApplies(step) then ns.Print("that step is not for this character.") return false end
    if p.skipped and p.skipped[idx] then
        if step.type == "ACCEPT" and step.quest then
            for j, s in ipairs(g.steps) do if s.quest == step.quest then p.done[j] = nil p.skipped[j] = nil end end
        end
        p.skipped[idx] = nil
    end
    p.done[idx] = nil
    local cur = self.current
    if cur == idx then return true end
    local after = cur and g.steps[cur] and self:PrevIdx(cur) or nil
    local block = {}
    if step.quest then
        -- this quest's open steps that come before it in its own order and are not already behind us
        local from = cur and g.steps[cur] and self:PosOf(cur) or 1
        for _, j in ipairs(self:Order()) do
            if j == idx then break end
            if g.steps[j].quest == step.quest and self:PosOf(j) >= from and self:IsOpen(j) then block[#block + 1] = j end
        end
    end
    block[#block + 1] = idx
    if cur and g.steps[cur] then
        local inBlock = {}
        for _, b in ipairs(block) do inBlock[b] = true end
        while after and inBlock[after] do after = self:PrevIdx(after) end
        self:PlaceAfter(block, after or 0)
    end
    p.step = block[1]
    self.hold, self.current = nil, nil
    ns.Printf("Now: %s", self:GetStepText(step))
    self:Evaluate("now")
    return true
end

--- Back to the guide's own order.
function Guide:ResetOrder()
    local p = self.progress
    if not p or not p.order or #p.order == 0 then return false end
    -- restart the walk at the earliest step the player had moved or is on, so nothing that was put
    -- off ends up behind the walk
    local start = self.current
    for _, m in ipairs(p.order) do
        if self:IsOpen(m[1]) and (not start or m[1] < start) then start = m[1] end
    end
    p.order = nil
    self.orderCache = nil
    if start then p.step = start end
    self.hold, self.current = nil, nil
    self:Evaluate("order")
    return true
end

--- Steps skipped by hand in the active guide that are still skipped, in walking order.
function Guide:SkippedSteps()
    local p = self.progress
    local out = {}
    if not self.active or not p or not p.skipped then return out end
    for _, idx in ipairs(self:Order()) do
        if p.skipped[idx] and p.done[idx] then out[#out + 1] = idx end
    end
    return out
end

--- Recompute the current step from the persisted position and game state.
--- The level an ACCEPT step's quest needs above the player's (nil when it can be taken).
function Guide:LevelGate(step)
    if not step or step.type ~= "ACCEPT" or not step.quest or not ns.DB or not ns.DB:IsLoaded() then return nil end
    local Q = ns.Quest
    if Q:IsOnQuest(step.quest) or Q:IsCompleted(step.quest) then return nil end
    local q = ns.DB:GetQuest(step.quest)
    local level = ns.Player:GetLevel()
    if q and q.req and level < q.req then return q.req end
    return nil
end

function Guide:Evaluate(reason)
    local g, p = self.active, self.progress
    if not g or not p then return end
    local steps = g.steps
    local i = p.step
    self.blocked = false
    if self.recovery and (self.recovery.step ~= i or ns.Quest:IsOnQuest(self.recovery.quest)) then self.recovery = nil end
    self.note = self.recovery and self.recovery.note or nil
    p.deferred = p.deferred or {}

    -- 0. quests skipped earlier because the level was too low: back to them once it is reached
    for quest, acceptIdx in pairs(p.deferred) do
        local s = steps[acceptIdx]
        if not s or s.quest ~= quest or p.done[acceptIdx] or ns.Quest:IsCompleted(quest) then
            p.deferred[quest] = nil
        elseif ns.Quest:IsOnQuest(quest) then
            -- the player took the quest by hand (a level-independent giver, or a level we misjudged):
            -- its objective steps were passed over as deferred, so go back and work them
            p.deferred[quest] = nil
            if self:PosOf(acceptIdx) < self:PosOf(i) then
                i = acceptIdx
                self.note = string.format("%s is in your log - back to it.", ns.Quest:GetTitle(quest) or ("quest " .. quest))
            end
        elseif not self:LevelGate(s) then
            p.deferred[quest] = nil
            if self:PosOf(acceptIdx) < self:PosOf(i) then
                i = acceptIdx
                self.note = string.format("level reached - back to %s.", ns.Quest:GetTitle(quest) or ("quest " .. quest))
            end
        end
    end

    -- 0b. an optional (group / elite) quest the route only offered: its steps were walked past, so
    --     once the player takes it by hand the guide goes back and works it like any other quest
    for quest, idx in pairs(self.optionalPassed or {}) do
        local s = steps[idx]
        if not s or s.quest ~= quest or p.done[idx] or ns.Quest:IsCompleted(quest) then
            self.optionalPassed[quest] = nil
        elseif ns.Quest:IsOnQuest(quest) and self:PosOf(idx) < self:PosOf(i) then
            self.optionalPassed[quest] = nil
            i = idx
            self.note = string.format("%s is in your log - back to it.", ns.Quest:GetTitle(quest) or ("quest " .. quest))
        end
    end

    -- 1. advance over done steps; auto-complete manual steps when the next
    --    automatic step is already done; skip quests the level does not allow yet
    local guard = 0
    if self.hold and self.hold ~= p.step then self.hold = nil end
    while steps[i] and i ~= self.hold and guard < #steps + 5 do
        guard = guard + 1
        local step = steps[i]
        if step.quest and step.type == "ACCEPT" and ns.DB and ns.DB:IsLoaded() and not p.done[i] then
            local ok, why = ns.DB:RaceClassOK(step.quest)
            if not ok then
                self.notForYou = self.notForYou or {}
                if not self.notForYou[step.quest] then
                    self.notForYou[step.quest] = true
                    ns.Printf("%s is %s - not one you can take; the route skips it.",
                        ns.DB:QuestName(step.quest) or ("quest " .. step.quest),
                        why == "wrong class" and "for another class" or "for another race")
                end
            end
        end
        local done = self:IsStepDone(step, i)
        if not done and step.quest then
            local need = self:LevelGate(step)
            if need then
                p.deferred[step.quest] = i
                self.note = string.format("%s needs level %d - skipped until then.", ns.Quest:GetTitle(step.quest) or ("quest " .. step.quest), need)
                done = true      -- passed over for now, not marked done
            elseif p.deferred[step.quest] and not ns.Quest:IsOnQuest(step.quest) then
                done = true      -- an objective / turn-in of a quest we could not take yet
            end
        end
        -- optional quest steps (group / elite quests the route only offers) are walked past unless the
        -- player opted in by taking the quest: then its objectives and turn-in are guided like any other
        if not done and step.optional and step.quest then
            local opted = step.type ~= "ACCEPT" and ns.Quest:IsOnQuest(step.quest)
            if not opted then
                done = true                     -- passed over, not marked done
                -- remember where it was: taking it by hand later brings the guide back (see 0b)
                if not ns.Quest:IsCompleted(step.quest) then
                    self.optionalPassed = self.optionalPassed or {}
                    local at = self.optionalPassed[step.quest]
                    if not at or self:PosOf(i) < self:PosOf(at) then self.optionalPassed[step.quest] = i end
                end
            end
        end
        -- manual steps and other optional steps complete themselves once the player is past them
        if not done and (MANUAL[step.type] or step.optional) then
            -- look at the next few automatic steps, not only the first one: quests accepted out of
            -- order (or a hub already visited) are proof the player is past this travel / note step,
            -- even when the step right after it is still open.
            local k, seen = self:NextIdx(i), 0
            while steps[k] and seen < LOOKAHEAD do
                if not (MANUAL[steps[k].type] or not self:StepApplies(steps[k])) then
                    seen = seen + 1
                    if self:IsStepDone(steps[k], k) or p.done[k] then
                        p.done[i] = true
                        done = true
                        break
                    end
                end
                k = self:NextIdx(k)
            end
        end
        if not done then break end
        i = self:NextIdx(i)
    end

    -- a standing reminder while something is skipped for level
    if not self.note and next(p.deferred) then
        for quest in pairs(p.deferred) do
            local q = ns.DB and ns.DB:GetQuest(quest)
            if q and q.req then
                self.note = string.format("%s needs level %d - skipped until then.", ns.Quest:GetTitle(quest) or q.n or ("quest " .. quest), q.req)
                break
            end
        end
    end

    -- 1b. about to accept with a full quest log: name the quests this guide does not need
    if steps[i] and steps[i].type == "ACCEPT" and steps[i].quest and not ns.Quest:IsOnQuest(steps[i].quest) and not self.note then
        local n, max = ns.Quest:GetNumQuests()
        if max and max > 0 and n >= max then
            local needed = {}
            for _, k in ipairs(self:OrderFrom(i)) do if steps[k].quest then needed[steps[k].quest] = true end end
            local spare = {}
            for _, id in ipairs(ns.Quest.order or {}) do
                if not needed[id] then spare[#spare + 1] = ns.Quest:GetTitle(id) or ("quest " .. id) end
                if #spare >= 4 then break end
            end
            self.note = string.format("Quest log full (%d/%d). %s", n, max,
                #spare > 0 and ("Not needed by this guide: " .. table.concat(spare, ", ") .. " - abandon one.") or "Turn something in first.")
            self.logFull = true
        else
            self.logFull = nil
        end
    end

    -- 2. recovery: quest missing from the log
    if steps[i] and self:IsStepBlocked(steps[i]) then
        local acceptIdx = self:FindAcceptStep(steps[i].quest, i)
        if acceptIdx and not p.done[acceptIdx] then
            local title = ns.Quest:GetTitle(steps[i].quest) or ("quest " .. steps[i].quest)
            self.note = string.format("%s is not in your quest log - back to accepting it.", title)
            self.recovery = { step = acceptIdx, quest = steps[i].quest, note = self.note }
            i = acceptIdx
        else
            self.blocked = true
            local title = ns.Quest:GetTitle(steps[i].quest) or ("quest " .. steps[i].quest)
            self.note = string.format("%s is not in your log. Accept it, or /fg skip.", title)
        end
    end

    local changed = (i ~= self.current) or (p.step ~= i)
    p.step = i
    self.current = i

    if not steps[i] then
        -- guide finished: a dungeon guide hands back to the chapter it was opened from
        local back = self:IsDungeon(g) and ns.char.returnGuide and self.registry[ns.char.returnGuide]
        if back and back ~= g and (self.chainDepth or 0) < 10 then
            ns.Printf("%s done - back to '%s'.", g.name or g.id, back.name or back.id)
            self.chainDepth = (self.chainDepth or 0) + 1
            self:Activate(back.id)
            self.chainDepth = self.chainDepth - 1
            return
        end
        if g.next and self.registry[g.next] and self.registry[g.next] ~= g and (self.chainDepth or 0) < 10 then
            ns.Printf("Guide '%s' complete - continuing with '%s'.", g.name or g.id, self.registry[g.next].name or g.next)
            self.chainDepth = (self.chainDepth or 0) + 1
            self:Activate(g.next)
            self.chainDepth = self.chainDepth - 1
            return
        end
        if not (ns.Tracker and ns.Tracker:IsActive()) then ns.Navigation:Clear() end
        if changed then ns.Events:Fire("FG_STEP_CHANGED", nil, g) end
        return
    end

    self:UpdateNavigation()
    if changed then
        ns.Events:Fire("FG_STEP_CHANGED", steps[i], g, reason)
    else
        ns.Events:Fire("FG_STEP_UPDATED", steps[i], g, reason)
    end
end

function Guide:UpdateNavigation()
    if ns.Navigation.override then return end                  -- a ghost walks to its corpse first (Corpse.lua)
    if ns.Tracker and ns.Tracker:IsActive() then return end   -- tracker drives navigation (auto mode, or no guide)
    local step = self:GetCurrentStep()
    if not step then ns.Navigation:Clear() return end
    local mapID, x, y = ns.Navigation:ResolveStep(step)
    if mapID then
        local t = ns.Navigation.target
        local eff = ns.Editor and ns.Editor:Effective(step) or step
        local label = self:GetStepText(step)
        -- same spot for two steps in a row (accept then turn in at one npc) still needs a fresh
        -- target: the label, the radius and the one-shot arrival latch belong to the step
        if not (t and t.map == mapID and t.x == x and t.y == y and t.label == label and t.radius == (eff.radius or t.radius)
                and t.guide == self.active.id and t.step == step.index) then
            ns.Navigation:SetTarget({ map = mapID, x = x, y = y, label = label, radius = eff.radius, owner = "guide",
                                      guide = self.active.id, step = step.index })
        end
    else
        ns.Navigation:Clear()
    end
end

-- ------------------------------------------------------------
-- Activation / manual control
-- ------------------------------------------------------------
function Guide:Activate(id, silent)
    local g = self.registry[id]
    if not g then
        ns.Error("unknown guide: " .. tostring(id))
        return false
    end
    -- a dungeon guide remembers the chapter it was opened from; opening a chapter forgets it
    if self:IsDungeon(g) then
        if self.active and not self:IsDungeon(self.active) then ns.char.returnGuide = self.active.id end
    else
        ns.char.returnGuide = nil
    end
    self.active = g
    self.progress = ns.Database:GuideProgress(g.id, g.version)
    self.current = nil
    self.hold, self.recovery = nil, nil
    ns.char.activeGuide = g.id
    if not silent then ns.Printf("Guide: %s%s%s (%d steps)", ns.COLOR_OK, g.name or g.id, ns.COLOR_END, #g.steps) end
    self:Evaluate("activate")
    if self.active ~= g then return true end   -- finished instantly and chained into the next guide
    ns.Events:Fire("FG_GUIDE_CHANGED", g)
    self:WarnOffRoute()
    return true
end

--- One line when the active chapter is another race's (a zone switch or a hand-picked chapter left
--- a dwarf on the Night Elf route): quests only that race can take are skipped, so say so once.
function Guide:WarnOffRoute()
    local race, mine = self:OffRouteChapter()
    if not race then self.warnedOffRoute = nil return end
    if self.warnedOffRoute == (self.active and self.active.id) then return end
    self.warnedOffRoute = self.active and self.active.id
    ns.Printf("this is the %s route's chapter - your own route has %s for level %d. /fg path race goes back to it (or /fg guide %s).",
        ROUTE_LABEL[race] or race, mine.name or mine.id, ns.Player:GetLevel(), mine.id)
end

--- Number of steps without forcing a lazy guide to load its steps.
function Guide.StepCount(g)
    return g and (rawget(g, "stepCount") or (rawget(g, "steps") and #g.steps) or 0) or 0
end

local USE_ITEM_STEP = { KILL = true, COLLECT = true, COMPLETE = true }

--- The item the player clicks for this step, or nil: the quest's usable item while its objectives
--- are open, or on an accept step the item in your bags that starts the quest.
---@return number?
function Guide:StepUseItem(step)
    if not step or not step.quest then return nil end
    if step.type == "ACCEPT" then return ns.Quest:StarterItem(step.quest) end
    if not USE_ITEM_STEP[step.type] then return nil end
    return ns.Quest:UsableItem(step.quest)
end

function Guide:GetCurrentStep()
    if not self.active or not self.current then return nil end
    return self.active.steps[self.current]
end

--- Mark the given (or current) step done and re-evaluate.
function Guide:MarkDone(idx, reason)
    if not self.active or not self.progress then return end
    idx = idx or self.current
    local step = self.active.steps[idx]
    if not step then return end
    self.progress.done[idx] = true
    if reason == "skip" then
        -- remembered, so /fg skipped can bring it back
        self.progress.skipped = self.progress.skipped or {}
        self.progress.skipped[idx] = true
    end
    if self.hold == idx then self.hold = nil end
    -- skipping an ACCEPT step means skipping that quest entirely
    if step.type == "ACCEPT" and step.quest and reason == "skip" then
        for j, s in ipairs(self.active.steps) do
            if s.quest == step.quest then self.progress.done[j] = true end
        end
    end
    self:Evaluate(reason or "done")
end

function Guide:Skip()
    local step = self:GetCurrentStep()
    if not step then return end
    ns.Printf("Skipped step %d: %s (still in the list: right-click > Do now brings it back)", self:PosOf(step.index), self:GetStepText(step))
    self:MarkDone(step.index, "skip")
end

function Guide:Back()
    if not self.active or not self.progress then return end
    local i = self:PrevIdx(self.current or self:FirstIdx()) or self:FirstIdx()
    -- walk back over steps that do not apply to this character
    while self:PrevIdx(i) and not self:StepApplies(self.active.steps[i]) do i = self:PrevIdx(i) end
    self.progress.done[i] = nil
    if self.progress.skipped then self.progress.skipped[i] = nil end
    self.progress.step = i
    self.current = nil
    self.hold = i        -- stay here even if the game says it is done (until /fg skip or a real change)
    self:Evaluate("back")
    if self.current == i then ns.Printf("Back to step %d (held; /fg skip to move on).", i) end
end

function Guide:SetStep(n)
    if not self.active or not self.progress then return end
    n = math.max(1, math.min(#self.active.steps, math.floor(n)))
    self.hold = nil
    for _, j in ipairs(self:OrderFrom(n)) do
        self.progress.done[j] = nil
        if self.progress.skipped then self.progress.skipped[j] = nil end
    end
    self.progress.step = n
    self.current = nil
    self:Evaluate("jump")
end

--- Level-aware resync (recovery when the player levelled elsewhere or
--- skipped around): jump to the first step that is not done, skipping
--- whole quests that would give almost no xp any more (unless a later step
--- of the guide needs them). Returns the number of quests skipped.
function Guide:Resync()
    if not self.active or not self.progress then return 0 end
    local steps, p, Q = self.active.steps, self.progress, ns.Quest
    local needed = {}
    if ns.DB and ns.DB:IsLoaded() then
        for _, s in ipairs(steps) do
            local q = s.quest and ns.DB:GetQuest(s.quest)
            if q then
                for _, pre in ipairs(q.pregroup or {}) do needed[pre] = true end
                for _, pre in ipairs(q.pre or {}) do needed[pre] = true end
                if q.parent then needed[q.parent] = true end
            end
        end
    end
    local skipped, skippedQuests = 0, {}
    for i, s in ipairs(steps) do
        if s.quest and not skippedQuests[s.quest] and not p.done[i] and self:StepApplies(s)
            and not Q:IsCompleted(s.quest) and not Q:IsOnQuest(s.quest) and not needed[s.quest]
            and Q:XPMultiplier(s.quest) <= 0.2 then
            skippedQuests[s.quest] = true
            skipped = skipped + 1
        end
    end
    for i, s in ipairs(steps) do
        if s.quest and skippedQuests[s.quest] then p.done[i] = true end
    end
    -- everything before the furthest thing you have actually done is behind you: travel, notes and
    -- talk steps left open there would otherwise hold the guide at the top of the chapter forever
    local seq = self:Order()
    local last = 0
    for k, i in ipairs(seq) do
        local s = steps[i]
        if p.done[i] or (self:StepApplies(s) and self:IsStepDone(s, i)) then last = k end
    end
    for k = 1, last - 1 do
        if MANUAL[steps[seq[k]].type] then p.done[seq[k]] = true end
    end
    self.hold = nil
    self.current = nil
    p.step = self:FirstIdx()  -- re-walk from the top so done steps are skipped in one pass
    self:Evaluate("resync")
    return skipped
end

function Guide:Reset()
    if not self.active then return end
    ns.Database:ResetGuide(self.active.id)
    self.progress = ns.Database:GuideProgress(self.active.id, self.active.version)
    self.current = nil
    self:Evaluate("reset")
end

-- ------------------------------------------------------------
-- Display helpers
-- ------------------------------------------------------------
local VERB = {
    ACCEPT = "Accept", TURNIN = "Turn in", COMPLETE = "Complete", KILL = "Kill", COLLECT = "Collect",
    GRIND = "Grind to level", BUY = "Buy", TRAIN = "Train", HEARTH = "Set hearthstone at",
    TRAVEL = "Go to", FLY = "Fly to", TALK = "Talk to", FLIGHTPATH = "Get the flight path at", NOTE = "",
}

function Guide:GetStepText(step)
    if not step then return "" end
    if step.text and step.text ~= "" then return step.text end
    local t = step.type
    local verb = VERB[t] or t
    local DB = ns.DB
    if step.quest and (t == "ACCEPT" or t == "TURNIN" or OBJECTIVE[t]) then
        local title = ns.Quest:TitleWithLevel(step.quest, step.questName or ns.Quest:GetTitle(step.quest))
        local target = step.target
        if OBJECTIVE[t] and not target and DB and DB:IsLoaded() then
            local objs = DB:QuestObjectives(step.quest)
            local o = step.objective and objs[step.objective] or objs[1]
            if o and o.name then target = o.name end
        end
        if OBJECTIVE[t] and target then
            if step.count then return string.format("%s %d %s (%s)", verb, step.count, target, title) end
            return string.format("%s %s (%s)", verb, target, title)
        end
        return verb .. " " .. title
    elseif t == "GRIND" then
        return verb .. " " .. tostring(step.level)
    elseif t == "BUY" then
        return string.format("%s %d x %s", verb, step.count or 1, step.itemName or (DB and DB:ItemName(step.item)) or ("item " .. tostring(step.item)))
    elseif t == "TRAIN" then
        return verb .. " " .. tostring(step.spellName or ("spell " .. tostring(step.spell)))
    elseif t == "TALK" or t == "FLIGHTPATH" then
        return verb .. " " .. tostring(step.npcName or (DB and DB:NPCName(step.npc)) or ("NPC " .. tostring(step.npc)))
    elseif t == "TRAVEL" or t == "FLY" then
        return verb .. " " .. tostring(step.zone or (step.x and step.y and string.format("%.1f, %.1f", step.x, step.y)) or "destination")
    elseif t == "HEARTH" then
        local keeper = step.npcName or (step.npc and DB and DB:NPCName(step.npc))
        if keeper then return "Set your hearthstone with " .. keeper .. (step.zone and (" (" .. step.zone .. ")") or "") end
        return verb .. " " .. tostring(step.zone or "the inn")
    end
    return step.note or t
end

--- Progress text for the current step ("6 / 8", "ready to turn in", ...).
function Guide:GetStepProgress(step)
    if not step then return "" end
    local Q = ns.Quest
    local t = step.type
    if step.quest then
        if Q:IsCompleted(step.quest) then return "completed" end
        if t == "ACCEPT" then
            return Q:IsOnQuest(step.quest) and "accepted" or "not accepted"
        end
        if not Q:IsOnQuest(step.quest) then return "not in quest log" end
        if Q:IsReadyForTurnIn(step.quest) then return "ready to turn in" end
        if t == "TURNIN" then return "objectives not finished" end
        local f, r = Q:GetProgress(step.quest, self:StepObjectiveIndex(step))
        if r > 0 then return string.format("%d / %d", f, r) end
        return "in progress"
    elseif t == "GRIND" then
        return string.format("level %d / %d", ns.Player:GetLevel(), step.level or 0)
    elseif t == "BUY" then
        return string.format("%d / %d", ItemCount(step.item), step.count or 1)
    elseif t == "TRAIN" then
        return SpellKnown(step.spell) and "known" or "not learned"
    elseif t == "TRAVEL" or t == "FLY" then
        return ns.Navigation:Describe()
    end
    return step.note or ""
end

--- Position of the current step in the walking order (past the end when finished), and the total.
function Guide:GetStepCount()
    if not self.active then return 0, 0 end
    return self.current and self:PosOf(self.current) or 0, #self.active.steps
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
function Guide:OnInit()
    local function reeval(event) Guide:Evaluate(event) end
    ns.Events:RegisterMany({ "FG_QUEST_LOG_CHANGED", "FG_LEVEL_CHANGED", "FG_QUEST_TITLE_LOADED" }, reeval)
    ns.Events:Register("FG_LEVEL_CHANGED", function() Guide:WarnOffRoute() end)
    ns.Events:RegisterMany({ "BAG_UPDATE_DELAYED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_SKILL_LINE" }, function(event)
        ns.Events:Debounce("guide:" .. event, 0.3, function() Guide:Evaluate(event) end)
    end)
    -- a zone change can finish the chapter's travel step ("travel to Westfall" is done once you
    -- are in Westfall), so re-evaluate, not just re-aim the arrow
    ns.Events:Register("FG_ZONE_CHANGED", function(event)
        local step = Guide:GetCurrentStep()
        if step and (step.type == "TRAVEL" or step.type == "FLY") then Guide:Evaluate(event or "zone") end
        Guide:UpdateNavigation()
    end)

    -- TALK steps complete when the matching NPC window opens
    ns.Events:RegisterMany({ "GOSSIP_SHOW", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING", "MERCHANT_SHOW", "TRAINER_SHOW" },
        function()
            local step = Guide:GetCurrentStep()
            if not step or step.type ~= "TALK" then return end
            local npc = ns.Player:GetInteractionNPC()
            if not npc then return end
            if not step.npc or step.npc == npc.npcID then
                Guide:MarkDone(step.index, "talked")
            end
        end)

    -- FLIGHTPATH steps complete when that flight master's map opens (which learns the path), or when
    -- "New flight path discovered!" comes up while the step is the current one
    ns.Events:Register("TAXIMAP_OPENED", function()
        local step = Guide:GetCurrentStep()
        if not step or step.type ~= "FLIGHTPATH" then return end
        local npc = ns.Player:GetInteractionNPC()
        if not step.npc or not npc or step.npc == npc.npcID then Guide:MarkDone(step.index, "flight path") end
    end)
    -- HEARTH steps complete when the hearthstone is bound while the step is the current one, unless
    -- the NPC still open is another innkeeper. The inn's name does not matter here; GetBindLocation()
    -- only covers a bind made before the step (see IsStepDone).
    ns.Events:Register("HEARTHSTONE_BOUND", function()
        local step = Guide:GetCurrentStep()
        if not step or step.type ~= "HEARTH" then return end
        local npc = ns.Player:GetInteractionNPC()
        if not step.npc or not npc or step.npc == npc.npcID then Guide:MarkDone(step.index, "hearth bound") end
    end)
    ns.Events:Register("UI_INFO_MESSAGE", function(_, _, message)
        local step = Guide:GetCurrentStep()
        if not step or step.type ~= "FLIGHTPATH" then return end
        local want = rawget(_G, "ERR_NEWTAXIPATH")
        if want and ns.PlainString(message) == want then Guide:MarkDone(step.index, "flight path") end
    end)

    -- TRAVEL/FLY steps complete on arrival (Navigation is polled by the UI)
    ns.Events:Register("FG_NAV_ARRIVED", function(_, target)
        if not target or target.owner ~= "guide" then return end
        local step = Guide:GetCurrentStep()
        if step and (step.type == "TRAVEL" or step.type == "FLY") then
            Guide:MarkDone(step.index, "arrived")
        end
    end)
end

--- Forget the other faction's guides: their step loaders (about half of all guide bytecode) are
--- then free for the collector. A character with no side yet keeps everything; the open guide and
--- the one a dungeon returns to are always kept. A faction change means a relog, which reloads them.
function Guide:PruneForFaction()
    local faction = ns.Player:GetFaction()
    if not faction then return end
    local keep = {}
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if not g.faction or string.upper(g.faction) == string.upper(faction)
            or g == self.active or id == ns.char.activeGuide or id == ns.char.returnGuide then
            keep[#keep + 1] = id
        else
            self.registry[id] = nil
        end
    end
    self.list = keep
end

function Guide:OnEnable()
    self:PruneForFaction()
    local id = ns.char.activeGuide
    if id and self.registry[id] then
        self:Activate(id, true)
    elseif ns.char.autoPickGuide then
        local g = self:AutoPick()
        if g then self:Activate(g.id) end
    end
    if not self.active then
        ns.Warn("no guide active. /fg guides to list, /fg guide <name> to start one.")
    end
end

function Guide:OnEnterWorld()
    if self.active then self:Evaluate("enter-world") end
end
