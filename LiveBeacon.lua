--------------------------------------------------------------------------------
-- LiveBeacon.lua - the player's position, drawn for the ForeverGuide Companion
--
-- An addon cannot send anything out of the game while it runs, and the game writes saved variables
-- only on /reload, logout or exit. So, while the player records a run (the Record button) or opts in
-- ("Share live position with the Companion", off by default), this draws the position as a strip of
-- 23 colored cells, 3x3 physical pixels each, in the window's top-left corner, redrawn every 0.1 s.
-- Each frame also carries the latest thing the player did in the game, guide or not: a quest picked
-- up, turned in or abandoned; an objective's count going up, with what made it (a kill, loot from a
-- creature, an object on the ground) and that creature's or object's id; every bit of experience and
-- where it came from (a kill, a quest turned in, exploring); a level; a death. It carries the
-- character's Name-Realm, a byte a frame, so the live view shows only the character played now, and
-- while the character has a run, the run's id, so the Companion files the recording under them. The
-- Companion captures that strip and nothing else, and sends it to codex, where admins watch the player
-- move on the map and play their recordings back.
-- The contract (frame, cells, checksum) is forever-codex's docs/LIVE-BEACON.md; the encoder is
-- checked against its test vectors (tools/test/fixtures/live-beacon-vectors.json).
--
-- Passive: it reads what the addon already reads (Player.lua, the run, the quest log's events) and
-- draws; nothing else.
--------------------------------------------------------------------------------
local _, ns = ...
local LiveBeacon = ns:NewModule("LiveBeacon")

local MAGIC = 0xFC                -- version 2
local CELLS, CELL_PX = 23, 3
local EVERY = 0.1                 -- seconds between frames
local HOLD = 3                    -- frames each event stays drawn, so a capture at 10 a second sees it
local NAME_MAX = 62               -- bytes of Name-Realm the name channel carries
LiveBeacon.FLAG = { mounted = 1, taxi = 2, dead = 4, noPosition = 8, paused = 16, recording = 32 }
LiveBeacon.EVENT = { none = 0, accept = 1, turnIn = 2, progress = 3, level = 4, death = 5, abandon = 6, xp = 7 }
LiveBeacon.SOURCE = { other = 0, kill = 1, mobLoot = 2, object = 3, quest = 4, explore = 5 }
local XP_WITHIN = 2                       -- seconds a kill, turn-in or discovery still explains experience
local KILL_WITHIN, LOOT_WITHIN = 2, 5      -- seconds a kill or a loot window still explains a count going up

-- ---- the frame: pure functions, the contract ------------------------------------------------
-- Lua 5.1 has no bit operators, and WoW's `bit` is not in the headless tests: bytes are XORed by arithmetic.
local function xor8(a, b)
    local r, p = 0, 1
    for _ = 1, 8 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
end

--- CRC-8, polynomial 0x07, initial 0.
function LiveBeacon.Crc8(bytes)
    local crc = 0
    for _, byte in ipairs(bytes) do
        crc = xor8(crc, byte)
        for _ = 1, 8 do
            if crc >= 0x80 then crc = xor8((crc * 2) % 256, 0x07) else crc = (crc * 2) % 256 end
        end
    end
    return crc
end

local function coordinate(percent)
    local v = math.floor(percent * 655.35 + 0.5)
    if v < 0 then return 0 elseif v > 0xFFFF then return 0xFFFF end
    return v
end

-- byte n of a number, counting from the lowest (0)
local function byte(value, n) return math.floor(value / 256 ^ n) % 256 end

--- A frame's 31 bytes, the checksum last. frame = { seq, map, x, y, facing, classId, flags,
--- eventSeq, eventKind, eventValue, eventObjective, eventHave, eventNeed, source, sourceId,
--- recording, nameIndex, nameByte }.
function LiveBeacon.Bytes(frame)
    local x, y = coordinate(frame.x), coordinate(frame.y)
    local v, r, si = frame.eventValue or 0, frame.recording or 0, frame.sourceId or 0
    local body = {
        MAGIC,
        byte(frame.seq, 1), byte(frame.seq, 0),
        byte(frame.map, 1), byte(frame.map, 0),
        byte(x, 1), byte(x, 0),
        byte(y, 1), byte(y, 0),
        frame.facing, frame.classId, frame.flags,
        frame.eventSeq or 0, frame.eventKind or 0, byte(v, 2), byte(v, 1), byte(v, 0),
        frame.eventObjective or 0, frame.eventHave or 0, frame.eventNeed or 0,
        frame.source or 0, byte(si, 2), byte(si, 1), byte(si, 0),
        byte(r, 3), byte(r, 2), byte(r, 1), byte(r, 0),
        frame.nameIndex or 0, frame.nameByte or 0,
    }
    body[31] = LiveBeacon.Crc8(body)
    return body
end

--- The strip's colors for a frame, 0-255 a channel: black, 21 data cells (the last nibble padding), white.
function LiveBeacon.Cells(frame)
    local bytes, nibbles = LiveBeacon.Bytes(frame), {}
    for _, b in ipairs(bytes) do
        nibbles[#nibbles + 1] = math.floor(b / 16)
        nibbles[#nibbles + 1] = b % 16
    end
    nibbles[#nibbles + 1] = 0             -- 62 nibbles of frame, one of padding
    local cells = { { 0, 0, 0 } }
    for i = 0, CELLS - 3 do
        cells[#cells + 1] = { nibbles[i * 3 + 1] * 16 + 8, nibbles[i * 3 + 2] * 16 + 8, nibbles[i * 3 + 3] * 16 + 8 }
    end
    cells[#cells + 1] = { 255, 255, 255 }
    return cells
end

--- The name channel's bytes for a character: the length, then Name-Realm's bytes (at most NAME_MAX).
function LiveBeacon.NameChannel(name)
    name = name:sub(1, NAME_MAX)
    local bytes = { #name }
    for i = 1, #name do bytes[#bytes + 1] = name:byte(i) end
    return bytes
end

--- The recording id a run id draws: its first 8 hex digits as a number; 0 for none.
function LiveBeacon.RecordingOf(runId)
    local hex = type(runId) == "string" and runId:match("^(%x%x%x%x%x%x%x%x)")
    return hex and tonumber(hex, 16) or 0
end

-- ---- what happened: events, each held for a few frames ---------------------------------------
local queue, current, held, eventSeq = {}, { kind = 0, value = 0 }, HOLD, 0

--- Queue an event to draw (only while the strip draws: one switched on later starts from now).
--- detail, for progress: { objective, have, need, source, sourceId }.
function LiveBeacon:Push(kind, value, detail)
    if not self:Drawing() or #queue >= 32 then return end
    detail = detail or {}
    queue[#queue + 1] = {
        kind = kind, value = value or 0, objective = detail.objective or 0, have = detail.have or 0,
        need = detail.need or 0, source = detail.source or 0, sourceId = detail.sourceId or 0,
    }
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
function LiveBeacon:NoteKill(npc)
    lastKill = { npc = npc, at = ns.Now() }
end

--- A loot window opened: what it is from, by its first slot's source; failing that, the creature
--- just killed, or else an object.
function LiveBeacon:NoteLoot()
    local sourceOf = rawget(_G, "GetLootSourceInfo")
    local kind, id
    if sourceOf then kind, id = Source(ns.Safe(sourceOf, 1)) end
    if not kind and lastKill and ns.Now() - lastKill.at <= 30 then kind, id = "npc", lastKill.npc end
    lastLoot = { kind = kind or "object", id = id or 0, at = ns.Now() }
end

-- ---- where experience came from ----------------------------------------------------------------
-- The game says only how much experience the player has: a gain is the difference, put down to the
-- quest just turned in, the area just discovered, or the creature the group just killed.
local xpWas, xpMaxWas, levelWas, lastTurnIn, lastExplore, lastPartyKill

--- The player's experience as it stands, to measure the next gain from.
function LiveBeacon:NoteXP()
    xpWas, xpMaxWas = ns.Player:GetXP()
    levelWas = ns.Player:GetLevel()
end

--- How much experience came since last time: across a level, the rest of the old level and the new.
function LiveBeacon:XPGained()
    local xp, max = ns.Player:GetXP()
    local level = ns.Player:GetLevel()
    local gained = 0
    if xpWas and levelWas then
        if level and level > levelWas then gained = (xpMaxWas or 0) - xpWas + xp else gained = xp - xpWas end
    end
    xpWas, xpMaxWas, levelWas = xp, max, level
    return math.max(0, gained)
end

--- Where experience gained now came from: a quest just turned in, an area just discovered, a kill.
function LiveBeacon:XPSourceNow()
    local S, now = LiveBeacon.SOURCE, ns.Now()
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
function LiveBeacon:SourceNow()
    local S, now = LiveBeacon.SOURCE, ns.Now()
    if lastLoot and now - lastLoot.at <= LOOT_WITHIN then
        return lastLoot.kind == "npc" and S.mobLoot or S.object, lastLoot.id
    end
    if lastKill and now - lastKill.at <= KILL_WITHIN then return S.kill, lastKill.npc end
    return S.other, 0
end

-- the event the next frame carries: the current one until it has been drawn HOLD times, then the next
local function NextEvent()
    held = held + 1
    if held >= HOLD and #queue > 0 then
        current = table.remove(queue, 1)
        eventSeq, held = (eventSeq + 1) % 256, 0
    end
    return current
end

-- ---- reading the player ---------------------------------------------------------------------
local seq, nameStep, nameBytes, nameOf = 0, 0, nil, nil

-- the name channel's bytes for the character playing, read once a session
local function Name()
    if not nameBytes then
        nameOf = ns.Player:GetName() .. "-" .. ns.Player:GetRealm()
        nameBytes = LiveBeacon.NameChannel(nameOf)
    end
    return nameBytes
end

--- The frame for where the player is now.
function LiveBeacon:Frame()
    local P, Plain = ns.Player, ns.Plain
    local map, x, y = P:GetMapPosition()
    local facing = P:GetFacing()
    local classId = tonumber(Plain(select(3, ns.Safe(UnitClass, "player")))) or 0
    local F, flags = LiveBeacon.FLAG, 0
    if Plain(ns.Safe(rawget(_G, "IsMounted"))) == true then flags = flags + F.mounted end
    if Plain(ns.Safe(rawget(_G, "UnitOnTaxi"), "player")) == true then flags = flags + F.taxi end
    if Plain(ns.Safe(rawget(_G, "UnitIsDeadOrGhost"), "player")) == true then flags = flags + F.dead end
    if not x or not y then flags, x, y = flags + F.noPosition, 0, 0 end
    -- the character's name, always, so the live view shows only the character played now; and a
    -- run's id, the flag saying whether it records now
    local run = ns.char and ns.char.run
    local recording = 0
    if run then
        recording = LiveBeacon.RecordingOf(run.id)
        if ns.Run:State() == "recording" then flags = flags + F.recording else flags = flags + F.paused end
    end
    local bytes = Name()
    local nameIndex = nameStep % #bytes
    local nameByte = bytes[nameIndex + 1]
    nameStep = nameStep + 1
    seq = (seq + 1) % 65536
    local event = NextEvent()
    return {
        seq = seq, map = map or 0, x = x, y = y,
        facing = facing and (math.floor(facing / (2 * math.pi) * 256 + 0.5) % 256) or 0,
        classId = classId, flags = flags,
        eventSeq = eventSeq, eventKind = event.kind, eventValue = event.value,
        eventObjective = event.objective or 0, eventHave = event.have or 0, eventNeed = event.need or 0,
        source = event.source or 0, sourceId = event.sourceId or 0,
        recording = recording, nameIndex = nameIndex, nameByte = nameByte,
    }
end

-- ---- drawing ----------------------------------------------------------------------------------
local strip, textures

--- One UI unit to one physical pixel: the strip is the same size at any UI scale or resolution.
local function PixelScale()
    local _, height = ns.Safe(rawget(_G, "GetPhysicalScreenSize"))
    height = tonumber(ns.Plain(height))
    return (height and height > 0) and (768 / height) or 1
end

local function Draw()
    local cells = LiveBeacon.Cells(LiveBeacon:Frame())
    for i, c in ipairs(cells) do textures[i]:SetColorTexture(c[1] / 255, c[2] / 255, c[3] / 255, 1) end
end

local function Build()
    strip = CreateFrame("Frame", nil, UIParent)
    if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
    strip:SetScale(PixelScale())
    strip:SetFrameStrata("TOOLTIP")
    strip:SetSize(CELLS * CELL_PX, CELL_PX)
    strip:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    textures = {}
    for i = 1, CELLS do
        local t = strip:CreateTexture(nil, "OVERLAY")
        t:SetSize(CELL_PX, CELL_PX)
        t:SetPoint("TOPLEFT", strip, "TOPLEFT", (i - 1) * CELL_PX, 0)
        textures[i] = t
    end
    local wait = 0
    strip:SetScript("OnUpdate", function(_, elapsed)
        wait = wait - elapsed
        if wait > 0 then return end
        wait = EVERY
        local ok, err = pcall(Draw)
        if not ok then ns.ReportOnce("livebeacon", err) end
    end)
end

function LiveBeacon:Enabled() return ns.db and ns.db.liveBeacon == true end

--- Whether the strip draws: the setting is on, or a run is recording.
function LiveBeacon:Drawing()
    return self:Enabled() or (ns.Run ~= nil and ns.Run:State() == "recording")
end

--- Draw the strip, or stop drawing it, as the setting and the run say.
function LiveBeacon:Apply()
    if self:Drawing() then
        if not strip then Build() end
        strip:SetScale(PixelScale())
        strip:Show()
    else
        -- not drawn: what was waiting will never be seen, and must not burst out when it draws again
        queue, held = {}, HOLD
        if strip then strip:Hide() end
    end
end

--- Entering the world: draw the strip when the setting is on or a run records.
function LiveBeacon:OnEnable()
    self:NoteXP()
    self:Apply()
end

function LiveBeacon:OnInit()
    local E, EV, PlainNumber = ns.Events, LiveBeacon.EVENT, ns.PlainNumber
    E:Register("FG_RUN_CHANGED", function() LiveBeacon:Apply() end)
    E:Register("FG_QUEST_ACCEPTED", function(_, q) LiveBeacon:Push(EV.accept, PlainNumber(q)) end)
    E:Register("FG_QUEST_TURNED_IN", function(_, q) LiveBeacon:Push(EV.turnIn, PlainNumber(q)) end)
    E:Register("FG_QUEST_ABANDONED", function(_, q) LiveBeacon:Push(EV.abandon, PlainNumber(q)) end)
    -- every count going up, with what made it: the record of what the player did
    E:Register("FG_OBJECTIVE_PROGRESS", function(_, q, idx, have, need)
        local source, sourceId = LiveBeacon:SourceNow()
        LiveBeacon:Push(EV.progress, PlainNumber(q), {
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
        if me ~= nil and ns.PlainString(attacker) == me then LiveBeacon:NoteKill(id) end
    end)
    E:Register("FG_QUEST_TURNED_IN", function(_, q) lastTurnIn = { quest = PlainNumber(q) or 0, at = ns.Now() } end)
    local explored = ExploredPattern()
    E:Register("CHAT_MSG_COMBAT_XP_GAIN", function(_, text)
        text = ns.PlainString(text)
        if text and text:find(explored) then lastExplore = { at = ns.Now() } end
    end)
    E:Register("PLAYER_XP_UPDATE", function(_, unit)
        if unit ~= nil and ns.PlainString(unit) ~= "player" then return end
        local gained = LiveBeacon:XPGained()
        if gained <= 0 then return end
        local source, sourceId = LiveBeacon:XPSourceNow()
        LiveBeacon:Push(EV.xp, math.min(0xFFFFFF, gained), { source = source, sourceId = sourceId })
    end)
    E:Register("LOOT_OPENED", function() LiveBeacon:NoteLoot() end)
    E:Register("FG_LEVEL_CHANGED", function(_, level) LiveBeacon:Push(EV.level, PlainNumber(level)) end)
    E:Register("PLAYER_DEAD", function() LiveBeacon:Push(EV.death, 0) end)
end

--- The setting switched on or off (Options, /fg live).
function LiveBeacon:SetEnabled(on)
    ns.db.liveBeacon = on and true or false
    self:Apply()
end

--- The cells as last drawn, for tests and /fg live: their colors, 0-255.
function LiveBeacon:Shown()
    if not (strip and strip:IsShown()) then return nil end
    local out = {}
    for i, t in ipairs(textures) do
        local c = t.colorTexture
        out[i] = c and { math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5) } or nil
    end
    return out
end
