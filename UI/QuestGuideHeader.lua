-- ============================================================
-- ForeverGuide / UI/QuestGuideHeader.lua
--   (compass)  QUEST GUIDE                       6 / 14
--   Elwynn Forest 1-11 (Human)  ·  Lv 7
--   ---------------- gold separator ----------------
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Header = {}
ns.QuestGuideHeader = Header

Header.HEIGHT = 50

function Header.Create(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    h:SetHeight(Header.HEIGHT)

    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(24, 24)
    h.icon:SetPoint("TOPLEFT", h, "TOPLEFT", 11, -8)
    h.icon:Hide()

    h.title = Theme.NewText(h, { fancy = true, size = 16, color = Theme.C.goldLight, oneLine = true })
    h.title:SetPoint("LEFT", h.icon, "RIGHT", 7, 0)
    h.title:SetPoint("RIGHT", h, "RIGHT", -168, 0)
    pcall(h.title.SetJustifyV, h.title, "MIDDLE")
    h.title:SetText("QUEST GUIDE")

    h.count = Theme.NewText(h, { fancy = true, size = 14, color = Theme.C.gold, justify = "RIGHT", oneLine = true })
    h.count:SetPoint("TOPRIGHT", h, "TOPRIGHT", -12, -11)
    h.count:SetWidth(64)

    h.report = Theme.NewButton(h, "!", 24, 22, function() ns.Reports:Prompt() end)
    h.report:SetPoint("TOPRIGHT", h, "TOPRIGHT", -80, -8)
    h.report:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:SetOwner(self, "ANCHOR_TOP") tt:AddLine("Report wrong step") tt:Show() end
    end)
    h.report:SetScript("OnLeave", function()
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
    end)
    h.reports = Theme.NewButton(h, "R", 24, 22, function() ns.Reports:ShowList() end)
    h.reports:SetPoint("RIGHT", h.report, "LEFT", -4, 0)
    h.reports:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:SetOwner(self, "ANCHOR_TOP") tt:AddLine("View saved feedback") tt:Show() end
    end)
    h.reports:SetScript("OnLeave", function()
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
    end)

    -- Record: one click records this character's run, again pauses (Run:Record)
    h.record = Theme.NewButton(h, "", 24, 22, function() ns.Run:Record() end)
    h.record:SetPoint("RIGHT", h.reports, "LEFT", -4, 0)
    h.record.dot = h.record:CreateTexture(nil, "OVERLAY")
    h.record.dot:SetSize(10, 10)
    h.record.dot:SetPoint("CENTER", h.record, "CENTER", 0, 0)
    pcall(h.record.dot.SetMask, h.record.dot, "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    h.record:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if not tt then return end
        local state = ns.Run:State()
        tt:SetOwner(self, "ANCHOR_TOP")
        tt:AddLine(state == "recording" and "Recording: click to pause" or state == "paused" and "Paused: click to record" or "Record this character's run")
        tt:AddLine("Carries on through /reload and logging out. The Companion keeps it as a session recording.", 1, 1, 1, true)
        tt:Show()
    end)
    h.record:SetScript("OnLeave", function()
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
    end)
    Header.RefreshRecord(h)

    h.sub = Theme.NewText(h, { size = 10, color = Theme.C.textDim, oneLine = true })
    h.sub:SetPoint("TOPLEFT", h, "TOPLEFT", 14, -33)
    h.sub:SetPoint("TOPRIGHT", h, "TOPRIGHT", -12, -33)

    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetHeight(1)
    h.line:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 6, 0)
    h.line:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -6, 0)
    pcall(h.line.SetTexture, h.line, Theme.TEX.headerLine)
    h.line:SetVertexColor(0.3, 0.3, 0.3, 1)

    -- the run controls, while Record runs is on (UI/RunStrip.lua)
    h.run = ns.RunStrip.Create(h)
    ns.RunStrip.Apply(h)

    h.Set = Header.Set
    return h
end

local RECORD_COLOR = { recording = { 1.00, 0.20, 0.15 }, paused = { 1.00, 0.70, 0.20 }, idle = { 0.45, 0.45, 0.45 } }

--- The Record button's dot: red while recording, amber paused, grey with no run.
function Header.RefreshRecord(h)
    local c = RECORD_COLOR[ns.Run:State()] or RECORD_COLOR.idle
    h.record.dot:SetColorTexture(c[1], c[2], c[3], 1)
end

ns.Events:Register("FG_RUN_CHANGED", function()
    local f = ns.QuestGuide and ns.QuestGuide.frame
    if f and f.header and f.header.record then Header.RefreshRecord(f.header) end
end)

--- title (nil keeps "QUEST GUIDE"), countText ("6 / 14"), subText
function Header.Set(h, countText, subText, title)
    h.title:SetText(title or "QUEST GUIDE")
    h.count:SetText(countText or "")
    h.sub:SetText(subText or "")
end
