-- ============================================================
-- ForeverGuide / Run.lua
-- Record runs: an opt-in of its own (Options -> Data collection, off by default), separate
-- from Contribute data. Turning it on shows run controls on the guide window (UI/RunStrip.lua);
-- nothing is recorded until the player presses Start. While a run records, it keeps a timed
-- log of what happened, for calibrating the route planner:
--   START STOP PAUSE RESUME GAP   the run itself (GAP: entries lost with the SavedVariables)
--   ACCEPT TURNIN ABANDON OBJ     quests (TURNIN: xp, money; OBJ: obj, f, r, done)
--   LEVEL                         a level-up (l, rested)
--   KILL                          a creature the player killed (npc, mobLevel, elite, secs, rested)
--   MOVE                          every 5 s while moving (mounted, taxi)
--   TAXI LAND                     a flight's start (cost) and landing (secs)
--   DEATH RESURRECT               dying, and coming back (secs)
--   HEARTH                        the hearthstone (action = "use" | "bind")
-- Every entry carries t (seconds of recording since the run started: never the clock), lvl,
-- m/x/y (uiMapID, map percent) and g/s (the guide and step being followed; g = "auto" in auto
-- mode). Never kept: names, realm, GUIDs, chat, the date or time of day.
--
-- A run is sent in segments: Send hands the entries since the last Send to the share window
-- (Share.lua, docs/SHARE-FORMAT.md) and recording carries on in the next segment. The run lives
-- in ForeverGuideCharDB.run; its id, segment and clock are mirrored in a cvar (Persist.lua), so a
-- login that loses the SavedVariables loses at most the unsent segment, marked with GAP.
-- ============================================================

local _, ns = ...
local Run = ns:NewModule("Run")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

Run.MAX_ENTRIES = 2500     -- one segment: about one 50,000-character share part
local WARN_AT = 2000       -- entries: remind to send the segment
local MOVE_EVERY = 5       -- seconds between movement samples
local MOVE_MIN = 0.05      -- map units the player must have moved for a sample
local HEARTHSTONE = 8690
local ELITE = { elite = true, rareelite = true, worldboss = true }

-- session state, never saved: what the kill, flight and death timers need
local resumedAt              -- ns.Now() when recording last started or resumed
local ticker                 -- the frame whose OnUpdate samples movement and taxis
local lastSample             -- { t = ns.Now(), m, x, y } of the last movement check
local mobs = {}              -- guid -> { npc, level, elite }: creatures targeted this session
local mobCount = 0
local engaged = {}           -- guid -> true: creatures targeted during the current fight
local killed = {}            -- guid -> true: deaths already recorded
local fightStart, lastKill
local taxiMoney, taxiStart, onTaxi
local deadAt
local warned = false

local function Enabled() return ns.db and ns.db.recordRuns == true end
local function Current() return ns.char and ns.char.run end

local function Round(n, places) return n and ns.Round(n, places) end

-- seconds of recording since the run started
function Run:Elapsed()
    local run = Current()
    if not run then return 0 end
    if run.state == "recording" and resumedAt then return run.elapsed + (ns.Now() - resumedAt) end
    return run.elapsed
end

function Run:State()
    local run = Current()
    return run and run.state or "idle"
end

function Run:Count()
    local run = Current()
    return run and #run.entries or 0
end

local function Changed()
    if ticker then ticker:SetShown(Run:State() == "recording" and Enabled()) end
    ns.Events:Fire("FG_RUN_CHANGED", Run:State())
end

-- the guide and step being followed, as /fg wrong reads them
local function GuideStep()
    local G, T = ns.Guide, ns.Tracker
    if T and T.IsActive and T:IsActive() and (not G.active or ns.char.mode == "auto") then return "auto", nil end
    if G and G.active then return G.active.id, G.current end
    return nil, nil
end

--- Append an entry to the current segment. force: the run's own entries (PAUSE, STOP) go in
--- while paused and past the cap.
local function Add(kind, fields, force)
    local run = Current()
    if not run or not Enabled() and not force then return nil end
    if run.state ~= "recording" and not force then return nil end
    if #run.entries >= Run.MAX_ENTRIES and not force then
        Run:Pause()
        ns.Warn(string.format("run segment full (%d entries): recording paused. Press Send on the guide window "
            .. "to paste it into the feedback form, then Resume.", #run.entries))
        return nil
    end
    local e = fields or {}
    e.e, e.t, e.lvl = kind, Round(Run:Elapsed(), 1), ns.Player:GetLevel()
    local m, x, y = ns.Player:GetMapPosition()
    e.m, e.x, e.y = m, Round(x, 2), Round(y, 2)
    e.g, e.s = GuideStep()
    run.entries[#run.entries + 1] = e
    if #run.entries >= WARN_AT and not warned then
        warned = true
        ns.Print(string.format("run segment at %d of %d entries: press Send on the guide window soon.", #run.entries, Run.MAX_ENTRIES))
    end
    ns.Events:Fire("FG_RUN_ENTRY", kind)
    return e
end
Run.Add = Add

local function Recording() return Enabled() and Run:State() == "recording" end

local function Rested() return select(3, ns.Player:GetXP()) end

-- ---- the run's lifecycle ---------------------------------------------------------------------
local function NewId()
    return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

local function StartClock()
    resumedAt = ns.Now()
    local m, x, y = ns.Player:GetMapPosition()
    lastSample = { t = ns.Now(), m = m, x = x, y = y }
    onTaxi = PlainBool(ns.Safe(rawget(_G, "UnitOnTaxi"), "player")) == true
end

function Run:Start()
    if not Enabled() then ns.Print("turn on Record runs under /fg options (Data collection) first.") return end
    if Current() then
        if self:State() == "paused" then self:Resume() end
        return
    end
    ns.char.run = { id = NewId(), seg = 1, elapsed = 0, state = "recording", entries = {} }
    warned = false
    StartClock()
    Add("START")
    Changed()
    ns.Print("run recording. Pause, Stop and Send are on the guide window.")
end

function Run:Pause()
    local run = Current()
    if not run or run.state ~= "recording" then return end
    run.elapsed = self:Elapsed()
    run.state = "paused"
    resumedAt = nil
    Add("PAUSE", nil, true)
    Changed()
end

function Run:Resume()
    local run = Current()
    if not run or run.state ~= "paused" then return end
    if not Enabled() then ns.Print("turn on Record runs under /fg options (Data collection) first.") return end
    if #run.entries >= self.MAX_ENTRIES then ns.Print("the run segment is full: press Send first.") return end
    run.state = "recording"
    StartClock()
    if run.gap then
        run.gap = nil
        Add("GAP")
    end
    Add("RESUME")
    Changed()
end

-- the current segment as it goes into a share, and the run moved on to the next one
local function CloseSegment(done)
    local run = Current()
    local segment = { id = run.id, seg = run.seg, done = done or nil, entries = run.entries }
    ns.char.runSent = segment
    run.seg, run.entries, warned = run.seg + 1, {}, false
    return segment
end

--- Hand the current segment to the share window; recording carries on in the next segment.
--- With nothing new recorded, the last segment sent is shown again to copy.
function Run:Send()
    local run = Current()
    if run and #run.entries > 0 then
        ns.Share:ShowRun(CloseSegment(false))
        Changed()
    elseif ns.char.runSent then
        ns.Share:ShowRun(ns.char.runSent)
    else
        ns.Print("nothing recorded to send yet.")
    end
end

--- End the run: its last segment goes to the share window, marked done.
function Run:Stop()
    local run = Current()
    if not run then return end
    run.elapsed, run.state, resumedAt = self:Elapsed(), "stopped", nil
    Add("STOP", nil, true)
    local segment = CloseSegment(true)
    ns.char.run, resumedAt = nil, nil
    Changed()
    ns.Share:ShowRun(segment)
end

--- Throw the run away, sent segments included.
function Run:Discard()
    ns.char.run, ns.char.runSent, resumedAt = nil, nil, nil
    Changed()
end

--- Record runs switched on or off (Options). Off pauses a recording run and hides the controls.
function Run:SetEnabled(on)
    if not on then self:Pause() end
    ns.db.recordRuns = on and true or false
    Changed()
end

-- ---- the cvar mirror (Persist.lua): "id:seg:elapsed" -------------------------------------------
function Run:MirrorString()
    local run = Current()
    if not run then return nil end
    return string.format("%s:%d:%.1f", run.id, run.seg, self:Elapsed())
end

--- A login that lost the SavedVariables: bring back the run, paused, its unsent entries lost.
function Run:RestoreMirror(s)
    if Current() or type(s) ~= "string" then return end
    local id, seg, elapsed = s:match("^(%x+):(%d+):([%d%.]+)$")
    if not id then return end
    ns.char.run = { id = id, seg = tonumber(seg), elapsed = tonumber(elapsed), state = "paused", entries = {}, gap = true }
end

-- ---- what is recorded ------------------------------------------------------------------------
local function NoteMob(info)
    if not (info and info.guid and info.npcID and not info.isPlayer) then return end
    if not mobs[info.guid] then
        mobCount = mobCount + 1
        if mobCount > 200 then mobs, mobCount = {}, 1 end
    end
    local class = PlainString(ns.Safe(rawget(_G, "UnitClassification"), info.unit or "target"))
    mobs[info.guid] = { npc = info.npcID, level = info.level, elite = ELITE[class or ""] == true }
    if fightStart then engaged[info.guid] = true end
end

-- a creature died: the player's kill when the player struck it, or it was fought this fight
local function Died(guid, byPlayer)
    guid = PlainString(guid)
    if not guid or killed[guid] or not (byPlayer or engaged[guid]) then return end
    local npc = ns.Player:NpcIDFromGUID(guid)
    if not npc then return end
    killed[guid] = true
    local now = ns.Now()
    local from = fightStart and math.max(fightStart, lastKill or fightStart)
    lastKill = now
    local fields = { npc = npc, secs = from and Round(now - from, 1) or nil, rested = Rested() }
    -- level and class only for a creature that was targeted: unknown stays out, not false
    local mob = mobs[guid]
    if mob and mob.npc == npc then fields.mobLevel, fields.elite = mob.level, mob.elite end
    Add("KILL", fields)
end

-- every second while recording: a flight starting or ending; every 5 s: a movement sample
local function Tick()
    local now = ns.Now()
    local taxi = PlainBool(ns.Safe(rawget(_G, "UnitOnTaxi"), "player")) == true
    if taxi and not onTaxi then
        local money = PlainNumber(ns.Safe(rawget(_G, "GetMoney")))
        local cost = taxiMoney and money and taxiMoney - money
        taxiStart = now
        Add("TAXI", { cost = cost and cost > 0 and cost or nil })
    elseif onTaxi and not taxi then
        Add("LAND", { secs = taxiStart and Round(now - taxiStart, 1) or nil })
        taxiStart, taxiMoney = nil, nil
    end
    onTaxi = taxi
    if lastSample and now - lastSample.t < MOVE_EVERY then return end
    local m, x, y = ns.Player:GetMapPosition()
    local moved = m and x and lastSample and (m ~= lastSample.m or not lastSample.x
        or math.abs(x - lastSample.x) >= MOVE_MIN or math.abs(y - lastSample.y) >= MOVE_MIN)
    lastSample = { t = now, m = m, x = x, y = y }
    if moved then
        Add("MOVE", { mounted = PlainBool(ns.Safe(rawget(_G, "IsMounted"))) == true, taxi = taxi })
    end
end

function Run:OnInit()
    local E = ns.Events
    -- a run left recording by a session that never logged out (a crash): paused where its log ends
    local run = Current()
    if run and run.state == "recording" then
        local lastEntry = run.entries[#run.entries]
        run.elapsed = math.max(run.elapsed or 0, lastEntry and lastEntry.t or 0)
        run.state = "paused"
    end

    ticker = CreateFrame("Frame")
    ticker:Hide()
    local since = 0
    ticker:SetScript("OnUpdate", function(_, elapsed)
        since = since + (elapsed or 0)
        if since < 1 then return end
        since = 0
        local ok, err = pcall(Tick)
        if not ok then ns.ReportOnce("run:tick", err) end
    end)

    E:Register("FG_QUEST_ACCEPTED", function(_, questID) Add("ACCEPT", { q = PlainNumber(questID) }) end)
    E:Register("FG_QUEST_TURNED_IN", function(_, questID, _, xp, money)
        Add("TURNIN", { q = PlainNumber(questID), xp = PlainNumber(xp), money = PlainNumber(money) })
    end)
    E:Register("FG_QUEST_ABANDONED", function(_, questID) Add("ABANDON", { q = PlainNumber(questID) }) end)
    E:Register("FG_OBJECTIVE_PROGRESS", function(_, questID, idx, fulfilled, required, finished)
        Add("OBJ", { q = PlainNumber(questID), obj = PlainNumber(idx), f = PlainNumber(fulfilled),
            r = PlainNumber(required), done = PlainBool(finished) })
    end)
    E:Register("FG_LEVEL_CHANGED", function(_, level) Add("LEVEL", { l = PlainNumber(level), rested = Rested() }) end)

    E:Register("FG_TARGET_CHANGED", function(_, info) if Recording() then NoteMob(info) end end)
    E:Register("PLAYER_REGEN_DISABLED", function()
        fightStart, lastKill, engaged = ns.Now(), nil, {}
        if Recording() then NoteMob(ns.Player:GetTargetInfo()) end
    end)
    E:Register("PARTY_KILL", function(_, attackerGUID, targetGUID)
        if not Recording() then return end
        local me = PlainString(ns.Safe(rawget(_G, "UnitGUID"), "player"))
        Died(targetGUID, me ~= nil and PlainString(attackerGUID) == me)
    end)
    E:Register("UNIT_DIED", function(_, guid) if Recording() then Died(guid, false) end end)

    E:Register("TAXIMAP_OPENED", function() taxiMoney = PlainNumber(ns.Safe(rawget(_G, "GetMoney"))) end)

    E:Register("PLAYER_DEAD", function()
        if not Recording() then return end
        deadAt = ns.Now()
        Add("DEATH")
    end)
    local function Back()
        if not deadAt or PlainBool(ns.Safe(rawget(_G, "UnitIsGhost"), "player")) == true then return end
        local secs = Round(ns.Now() - deadAt, 1)
        deadAt = nil
        Add("RESURRECT", { secs = secs })
    end
    E:RegisterMany({ "PLAYER_ALIVE", "PLAYER_UNGHOST" }, Back)

    E:Register("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
        if PlainString(unit) == "player" and PlainNumber(spellID) == HEARTHSTONE then Add("HEARTH", { action = "use" }) end
    end)
    E:Register("HEARTHSTONE_BOUND", function() Add("HEARTH", { action = "bind" }) end)
end

function Run:OnEnterWorld()
    Changed()
end

function Run:OnLogout()
    self:Pause()
end
