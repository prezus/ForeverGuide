-- ============================================================
-- ForeverGuide / UI/RunStrip.lua
-- The run controls: one row under the guide window's header, shown only while Record runs
-- is on (Options -> Data collection). Run.lua does the recording; this row only drives it.
--   REC 1:23:45 · 312            [Pause] [Stop] [Send]
--   PAUSED 1:23:45 · 312        [Resume] [Stop] [Send]
--   Run recorder: ready                        [Start]
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Strip = {}
ns.RunStrip = Strip

Strip.HEIGHT = 26
local BASE = ns.QuestGuideHeader.HEIGHT

local COLOR_REC = { 1.00, 0.35, 0.30 }

local function Tip(button, lines)
    button:SetScript("OnEnter", function(self)
        Theme.Color(self.label, Theme.C.goldLight)
        local tt = rawget(_G, "GameTooltip")
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_TOP")
        for _, line in ipairs(lines) do tt:AddLine(line, 1, 1, 1, true) end
        tt:Show()
    end)
    button:SetScript("OnLeave", function(self)
        Theme.Color(self.label, Theme.C.gold)
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
    end)
end

local function Clock(secs)
    secs = math.floor(secs or 0)
    return string.format("%d:%02d:%02d", math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
end

function Strip.Create(header)
    local s = CreateFrame("Frame", nil, header)
    s:SetHeight(Strip.HEIGHT - 2)
    s:SetPoint("TOPLEFT", header, "TOPLEFT", 0, -(BASE - 2))
    s:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, -(BASE - 2))
    s:Hide()

    local R = ns.Run
    s.send = Theme.NewButton(s, "Send", 48, 22, function() R:Send() end)
    s.send:SetPoint("RIGHT", s, "RIGHT", -12, 0)
    Tip(s.send, { "Send segment", "Opens the share window with everything since the last Send.",
        "Paste it into the feedback form; recording carries on." })
    s.stop = Theme.NewButton(s, "Stop", 44, 22, function() R:Stop() end)
    s.stop:SetPoint("RIGHT", s.send, "LEFT", -4, 0)
    Tip(s.stop, { "Stop the run", "Ends the run and opens its last segment to paste." })
    s.pause = Theme.NewButton(s, "Pause", 60, 22, function()
        if R:State() == "recording" then R:Pause() else R:Resume() end
    end)
    s.pause:SetPoint("RIGHT", s.stop, "LEFT", -4, 0)
    Tip(s.pause, { "Pause / Resume", "While paused nothing is recorded and the run's clock stops." })
    s.start = Theme.NewButton(s, "Start", 60, 22, function() R:Start() end)
    s.start:SetPoint("RIGHT", s, "RIGHT", -12, 0)
    Tip(s.start, { "Start a run", "Records a timed log of your play (no names or clock time)",
        "until you Stop; send it in segments with Send." })

    s.status = Theme.NewText(s, { size = 11, color = Theme.C.textDim, oneLine = true })
    s.status:SetPoint("LEFT", s, "LEFT", 14, 0)
    s.status:SetPoint("RIGHT", s.pause, "LEFT", -6, 0)
    pcall(s.status.SetJustifyV, s.status, "MIDDLE")

    local since = 0
    s:SetScript("OnUpdate", function(_, elapsed)
        since = since + (elapsed or 0)
        if since < 0.5 then return end
        since = 0
        if R:State() == "recording" then Strip.Refresh(s) end
    end)
    return s
end

--- Buttons and status for the run's state.
function Strip.Refresh(s)
    local R = ns.Run
    local state = R:State()
    local idle = state == "idle"
    s.start:SetShown(idle)
    s.pause:SetShown(not idle)
    s.stop:SetShown(not idle)
    s.send:SetShown(not idle or ns.char.runSent ~= nil)
    if idle and ns.char.runSent then
        -- idle with a sent segment: Send shows it again, left of Start
        s.send:ClearAllPoints()
        s.send:SetPoint("RIGHT", s.start, "LEFT", -4, 0)
    else
        s.send:ClearAllPoints()
        s.send:SetPoint("RIGHT", s, "RIGHT", -12, 0)
    end
    s.pause.label:SetText(state == "recording" and "Pause" or "Resume")
    s.status:ClearAllPoints()
    s.status:SetPoint("LEFT", s, "LEFT", 14, 0)
    s.status:SetPoint("RIGHT", idle and (ns.char.runSent and s.send or s.start) or s.pause, "LEFT", -6, 0)
    if idle then
        Theme.Color(s.status, Theme.C.textDim)
        s.status:SetText("Run recorder: ready")
    else
        local tag = state == "recording" and "REC" or "PAUSED"
        Theme.Color(s.status, state == "recording" and COLOR_REC or Theme.C.skipped)
        s.status:SetText(string.format("%s %s \194\183 %d", tag, Clock(R:Elapsed()), R:Count()))
    end
end

--- Show or hide the row with the option, growing the header to hold it.
function Strip.Apply(header)
    local s = header and header.run
    if not s then return end
    local on = ns.db and ns.db.recordRuns == true
    s:SetShown(on)
    ns.QuestGuideHeader.HEIGHT = on and (BASE + Strip.HEIGHT) or BASE
    header:SetHeight(ns.QuestGuideHeader.HEIGHT)
    if on then Strip.Refresh(s) end
    -- while the window is being built it lays itself out once it is done
    if ns.QuestGuide and ns.QuestGuide.frame then ns.QuestGuide:Layout() end
end

ns.Events:Register("FG_RUN_CHANGED", function()
    local f = ns.QuestGuide and ns.QuestGuide.frame
    if f and f.header then Strip.Apply(f.header) end
end)
ns.Events:Register("FG_RUN_ENTRY", function()
    local f = ns.QuestGuide and ns.QuestGuide.frame
    local s = f and f.header and f.header.run
    if s and s:IsShown() then Strip.Refresh(s) end
end)
