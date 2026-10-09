--------------------------------------------------------------------------------
-- LiveLog.lua - who plays, where they are and what they do, for the ForeverGuide Companion
--
-- An addon cannot send anything out of the game or write a file, and the game writes saved variables
-- only on /reload, logout or exit. But the game writes its own chat log (Logs\WoWChatLog.txt,
-- /chatlog) as the player plays. So, while the player records a run (the Record button) or opts in
-- ("Share live position with the Companion", off by default), this switches that log on and prints
-- short machine lines into a chat window of its own that is never shown; the Companion reads its
-- lines from the log as it grows, the way Warcraft Logs reads the combat log, and sends them to codex,
-- where admins watch the player move on the map and play their recordings back. No screen is read.
--
-- The lines (forever-codex docs/LIVE-LOG.md, checked against its vectors in
-- tools/test/fixtures/live-log-vectors.json), each "FGLOG1 <kind> <t> ...", t the game's clock in ms:
--   W  who plays: recording id (the run id's first 8 hex digits, 0 with no run), class, flags, Name-Realm
--   P  where: uiMapID, x, y, facing (0-255), flags; every second while moving, every 10 s standing still
--   E  what they did: kind, value, objective, have, need, source, source id; each at once
--------------------------------------------------------------------------------
local _, ns = ...
local LiveLog = ns:NewModule("LiveLog")

local PREFIX = "FGLOG1"
local EVERY = 1                   -- seconds between position checks
local STILL = 10                  -- seconds between positions while nothing changes
local WHO_EVERY = 30              -- seconds between who lines
local WINDOW_NAME = "FG Log"      -- the chat window the lines go to, never shown
local KILL_WITHIN, LOOT_WITHIN = 2, 5      -- seconds a kill or a loot window still explains a count going up
local XP_WITHIN = 2                       -- seconds a kill, turn-in or discovery still explains experience
LiveLog.FLAG = { mounted = 1, taxi = 2, dead = 4, noPosition = 8, paused = 16, recording = 32 }
LiveLog.EVENT = { none = 0, accept = 1, turnIn = 2, progress = 3, level = 4, death = 5, abandon = 6, xp = 7 }
LiveLog.SOURCE = { other = 0, kill = 1, mobLoot = 2, object = 3, quest = 4, explore = 5 }
LiveLog.TARGETS = { window = true, combat = true, main = true }

-- ---- the lines: pure functions, the contract ------------------------------------------------
local function coordinate(n) return string.format("%.2f", math.floor(n * 100 + 0.5) / 100) end

-- WoW's string.format takes only 32-bit integers for %d ("integer overflow attempting to store"):
-- the clock, in ms since the epoch, is far past that, so it is written as a whole number with %.0f.
local function whole(n) return string.format("%.0f", math.floor(n)) end

--- A line's text. line = { kind = "W"|"P"|"E", t, ... } with the fields docs/LIVE-LOG.md names.
function LiveLog.LineOf(line)
    if line.kind == "W" then
        return string.format("%s W %s %s %d %d %s", PREFIX, whole(line.t), line.recording, line.classId, line.flags, line.character)
    elseif line.kind == "P" then
        return string.format("%s P %s %d %s %s %d %d", PREFIX, whole(line.t), line.map, coordinate(line.x), coordinate(line.y),
            line.facing, line.flags)
    end
    return string.format("%s E %s %d %d %d %d %d %d %d", PREFIX, whole(line.t), line.eventKind, line.value, line.objective,
        line.have, line.need, line.source, line.sourceId)
end

--- The recording id a run id names: its first 8 hex digits, lower case; "0" for none.
function LiveLog.RecordingOf(runId)
    local hex = type(runId) == "string" and runId:match("^(%x%x%x%x%x%x%x%x)")
    return hex and hex:lower() or "0"
end

-- ---- the game's clock, in ms since the epoch ------------------------------------------------
-- time() counts whole seconds; GetTime() counts finely from an unknown start. Their difference, taken
-- once, gives a clock that is fine and never goes back.
local epochOffset
local function Now()
    local fine = (tonumber(ns.Plain(ns.Safe(rawget(_G, "GetTime")))) or 0) * 1000
    if not epochOffset then epochOffset = (tonumber(ns.Plain(ns.Safe(rawget(_G, "time")))) or 0) * 1000 - fine end
    return math.floor(epochOffset + fine)
end
LiveLog.Now = Now

-- ---- writing: the chat log on, and a window of our own -----------------------------------------
local window, weTurnedLoggingOn
local written = {}                 -- the last lines written, for tests and /fg live

--- The chat window the lines go to: our own, closed so it is never shown; the combat log's, or the
--- main one, when the player chose so (/fg live target) or ours cannot be opened.
local function Window()
    local target = ns.db and ns.db.liveLogTarget or "window"
    if target == "main" then return rawget(_G, "DEFAULT_CHAT_FRAME") end
    if target == "combat" then return rawget(_G, "ChatFrame2") or rawget(_G, "DEFAULT_CHAT_FRAME") end
    if window then return window end
    local count = tonumber(rawget(_G, "NUM_CHAT_WINDOWS")) or 10
    for i = 1, count do
        local name = ns.PlainString(ns.Safe(rawget(_G, "GetChatWindowInfo"), i))
        if name == WINDOW_NAME then window = rawget(_G, "ChatFrame" .. i) end
    end
    local open, close = rawget(_G, "FCF_OpenNewWindow"), rawget(_G, "FCF_Close")
    if not window and open then
        local ok, made = pcall(open, WINDOW_NAME, true)
        if ok and made then
            window = made
            if close then pcall(close, made) end
        end
    end
    return window or rawget(_G, "ChatFrame2") or rawget(_G, "DEFAULT_CHAT_FRAME")
end

--- Write one line.
function LiveLog:Write(line)
    local text = LiveLog.LineOf(line)
    written[#written + 1] = text
    if #written > 50 then table.remove(written, 1) end
    local frame = Window()
    if frame and frame.AddMessage then frame:AddMessage(text) end
end

--- The last lines written, newest last.
function LiveLog:Written() return written end

--- The chat log on, while lines are written; off again only if it was off before.
local function KeepLogging(on)
    local logging = rawget(_G, "LoggingChat")
    if not logging then return end
    local isOn = ns.Plain(ns.Safe(logging)) == true
    if on and not isOn then
        pcall(logging, true)
        weTurnedLoggingOn = true
    elseif not on and weTurnedLoggingOn then
        pcall(logging, false)
        weTurnedLoggingOn = false
    end
end

-- ---- what happened: written at once -------------------------------------------------------------
--- Write an event (only while writing: one before that is not written later).
--- detail, for progress and experience: { objective, have, need, source, sourceId }.
function LiveLog:Push(kind, value, detail)
    if not self:Writing() then return end
    detail = detail or {}
    self:Write({ kind = "E", t = Now(), eventKind = kind, value = value or 0, objective = detail.objective or 0,
        have = detail.have or 0, need = detail.need or 0, source = detail.source or 0, sourceId = detail.sourceId or 0 })
end

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
function LiveLog:NoteKill(npc)
    lastKill = { npc = npc, at = ns.Now() }
end

--- A loot window opened: what it is from, by its first slot's source; failing that, the creature
--- just killed, or else an object.
function LiveLog:NoteLoot()
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
function LiveLog:NoteXP()
    xpWas, xpMaxWas = ns.Player:GetXP()
end

--- How much experience came since last time. Across a level the bar starts again: the rest of the
--- old level and the new. A level-up is told by the bar going back, not by the level, which the game
--- can report a moment after the experience.
function LiveLog:XPGained()
    local xp, max = ns.Player:GetXP()
    local gained = 0
    if xpWas then
        if xp < xpWas then gained = (xpMaxWas or 0) - xpWas + xp else gained = xp - xpWas end
    end
    xpWas, xpMaxWas = xp, max
    return math.max(0, gained)
end

--- Where experience gained now came from: a quest just turned in, an area just discovered, a kill.
function LiveLog:XPSourceNow()
    local S, now = LiveLog.SOURCE, ns.Now()
    local function recent(note) return note and now - note.at <= XP_WITHIN end
    if recent(lastTurnIn) then return S.quest, lastTurnIn.quest end
    if recent(lastExplore) then return S.explore, 0 end
    if recent(lastPartyKill) then return S.kill, lastPartyKill.npc end
    return S.other, 0
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
function LiveLog:SourceNow()
    local S, now = LiveLog.SOURCE, ns.Now()
    if lastLoot and now - lastLoot.at <= LOOT_WITHIN then
        return lastLoot.kind == "npc" and S.mobLoot or S.object, lastLoot.id
    end
    if lastKill and now - lastKill.at <= KILL_WITHIN then return S.kill, lastKill.npc end
    return S.other, 0
end

-- ---- reading the player ---------------------------------------------------------------------
--- The flags as they stand: mounted, on a flight, dead, no position, and the run recording or paused.
local function Flags(x, y)
    local F, flags, Plain = LiveLog.FLAG, 0, ns.Plain
    if Plain(ns.Safe(rawget(_G, "IsMounted"))) == true then flags = flags + F.mounted end
    if Plain(ns.Safe(rawget(_G, "UnitOnTaxi"), "player")) == true then flags = flags + F.taxi end
    if Plain(ns.Safe(rawget(_G, "UnitIsDeadOrGhost"), "player")) == true then flags = flags + F.dead end
    if not x or not y then flags = flags + F.noPosition end
    if ns.char and ns.char.run then
        flags = flags + (ns.Run:State() == "recording" and F.recording or F.paused)
    end
    return flags
end

--- Who plays, now.
function LiveLog:Who()
    local run = ns.char and ns.char.run
    local name = ns.Player:GetName() .. "-" .. ns.Player:GetRealm()
    return { kind = "W", t = Now(), recording = LiveLog.RecordingOf(run and run.id), flags = Flags(true, true),
        classId = tonumber(ns.Plain(select(3, ns.Safe(UnitClass, "player")))) or 0, character = name }
end

--- Where the player is, now.
function LiveLog:Place()
    local map, x, y = ns.Player:GetMapPosition()
    local facing = ns.Player:GetFacing()
    return { kind = "P", t = Now(), map = map or 0, x = x or 0, y = y or 0, flags = Flags(x, y),
        facing = facing and (math.floor(facing / (2 * math.pi) * 256 + 0.5) % 256) or 0 }
end

--- Write who plays.
function LiveLog:WriteWho()
    if self:Writing() then self:Write(self:Who()) end
end

local ticker, lastPlace, placeAt, whoAt

local function Tick()
    local now = ns.Now()
    if not whoAt or now - whoAt >= WHO_EVERY then
        whoAt = now
        LiveLog:Write(LiveLog:Who())
    end
    local place = LiveLog:Place()
    local key = string.format("%d %s %s %d %d", place.map, coordinate(place.x), coordinate(place.y), place.facing, place.flags)
    if key ~= lastPlace or not placeAt or now - placeAt >= STILL then
        lastPlace, placeAt = key, now
        LiveLog:Write(place)
    end
end

function LiveLog:Enabled() return ns.db and ns.db.liveBeacon == true end

--- Whether lines are written: the setting is on, or a run is recording.
function LiveLog:Writing()
    return self:Enabled() or (ns.Run ~= nil and ns.Run:State() == "recording")
end

--- Write, or stop writing, as the setting and the run say.
function LiveLog:Apply()
    if self:Writing() then
        KeepLogging(true)
        if not ticker then
            ticker = CreateFrame("Frame")
            local since = EVERY
            ticker:SetScript("OnUpdate", function(_, elapsed)
                since = since + (elapsed or 0)
                if since < EVERY then return end
                since = 0
                local ok, err = pcall(Tick)
                if not ok then ns.ReportOnce("livelog", err) end
            end)
        end
        ticker:Show()
    else
        if ticker then ticker:Hide() end
        lastPlace, placeAt, whoAt = nil, nil, nil
        KeepLogging(false)
    end
end

--- Entering the world: write when the setting is on or a run records.
function LiveLog:OnEnable()
    self:NoteXP()
    self:Apply()
end

--- The setting switched on or off (Options, /fg live).
function LiveLog:SetEnabled(on)
    ns.db.liveBeacon = on and true or false
    self:Apply()
end

--- Where the lines go: "window" (ours, never shown), "combat" (the combat log's) or "main".
function LiveLog:SetTarget(target)
    if not LiveLog.TARGETS[target] then return false end
    ns.db.liveLogTarget = target
    window = nil
    return true
end

function LiveLog:OnInit()
    local E, EV, PlainNumber = ns.Events, LiveLog.EVENT, ns.PlainNumber
    E:Register("FG_RUN_CHANGED", function()
        LiveLog:Apply()
        LiveLog:WriteWho()
    end)
    E:Register("FG_QUEST_ACCEPTED", function(_, q) LiveLog:Push(EV.accept, PlainNumber(q)) end)
    E:Register("FG_QUEST_TURNED_IN", function(_, q) LiveLog:Push(EV.turnIn, PlainNumber(q)) end)
    E:Register("FG_QUEST_ABANDONED", function(_, q) LiveLog:Push(EV.abandon, PlainNumber(q)) end)
    -- every count going up, with what made it: the record of what the player did
    E:Register("FG_OBJECTIVE_PROGRESS", function(_, q, idx, have, need)
        local source, sourceId = LiveLog:SourceNow()
        LiveLog:Push(EV.progress, PlainNumber(q), {
            objective = PlainNumber(idx), have = math.min(255, PlainNumber(have) or 0),
            need = math.min(255, PlainNumber(need) or 0), source = source, sourceId = sourceId,
        })
    end)
    E:Register("PARTY_KILL", function(_, attacker, target)
        local kind, id = Source(target)
        if kind ~= "npc" then return end
        -- any kill of the group gives experience; only the player's own counts toward a kill objective
        lastPartyKill = { npc = id, at = ns.Now() }
        local me = ns.PlainString(ns.Safe(rawget(_G, "UnitGUID"), "player"))
        if me ~= nil and ns.PlainString(attacker) == me then LiveLog:NoteKill(id) end
    end)
    E:Register("FG_QUEST_TURNED_IN", function(_, q) lastTurnIn = { quest = PlainNumber(q) or 0, at = ns.Now() } end)
    local explored = ExploredPattern()
    E:Register("CHAT_MSG_COMBAT_XP_GAIN", function(_, text)
        text = ns.PlainString(text)
        if text and text:find(explored) then lastExplore = { at = ns.Now() } end
    end)
    E:Register("PLAYER_XP_UPDATE", function(_, unit)
        if unit ~= nil and ns.PlainString(unit) ~= "player" then return end
        local gained = LiveLog:XPGained()
        if gained <= 0 then return end
        local source, sourceId = LiveLog:XPSourceNow()
        LiveLog:Push(EV.xp, math.min(0xFFFFFF, gained), { source = source, sourceId = sourceId })
    end)
    E:Register("LOOT_OPENED", function() LiveLog:NoteLoot() end)
    E:Register("FG_LEVEL_CHANGED", function(_, level) LiveLog:Push(EV.level, PlainNumber(level)) end)
    E:Register("PLAYER_DEAD", function() LiveLog:Push(EV.death, 0) end)
end
