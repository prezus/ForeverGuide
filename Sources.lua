--------------------------------------------------------------------------------
-- Sources.lua - where things came from, for the run log (Run.lua)
--
-- The game says that an objective's count went up, or how much experience the player has, but not
-- why. This works it out from what it saw just before: an objective's count going up just after the
-- player killed a creature is that kill; just after a loot window opened, that loot (from a creature
-- or an object on the ground, by GetLootSourceInfo); and experience is put down to the quest just
-- turned in, the area just discovered, or the creature the group just killed. Sources are named as
-- codex names them: kill, mobLoot, object, quest, explore, other.
--------------------------------------------------------------------------------
local _, ns = ...
local Sources = ns:NewModule("Sources")

local KILL_WITHIN, LOOT_WITHIN = 2, 5      -- seconds a kill or a loot window still explains a count going up
local XP_WITHIN = 2                       -- seconds a kill, turn-in or discovery still explains experience

-- ---- what made an objective's count go up ------------------------------------------------------
-- The last creature the player killed, and the last loot window's source: a count that goes up just
-- after one of them is put down to it. Anything else (talking, using an item) is "other".
local lastKill, lastLoot

--- A GUID's kind and id: a creature ("npc") or an object; nil for anything else.
local function Source(guid)
    local id, unitType = ns.Player:NpcIDFromGUID(guid)
    if not id then return nil end
    if unitType == "GameObject" then return "object", id end
    if unitType == "Creature" or unitType == "Vehicle" then return "npc", id end
    return nil
end

--- The player killed a creature.
function Sources:NoteKill(npc)
    lastKill = { npc = npc, at = ns.Now() }
end

--- A loot window opened: what it is from, by its first slot's source; failing that, the creature
--- just killed, or else an object.
function Sources:NoteLoot()
    local sourceOf = rawget(_G, "GetLootSourceInfo")
    local kind, id
    if sourceOf then kind, id = Source(ns.Safe(sourceOf, 1)) end
    if not kind and lastKill and ns.Now() - lastKill.at <= 30 then kind, id = "npc", lastKill.npc end
    lastLoot = { kind = kind or "object", id = id or 0, at = ns.Now() }
end

-- ---- where experience came from ----------------------------------------------------------------
-- The game says only how much experience the player has: a gain is the difference, put down to the
-- quest just turned in, the area just discovered, or the creature the group just killed.
local xpWas, xpMaxWas, lastTurnIn, lastExplore, lastPartyKill

--- The player's experience as it stands, to measure the next gain from.
function Sources:NoteXP()
    xpWas, xpMaxWas = ns.Player:GetXP()
end

--- How much experience came since last time. Across a level the bar starts again: the rest of the
--- old level and the new. A level-up is told by the bar going back, not by the level, which the game
--- can report a moment after the experience.
function Sources:XPGained()
    local xp, max = ns.Player:GetXP()
    local gained = 0
    if xpWas then
        if xp < xpWas then gained = (xpMaxWas or 0) - xpWas + xp else gained = xp - xpWas end
    end
    xpWas, xpMaxWas = xp, max
    return math.max(0, gained)
end

--- Where experience gained now came from: a quest just turned in, an area just discovered, a kill.
function Sources:XPSourceNow()
    local now = ns.Now()
    local function recent(note) return note and now - note.at <= XP_WITHIN end
    if recent(lastTurnIn) then return "quest", lastTurnIn.quest end
    if recent(lastExplore) then return "explore", 0 end
    if recent(lastPartyKill) then return "kill", lastPartyKill.npc end
    return "other", 0
end

-- the game's "Discovered %s: %d experience gained", as a pattern
local function ExploredPattern()
    local format = rawget(_G, "ERR_ZONE_EXPLORED_XP")
    if type(format) ~= "string" then format = "Discovered %s: %d experience gained" end
    -- the placeholders set aside, everything else literal, then the placeholders as patterns
    local marked = format:gsub("%%s", "\1"):gsub("%%d", "\2")
    local literal = marked:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    return "^" .. (literal:gsub("\1", ".+"):gsub("\2", "%%d+"))
end

--- What made a count go up now: a loot window just opened, else a kill just made, else something else.
function Sources:SourceNow()
    local now = ns.Now()
    if lastLoot and now - lastLoot.at <= LOOT_WITHIN then
        return lastLoot.kind == "npc" and "mobLoot" or "object", lastLoot.id
    end
    if lastKill and now - lastKill.at <= KILL_WITHIN then return "kill", lastKill.npc end
    return "other", 0
end

function Sources:OnInit()
    local E, PlainNumber = ns.Events, ns.PlainNumber
    E:Register("PARTY_KILL", function(_, attacker, target)
        local kind, id = Source(target)
        if kind ~= "npc" then return end
        -- any kill of the group gives experience; only the player's own counts toward a kill objective
        lastPartyKill = { npc = id, at = ns.Now() }
        local me = ns.PlainString(ns.Safe(rawget(_G, "UnitGUID"), "player"))
        if me ~= nil and ns.PlainString(attacker) == me then Sources:NoteKill(id) end
    end)
    E:Register("FG_QUEST_TURNED_IN", function(_, q) lastTurnIn = { quest = PlainNumber(q) or 0, at = ns.Now() } end)
    local explored = ExploredPattern()
    E:Register("CHAT_MSG_COMBAT_XP_GAIN", function(_, text)
        text = ns.PlainString(text)
        if text and text:find(explored) then lastExplore = { at = ns.Now() } end
    end)
    E:Register("LOOT_OPENED", function() Sources:NoteLoot() end)
end

--- Entering the world: the experience to measure the next gain from.
function Sources:OnEnable() self:NoteXP() end
