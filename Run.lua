-- ============================================================
-- ForeverGuide / Run.lua
-- Record runs: an opt-in of its own (Options -> Data collection, off by default), separate
-- from Contribute data. Turning it on shows run controls on the guide window (UI/RunStrip.lua);
-- nothing is recorded until the player presses Start. While a run records, it keeps a timed
-- log of what happened, for calibrating the route planner:
--   START STOP PAUSE RESUME GAP   the run itself (GAP: entries lost; only from builds that mirrored the run)
--   ACCEPT TURNIN ABANDON OBJ     quests (TURNIN: xp, money; OBJ: obj, f, r, done, src, sid)
--   XP                            every bit of experience (xp, src, sid)
--   LEVEL                         a level-up (l, rested)
--   KILL                          a creature the player killed (npc, mobLevel, elite, secs, rested)
--   MOVE                          every 2 s while moving (mounted, taxi)
--   TAXI LAND                     a flight's start (cost) and landing (secs)
--   DEATH RESURRECT               dying, and coming back (secs)
--   HEARTH                        the hearthstone (action = "use" | "bind")
-- Every entry carries t (seconds of recording since the run started), lvl, m/x/y (uiMapID, map
-- percent) and g/s (the guide and step being followed; g = "auto" in auto mode). START and RESUME
-- also carry at, the date and time the sitting began (seconds since the epoch), so a run over several
-- evenings says when each was. src/sid say what made it (Sources.lua): kill, mobLoot, object, quest,
-- explore or other, and the creature's, object's or quest's id. Never kept: names, realm, GUIDs,
-- chat. (The Companion knows the character from where the saved variables are, and files the run
-- under it at codex; the run's segments carry no name.)
--
-- A run is sent in segments: Send hands the entries since the last Send to the share window
-- (Share.lua, docs/SHARE-FORMAT.md) and recording carries on in the next segment. The run lives
-- in ForeverGuideCharDB.run.
--
-- With ForeverGuide Companion (the desktop app that uploads runs; its ForeverGuideCompanion addon
-- defines ForeverGuideCompanionReceipt), closed segments go to ForeverGuideCharDB.runOutbox instead
-- of the share window, each as its full share document. A full segment closes into the outbox and
-- recording carries on, and logging out closes the open segment too. On entering the world, the
-- segments the receipt names (codex has them) leave the outbox. Without the companion nothing
-- changes.
-- ============================================================

local _, ns = ...
local Run = ns:NewModule("Run")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

Run.MAX_ENTRIES = 2500     -- one segment: about one 50,000-character share part
Run.NOTICE_AT = 2250       -- entries: ask with a dialog to send the segment before it fills
local MOVE_EVERY = 2       -- seconds between movement samples
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
local noticed = false        -- the near-full dialog has been shown for this segment

local function Enabled() return ns.db and ns.db.recordRuns == true end
local function Current() return ns.char and ns.char.run end

-- ForeverGuide Companion is installed: its addon's receipt is loaded (## OptionalDeps loads it
-- first). Its only file assigns the receipt, so the table being there is the companion being there.
local function Receipt()
    local receipt = rawget(_G, "ForeverGuideCompanionReceipt")
    return type(receipt) == "table" and receipt or nil
end
local function Companion() return Receipt() ~= nil end
Run.Companion = Companion

--- Ask the player with the run dialog (UI:ShowRunNotice): "near" the limit, "full" and paused, or
--- "paused" at login. A long recording must not lose play to a chat line nobody read.
local function Notice(kind)
    local run = Current()
    if run and ns.UI and ns.UI.ShowRunNotice then ns.UI:ShowRunNotice(kind, #run.entries, Run.MAX_ENTRIES) end
end

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
        if Companion() then
            -- the companion uploads it: close the full segment and record on in the next
            Run.ToOutbox(Run.CloseSegment(false))
        else
            Run:Pause()
            Notice("full")
            return nil
        end
    end
    local e = fields or {}
    e.e, e.t, e.lvl = kind, Round(Run:Elapsed(), 1), ns.Player:GetLevel()
    local m, x, y = ns.Player:GetMapPosition()
    e.m, e.x, e.y = m, Round(x, 2), Round(y, 2)
    e.g, e.s = GuideStep()
    run.entries[#run.entries + 1] = e
    if #run.entries >= Run.NOTICE_AT and not noticed and not force and not Companion() then
        noticed = true
        Notice("near")
    end
    ns.Events:Fire("FG_RUN_ENTRY", kind)
    return e
end
Run.Add = Add

local function Recording() return Enabled() and Run:State() == "recording" end

local function Rested() return select(3, ns.Player:GetXP()) end

-- ---- the run's lifecycle ---------------------------------------------------------------------
-- four 16-bit draws: Lua 5.1's math.random(m, n) overflows on a range as wide as 2^31
local function NewId()
    return string.format("%04x%04x%04x%04x", math.random(0, 0xffff), math.random(0, 0xffff),
        math.random(0, 0xffff), math.random(0, 0xffff))
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
    ns.char.runWanted = true
    StartClock()
    Add("START", { at = PlainNumber(ns.Safe(rawget(_G, "time"))) })
    Changed()
end

function Run:Pause()
    local run = Current()
    if not run or run.state ~= "recording" then return end
    run.elapsed = self:Elapsed()
    run.state = "paused"
    resumedAt = nil
    ns.char.runWanted = nil
    Add("PAUSE", nil, true)
    Changed()
end

function Run:Resume()
    local run = Current()
    if not run or run.state ~= "paused" then return end
    if not Enabled() then ns.Print("turn on Record runs under /fg options (Data collection) first.") return end
    if #run.entries >= self.MAX_ENTRIES then ns.Print("the run segment is full: press Send first.") return end
    run.state = "recording"
    ns.char.runWanted = true
    StartClock()
    if run.gap then
        run.gap = nil
        Add("GAP")
    end
    Add("RESUME", { at = PlainNumber(ns.Safe(rawget(_G, "time"))) })
    if ns.UI and ns.UI.HideRunNotice then ns.UI:HideRunNotice() end
    Changed()
end

-- the current segment as it goes into a share, and the run moved on to the next one
local function CloseSegment(done)
    local run = Current()
    local segment = { id = run.id, seg = run.seg, done = done or nil, entries = run.entries }
    ns.char.runSent = segment
    run.seg, run.entries, noticed = run.seg + 1, {}, false
    return segment
end
Run.CloseSegment = CloseSegment

--- Keep a closed segment for ForeverGuide Companion: its share document, exactly what Send would
--- show, at the end of ForeverGuideCharDB.runOutbox.
function Run.ToOutbox(segment)
    local outbox = ns.char.runOutbox or {}
    ns.char.runOutbox = outbox
    outbox[#outbox + 1] = ns.Share:RunDoc(segment)
end

--- The segments waiting for ForeverGuide Companion.
function Run:Outbox()
    return ns.char and ns.char.runOutbox or {}
end

-- A closed segment goes to the companion's outbox when it is installed, else to the share window.
local function Deliver(segment)
    if Companion() then
        Run.ToOutbox(segment)
        -- chat stays quiet (the changelog's rule): the run strip and the app say what happens
        ns.Debug("run: segment", segment.seg, "saved for ForeverGuide Companion")
    else
        ns.Share:ShowRun(segment)
    end
end

--- Drop the segments the companion's receipt names: codex has them.
function Run:ApplyReceipt()
    local receipt, outbox = Receipt(), ns.char and ns.char.runOutbox
    if not (receipt and outbox) then return end
    local kept = {}
    for _, doc in ipairs(outbox) do
        local run = type(doc) == "table" and doc.run
        local key = run and tostring(run.id) .. ":" .. tostring(run.seg)
        if not (key and receipt[key] == true) then kept[#kept + 1] = doc end
    end
    ns.char.runOutbox = #kept > 0 and kept or nil
end

--- Hand the current segment to the share window; recording carries on in the next segment.
--- With nothing new recorded, the last segment sent is shown again to copy.
function Run:Send()
    local run = Current()
    if run and #run.entries > 0 then
        Deliver(CloseSegment(false))
        if ns.UI and ns.UI.HideRunNotice then ns.UI:HideRunNotice() end
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
    ns.char.run, ns.char.runWanted, resumedAt = nil, nil, nil
    Changed()
    Deliver(segment)
end

--- Throw the run away, sent segments included (the outbox keeps what is waiting for the companion).
function Run:Discard()
    ns.char.run, ns.char.runSent, ns.char.runWanted, resumedAt = nil, nil, nil, nil
    Changed()
end

--- The guide header's Record button: one click records (turning Record runs on if it is off), the
--- next pauses, the next goes on. The run is this character's; it carries on through /reload and
--- logging out (OnEnterWorld), so a run over several sittings is one recording.
function Run:Record()
    if not Enabled() then self:SetEnabled(true) end
    local state = self:State()
    if state == "recording" then self:Pause() elseif state == "paused" then self:Resume() else self:Start() end
end

--- Record runs switched on or off (Options). Off pauses a recording run and hides the controls.
function Run:SetEnabled(on)
    if not on then self:Pause() end
    ns.db.recordRuns = on and true or false
    Changed()
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

-- every second while recording: a flight starting or ending; every 2 s: a movement sample
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
        local src, sid = ns.Sources:SourceNow()
        Add("OBJ", { q = PlainNumber(questID), obj = PlainNumber(idx), f = PlainNumber(fulfilled),
            r = PlainNumber(required), done = PlainBool(finished), src = src, sid = sid ~= 0 and sid or nil })
    end)
    -- every bit of experience, and where it came from; measured whether or not the run records, so a
    -- gain is never counted from a stale reading
    E:Register("PLAYER_XP_UPDATE", function(_, unit)
        if unit ~= nil and PlainString(unit) ~= "player" then return end
        local gained = ns.Sources:XPGained()
        if gained <= 0 then return end
        local src, sid = ns.Sources:XPSourceNow()
        Add("XP", { xp = gained, src = src, sid = sid ~= 0 and sid or nil })
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
    -- every addon has loaded by now, the companion's receipt included
    self:ApplyReceipt()
    Changed()
    local run = Current()
    if not (run and Enabled() and run.state == "paused") then return end
    -- recording when the game reloaded or logged out (or crashed): carry on, no click needed
    if ns.char.runWanted and #run.entries < self.MAX_ENTRIES then
        self:Resume()
        return
    end
    -- paused by the player, or full: say so, or the session goes unrecorded
    Notice(#run.entries >= self.MAX_ENTRIES and "full" or "paused")
end

--- Send a full segment and record on from here: the dialog's "Send and resume".
function Run:SendAndResume()
    self:Send()
    self:Resume()
end

function Run:OnLogout()
    -- paused for the logout, not by the player: the next session carries on (OnEnterWorld)
    local wanted = ns.char.runWanted
    self:Pause()
    ns.char.runWanted = wanted
    -- with the companion, the open segment goes to the outbox now, so it uploads as the game saves
    local run = Current()
    if run and Companion() and #run.entries > 0 then Run.ToOutbox(CloseSegment(false)) end
end
