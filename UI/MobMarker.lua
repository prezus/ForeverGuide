-- ============================================================
-- ForeverGuide / UI/MobMarker.lua
-- Skulls over the mobs the current step wants killed (or looted):
--
--        [ skull ]   <- the best pick: nearest untagged quest mob
--       Great Goretusk
--
--        [skull]     <- smaller: other mobs with identifiable open objectives
--                       in the quest log (including quests off the route)
--
-- When the current step wants no kill and has no item for the key, the quests in
-- the log take over: the nearest of their mobs gets the big skull and the target
-- key, so a quest the player picked up on their own is marked like a route one.
-- A mob's own tooltip (C_TooltipInfo.GetUnit: the quest lines the client shows on
-- mouseover) settles what the names cannot: an objective of yours still open there
-- marks it, every one of them completed takes its skull away. With `party` on (off by
-- default; `/fg skull party off`), a mob a party member still needs gets a small blue skull of its own.
--
-- Raid target icons (SetRaidTarget) are blocked for addons on this client
-- (ADDON_ACTION_FORBIDDEN, the same reason RestedXP disables them on 12.x),
-- so the skulls are our own textures anchored to the enemy nameplates.
-- That needs enemy nameplates on; with `plates` set (default) they are
-- switched on while a kill/collect step is current and restored afterwards.
-- "Nearest" without UnitPosition (nil for non-group units here): the
-- nameplate's engine-set scale, then its height on screen (a chase camera
-- looks down: lower on screen = closer). A mob tagged by someone else
-- (UnitIsTapDenied) gets no skull at all.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local MM = ns:NewModule("MobMarker")

local SKULL_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local SKULL_COORDS = { 0.75, 1, 0.25, 0.5 }    -- 4x4 atlas, index 8

local pool, used = {}, {}
local wanted, wantedAt = {}, 0     -- lower-case npc names for the current step
local forcedPlates = nil           -- previous nameplateShowEnemies value when we switched them on
local lastPrimary

local function cfg()
    ns.db.nav.skull = ns.db.nav.skull or { enabled = true, plates = true, others = true }
    return ns.db.nav.skull
end
MM.Cfg = cfg

-- ---- what the step wants -----------------------------------------------------------
local OBJECTIVE = { KILL = true, COLLECT = true, COMPLETE = true }

local function addName(set, name)
    if type(name) == "string" and name ~= "" then set[string.lower(name)] = name end   -- lower -> as written
end

-- the mobs behind one database objective (killed, credited, or dropping the item)
local function objectiveMobs(DB, d, set)
    if d.kind == "kill" or d.kind == "credit" then
        addName(set, d.name)
    elseif d.kind == "item" then
        local it = DB:GetItem(d.id)
        for _, npc in ipairs(it and it.npc or {}) do addName(set, DB:NPCName(npc)) end
    end
end

-- which database objective a live objective is (by wording), so a finished "Goretusk Snout 5/5"
-- takes the goretusks off the list even while the quest's other objectives are open
local function liveToDB(DB, questID, k, live)
    local o = live[k]
    local d = DB:MatchObjective(questID, k, o and o.text)
    if not d then return nil end
    -- strict: the database objective must be named in the live text. Forever rewrote some quests
    -- (Redridge Goulash: "Kill Dire Condor" where the old data has an item), and MatchObjective's
    -- last resort - same position - would hand back the wrong mobs
    local text = o and o.text and string.lower(o.text)
    local name = d.name and string.lower(d.name)
    if text and name and name ~= "" and string.find(text, name, 1, true) then return d end
    if text and d.kind == "item" then
        local it = DB:GetItem(d.id)
        if it and it.n and string.find(text, string.lower(it.n), 1, true) then return d end
    end
    return nil
end

-- The mob a kill objective's own wording names, whatever the format: Forever writes the count
-- first ("0/8 Murloc slain"), the old client after (": 0/8"), the tracker sometimes "(4)".
local KILL_VERBS = { "slain", "killed", "defeated" }
local function mobFromText(text)
    if type(text) ~= "string" then return nil end
    local t = text:gsub("^%s*%d+%s*/%s*%d+%s+", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", ""):gsub("%s*%(%d+%)%s*$", "")
    for _, verb in ipairs(KILL_VERBS) do
        local mob = t:match("^(.-)%s+" .. verb .. "$")
        if mob and mob ~= "" then return mob end
    end
    return nil
end
MM.MobFromText = mobFromText

--- lower-case names of the mobs the current step still needs ({} when it is not a kill/loot step)
function MM:WantedNames()
    local step = ns.Guide and ns.Guide:GetCurrentStep()
    local set = {}
    if not step or not OBJECTIVE[step.type] then return set, nil end
    if step.quest and ns.Quest:IsReadyForTurnIn(step.quest) then return set, nil end
    local DB = ns.DB
    if step.npc and DB then addName(set, DB:NPCName(step.npc)) end
    if step.type == "KILL" and step.target then
        for part in string.gmatch(step.target, "[^/]+") do addName(set, ns.Trim(part)) end
    end
    -- a COLLECT step names the creatures that drop its item when the quest database does not know them
    if step.mobs then
        for part in string.gmatch(step.mobs, "[^/]+") do addName(set, ns.Trim(part)) end
    end
    if step.quest and DB and DB:IsLoaded() then
        local objIdx = ns.Guide:StepObjectiveIndex(step)
        local live = ns.Quest:GetObjectives(step.quest) or {}
        if objIdx then
            local d = liveToDB(DB, step.quest, objIdx, live)
            if d and not (live[objIdx] and live[objIdx].finished) then objectiveMobs(DB, d, set) end
        elseif #live > 0 then
            -- no single objective identified: every objective that is still open
            for k, o in ipairs(live) do
                if not o.finished then
                    local d = liveToDB(DB, step.quest, k, live)
                    if d then objectiveMobs(DB, d, set) end
                end
            end
        else
            for _, d in ipairs(DB:QuestObjectives(step.quest) or {}) do objectiveMobs(DB, d, set) end
        end
    end
    return set, step
end

--- Names from open log objectives: kill names and item-drop mobs, respectively.
--- A quest ready to turn in has no open mobs, even if the client still calls them quest-related.
function MM:OpenKillNames()
    local set, loot = {}, {}
    local DB = ns.DB
    if not DB or not DB:IsLoaded() or not ns.Quest then return set, loot end
    for _, questID in ipairs(ns.Quest.order or {}) do
        local entry = ns.Quest:GetEntry(questID)
        if entry and not entry.ready then
            local live = entry.objectives
            for k, o in ipairs(live) do
                if not o.finished then
                    local d = liveToDB(DB, questID, k, live)
                    if d and (d.kind == "kill" or d.kind == "credit") then addName(set, d.name)
                    elseif d and d.kind == "item" then objectiveMobs(DB, d, loot) end
                    -- no database match: the wording itself may name the mob ("0/4 X slain")
                    if not d then addName(set, mobFromText(o.text)) end
                end
            end
        end
    end
    return set, loot
end

--- lower-case names of mobs whose objective is already complete for every quest in the log:
--- they may still count as "related to an active quest" for the client, but there is nothing to get
function MM:FinishedNames()
    local set = {}
    local DB = ns.DB
    if not DB or not DB:IsLoaded() or not ns.Quest then return set end
    for _, questID in ipairs(ns.Quest.order or {}) do
        local live = ns.Quest:GetObjectives(questID) or {}
        local open = {}
        for k, o in ipairs(live) do
            if o.finished then
                local d = liveToDB(DB, questID, k, live)
                if d then objectiveMobs(DB, d, set)
                else
                    addName(set, mobFromText(o.text))
                end
            end
        end
        -- a mob wanted by another, still open objective of the same quest stays
        for k, o in ipairs(live) do
            if not o.finished then
                local d = liveToDB(DB, questID, k, live)
                if d then objectiveMobs(DB, d, open) end
            end
        end
        for k in pairs(open) do set[k] = nil end
    end
    return set
end

--- Mob names proven to serve one live quest objective (including completed ones).
function MM:ObjectiveNames(questID, index, live)
    local set = {}
    local o = live and live[index]
    if not o then return set end
    local DB = ns.DB
    if DB and DB:IsLoaded() then
        local d = liveToDB(DB, questID, index, live)
        if d then objectiveMobs(DB, d, set) end
    end
    -- Forever-only quests may not have database entries. Only kill wording names a mob.
    if not next(set) then addName(set, mobFromText(o.text)) end
    return set
end

-- ---- nameplates -----------------------------------------------------------------------
local function plateUnit(plate)
    return plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
end

local function isMob(u)
    if ns.Plain(ns.Safe(UnitCanAttack, "player", u)) ~= true then return false end
    if ns.Plain(ns.Safe(UnitIsDead, u)) == true then return false end
    if ns.Plain(ns.Safe(UnitIsPlayer, u)) == true then return false end
    return true
end

local function tagged(u)
    return ns.Plain(ns.Safe(UnitIsTapDenied, u)) == true
end

-- ---- the mob's own tooltip ------------------------------------------------------------
-- The client builds a mob's mouseover tooltip from your quest log: a title line per quest, then
-- its objectives with `completed`, and in a group a player line before each member's own.
-- Read through C_TooltipInfo, it says per mob what the names cannot (a loot quest whose drops
-- nobody recorded, a quest the database lacks). Cached by GUID until the quest log changes;
-- a tooltip that cannot be read (secret in combat) keeps the last answer.
local LINE_FALLBACK = { QuestObjective = 8, QuestTitle = 17, QuestPlayer = 18 }
local function lineType(name)
    local E = rawget(_G, "Enum")
    local T = E and E.TooltipDataLineType
    return T and T[name] or LINE_FALLBACK[name]
end

local tipCache = {}       -- GUID -> { state, party }

--- "open" when the mob's tooltip lists an objective of yours not yet completed, "done" when it
--- lists only completed ones, false when it lists none, nil when it cannot be read; and whether
--- it lists a party member's objective not yet completed.
local function readTooltip(u)
    local data = ns.Call("C_TooltipInfo.GetUnit", u)
    if type(data) ~= "table" or ns.IsSecret(data) or type(data.lines) ~= "table" then return nil end
    local OBJ, TITLE, PLAYER = lineType("QuestObjective"), lineType("QuestTitle"), lineType("QuestPlayer")
    local me = ns.Player:GetName()
    local mine, any, open, party = true, false, false, false
    for _, line in ipairs(data.lines) do
        local t = ns.PlainNumber(line.type)
        if t == nil and ns.IsSecret(line.type) then return nil end
        if t == TITLE then
            mine = true
        elseif t == PLAYER then
            mine = ns.PlainString(line.leftText) == me     -- a group member's objectives follow
        elseif t == OBJ then
            local done = ns.Plain(line.completed)
            if done == nil and ns.IsSecret(line.completed) then return nil end
            if not mine then
                if done ~= true then party = true end
            else
                any = true
                if done ~= true then open = true end
            end
        end
    end
    if open then return "open", party end
    return any and "done" or false, party
end

--- The mob's tooltip state and whether a party member still needs it (see readTooltip).
function MM:TooltipQuest(u)
    local guid = ns.PlainString(ns.Safe(UnitGUID, u))
    local hit = guid and tipCache[guid]
    if hit then return hit[1], hit[2] end
    local state, party = readTooltip(u)
    if guid and state ~= nil then tipCache[guid] = { state, party } end
    return state, party
end

function MM:ForgetTooltips() tipCache = {} end

local MACRO_NAMES = 8         -- names in the target macro when it serves quests off the route

-- Closeness proxy. Nameplate frames are "restricted regions" on this client:
-- measuring them (GetCenter/GetScale) throws in combat, anchoring to them is
-- fine. So: measure when allowed (scale, then lower on screen = closer), else
-- fall back to the interact-distance rings (10 / 28 yd), else everything ties.
local function closeness(plate, u)
    local okS, s = pcall(plate.GetScale, plate)
    local okC, _, cy = pcall(plate.GetCenter, plate)
    if okS and okC and type(cy) == "number" then
        local ui = rawget(_G, "UIParent")
        local h = ui and ui:GetHeight() or 1000
        return (ns.PlainNumber(s) or 1) * 1000 - cy / h * 100
    end
    local CID = rawget(_G, "CheckInteractDistance")
    if CID then
        if ns.Plain(ns.Safe(CID, u, 3)) == true then return 300 end   -- within ~10 yd
        if ns.Plain(ns.Safe(CID, u, 4)) == true then return 200 end   -- within ~28 yd
    end
    return 100
end

-- ---- skull frames ---------------------------------------------------------------------
local function newSkull()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    pcall(f.tex.SetTexture, f.tex, SKULL_TEX)
    pcall(f.tex.SetTexCoord, f.tex, unpack(SKULL_COORDS))
    f.ring = f:CreateTexture(nil, "BACKGROUND")
    f.ring:SetPoint("CENTER")
    pcall(f.ring.SetTexture, f.ring, Theme.TEX.ring)
    pcall(f.ring.SetBlendMode, f.ring, "ADD")
    pcall(f.ring.SetVertexColor, f.ring, 1, 0.85, 0.4)
    f.label = Theme.NewText(f, { size = 9, justify = "CENTER", color = Theme.C.goldLight, oneLine = true, outline = "OUTLINE" })
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.label:SetWidth(160)
    f:Hide()
    return f
end

local function acquire()
    local f = table.remove(pool) or newSkull()
    used[#used + 1] = f
    return f
end

local function releaseAll()
    for _, f in ipairs(used) do
        f:Hide()
        f:ClearAllPoints()
        Theme.SetPulseEnabled(f.ring, false)
        pool[#pool + 1] = f
    end
    used = {}
end

local PARTY_TINT = { 0.45, 0.75, 1.00 }   -- a party member's mob: the skull in blue

local function dress(f, plate, primary, size, tint)
    f:ClearAllPoints()
    pcall(f.tex.SetVertexColor, f.tex, unpack(tint or { 1, 1, 1 }))
    f:SetSize(size, size)
    f:SetPoint("BOTTOM", plate, "TOP", 0, primary and 6 or 2)
    f.ring:SetSize(size * 1.9, size * 1.9)
    f.ring:SetShown(primary)
    if primary then
        Theme.Pulse(f.ring, 1.6, 0.35, 0.8)
        Theme.SetPulseEnabled(f.ring, cfg().animate ~= false)
        f.label:SetText("kill")
        f.label:Show()
    else
        Theme.SetPulseEnabled(f.ring, false)
        f.label:Hide()
    end
    pcall(f.SetAlpha, f, primary and 1 or 0.75)
    f:Show()
end

-- ---- enemy nameplates on/off -----------------------------------------------------------
local function getCVar(name)
    local C = rawget(_G, "C_CVar")
    local v = C and C.GetCVar and ns.Safe(C.GetCVar, name)
    if v == nil then v = ns.Safe(rawget(_G, "GetCVar"), name) end
    return ns.PlainString(v)
end
local function setCVar(name, value)
    local C = rawget(_G, "C_CVar")
    if C and C.SetCVar then return ns.Safe(C.SetCVar, name, value) end
    return ns.Safe(rawget(_G, "SetCVar"), name, value)
end

local function inCombat()
    return ns.Plain(ns.Safe(rawget(_G, "InCombatLockdown"))) == true
end

--- nameplateShowEnemies/nameplateShowFriends* are protected cvars: setting them from combat lockdown
--- is silently denied by the client (Ilya, 2026-09-24: "Interface action failed because of an AddOn" -
--- firing live, right as a kill step started mid-fight) and, since Scan() retries every 0.5s while a
--- kill step is current, it would keep retrying - and keep getting denied - for the whole fight. Skip
--- entirely while in combat; Scan() already re-runs on PLAYER_REGEN_ENABLED (below), which calls this
--- again once it is safe to actually change the cvars.
local function forcePlates(want)
    if not cfg().plates then return end
    if inCombat() then return end
    if want then
        -- Re-assert while held: the plates key, or a loading screen, can switch them off under us,
        -- and then every skull is gone until a reload clears forcedPlates (seen live, 2026-09-27).
        local now = getCVar("nameplateShowEnemies")
        if now ~= "1" then
            if forcedPlates == nil then forcedPlates = now or "0" end
            setCVar("nameplateShowEnemies", "1")
        end
    else
        if forcedPlates ~= nil then
            setCVar("nameplateShowEnemies", forcedPlates)
            forcedPlates = nil
        end
    end
end

-- ---- the secure "target the next quest mob" button ----------------------------------------
-- Addons may not change the player's target from Lua; a SecureActionButton with
-- a /targetexact macro may, when the PLAYER clicks it or presses its key. The
-- macro is rewritten out of combat only (secure attributes are locked in combat);
-- the names of a kill step do not change mid-fight, so it is right when it matters.
local targetBtn, macroNames, macroPending
function MM:TargetButton()
    if targetBtn then return targetBtn end
    local ok, b = pcall(CreateFrame, "Button", "ForeverGuideTargetButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    targetBtn = b
    pcall(b.SetAttribute, b, "type", "macro")
    pcall(b.RegisterForClicks, b, "AnyDown", "AnyUp")
    b:SetSize(1, 1)
    b:SetPoint("CENTER")
    return b
end

--- Point the button's macro at the current step's mobs, then the step's quest item when there is
--- one (deferred while in combat).
function MM:UpdateTargetMacro(names, itemID)
    local b = self:TargetButton()
    if not b then return end
    local list = {}
    for _, name in pairs(names or {}) do list[#list + 1] = name end
    table.sort(list)
    local key = table.concat(list, "|") .. "#" .. tostring(itemID)
    if key == macroNames then return end
    if inCombat() then macroPending = { names = names, item = itemID } return end
    -- /targetexact may land on a corpse. Each name is tried only while there is no target or it is
    -- dead, so a later name cannot replace a living one, and a corpse left at the end is dropped.
    local lines = {}
    if #list > 0 then
        lines[1] = "/cleartarget"
        for _, name in ipairs(list) do lines[#lines + 1] = "/targetexact [noexists][dead] " .. name end
        lines[#lines + 1] = "/cleartarget [dead]"
    end
    -- after the targeting, so an item used on a mob lands on the one just picked
    if itemID then lines[#lines + 1] = "/use item:" .. itemID end
    pcall(b.SetAttribute, b, "macrotext", table.concat(lines, "\n"))
    macroNames, macroPending = key, nil
    ns.Events:Fire("FG_TARGET_MACRO_CHANGED", list, itemID)
end

--- The names the target macro gets off the route: the mobs on screen, nearest first, then the
--- rest by name, at most MACRO_NAMES of them.
function MM:MacroNames(names, seen)
    local list = {}
    for lower in pairs(names) do list[#list + 1] = lower end
    table.sort(list, function(a, b)
        local sa, sb = seen[a], seen[b]
        if sa and sb then return sa > sb end
        if sa or sb then return sa ~= nil end
        return a < b
    end)
    local out = {}
    for i = 1, math.min(#list, MACRO_NAMES) do out[list[i]] = names[list[i]] end
    return out
end

function MM:TargetKey()
    local k = ns.PlainString(ns.Safe(rawget(_G, "GetBindingKey"), "CLICK ForeverGuideTargetButton:LeftButton"))
    return k
end

-- ---- the scan ---------------------------------------------------------------------------
function MM:Scan()
    releaseAll()
    local c = cfg()
    self.primaryUnit, self.markedCount, self.markedUnits = nil, 0, {}
    if c.enabled == false or (ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()) then forcePlates(false) return end
    local names, step = self:WantedNames()
    local finished = self:FinishedNames()
    local openKills, openLoot = self:OpenKillNames()
    local killStep = step ~= nil
    local current = ns.Guide and ns.Guide:GetCurrentStep()
    local stepItem = c.useItem ~= false and current and ns.Guide:StepUseItem(current) or nil
    -- the route wants no kill and has no item for the key: the quests in the log, on the route or
    -- not, get the big skull and the target key (a quest the player picked up on their own)
    local offRoute = next(names) == nil and stepItem == nil
    if offRoute then
        for lower, name in pairs(openKills) do names[lower] = name end
        for lower, name in pairs(openLoot) do names[lower] = name end
    end
    -- plates also while an off-guide kill or loot objective is open
    local anyKill = killStep or next(openKills) ~= nil or next(openLoot) ~= nil
    forcePlates(anyKill)
    if not offRoute then self:UpdateTargetMacro(names, stepItem) end
    local NP = rawget(_G, "C_NamePlate")
    if not NP or type(NP.GetNamePlates) ~= "function" then
        if offRoute then self:UpdateTargetMacro(self:MacroNames(names, {})) end
        return
    end
    local plates = ns.Safe(NP.GetNamePlates) or {}
    local best, bestScore, mine
    local others, partyPlates = {}, {}
    local targetGUID = ns.PlainString(ns.Safe(UnitGUID, "target"))
    local seen = {}               -- lower name -> best closeness of a living, untagged plate
    for _, plate in ipairs(plates) do
        local u = plateUnit(plate)
        if u and isMob(u) then
            local name = ns.PlainString(ns.Safe(UnitName, u))
            local lower = name and string.lower(name)
            local isWanted = lower and names[lower] ~= nil
            -- Only proven open objectives (or the current step) earn skulls; the client's
            -- quest-related flag stays true for quests already ready to turn in, so it is not used.
            -- The mob's tooltip is: an open objective there marks it, only completed ones unmark it.
            local open = lower and (openKills[lower] or openLoot[lower])
            local tip, partyOpen = self:TooltipQuest(u)
            if tip == "open" and offRoute then isWanted = true end
            local related = tip ~= "done" and (not lower or not finished[lower] or open or tip == "open")
                and (isWanted or open or tip == "open")
            -- a mob tagged by someone else is nobody's kill: no skull at all
            if related and not tagged(u) then
                local isTarget = targetGUID and ns.PlainString(ns.Safe(UnitGUID, u)) == targetGUID
                if isWanted then
                    local score = closeness(plate, u) + (isTarget and 5000 or 0)
                    if names[lower] and (not seen[lower] or score > seen[lower]) then seen[lower] = score end
                    if not bestScore or score > bestScore then
                        if best then others[#others + 1] = best end
                        best, bestScore = plate, score
                    else
                        others[#others + 1] = plate
                    end
                elseif c.others ~= false then
                    others[#others + 1] = plate
                end
            elseif c.party ~= false and partyOpen and not tagged(u) then
                partyPlates[#partyPlates + 1] = plate
            end
        end
    end
    if offRoute then self:UpdateTargetMacro(self:MacroNames(names, seen)) end
    if best then dress(acquire(), best, true, 30 * (c.size or 1)) end
    if c.others ~= false then
        for _, plate in ipairs(others) do dress(acquire(), plate, false, 18 * (c.size or 1)) end
    end
    for _, plate in ipairs(partyPlates) do dress(acquire(), plate, false, 18 * (c.size or 1), PARTY_TINT) end
    self.primaryUnit = best and plateUnit(best) or nil
    self.markedCount = #used
    self.markedUnits = {}
    if best then self.markedUnits[plateUnit(best)] = "primary" end
    if c.others ~= false then for _, plate in ipairs(others) do self.markedUnits[plateUnit(plate)] = "other" end end
    for _, plate in ipairs(partyPlates) do self.markedUnits[plateUnit(plate)] = "party" end
    -- the player's own target got taken by someone else: say so once (we cannot retarget for them)
    if killStep and targetGUID and not self.taggedWarned then
        local tName = ns.PlainString(ns.Safe(UnitName, "target"))
        local tl = tName and string.lower(tName)
        if tl and names[tl] and tagged("target") then
            self.taggedWarned = targetGUID
            ns.Debug("mob marker:", tName, "is tagged by someone else")
        end
    end
    if not targetGUID or self.taggedWarned ~= targetGUID then self.taggedWarned = nil end
    local guid = best and ns.PlainString(ns.Safe(UnitGUID, plateUnit(best)))
    if guid ~= lastPrimary then
        lastPrimary = guid
        ns.Events:Fire("FG_MOB_MARKED", guid, best and plateUnit(best))
    end
end

function MM:SetEnabled(on)
    cfg().enabled = on and true or false
    self:Scan()
end

function MM:OnInit()
    ns.Events:RegisterMany({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UNIT_FLAGS", "PLAYER_REGEN_ENABLED" },
        function() ns.Events:Debounce("mobmarker", 0.1, function() MM:Scan() end) end)
    ns.Events:Register("PLAYER_REGEN_ENABLED", function() if macroPending then MM:UpdateTargetMacro(macroPending.names, macroPending.item) end end)
    ns.Events:RegisterMany({ "FG_QUEST_LOG_CHANGED", "FG_OBJECTIVE_PROGRESS" }, function() tipCache = {} end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED", "FG_QUEST_LOG_CHANGED", "FG_HIDDEN_ALL_CHANGED", "BAG_UPDATE_DELAYED" },
        function() ns.Events:Debounce("mobmarker", 0.1, function() MM:Scan() end) end)
end

function MM:OnEnable()
    self:TargetButton()
    -- a slow ticker catches tap changes and deaths the events miss
    local t = CreateFrame("Frame")
    t.elapsed = 0
    t:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        local ok, err = pcall(MM.Scan, MM)
        if not ok then ns.ReportOnce("mobmarker:scan", err) end
    end)
    self:Scan()
end

function MM:OnLogout()
    forcePlates(false)
end
